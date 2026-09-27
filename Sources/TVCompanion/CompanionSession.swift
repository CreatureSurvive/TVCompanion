import Foundation

/// A message received from a paired device.
public struct CompanionMessage: Sendable {
    public let type: String
    public let body: Data

    /// Decodes the body.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

/// A request from a paired device, awaiting a response.
public struct CompanionRequest: Sendable {
    public let type: String
    public let body: Data
    let id: UUID
    weak var session: CompanionSession?

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    /// Sends a response.
    public func respond<T: Encodable & Sendable>(_ value: T) async throws {
        guard let session else { throw CompanionError.connectionClosed }
        try await session.reply(to: id, with: .success(Wire.encode(value)))
    }

    /// Declines the request, for example because the user canceled.
    public func decline() async {
        try? await session?.reply(to: id, with: .failure(.declined))
    }
}

struct Envelope: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case message, request, response, failure, cancel
    }

    var kind: Kind
    var type: String
    var id: UUID?
    var body: Data?
    var error: String?
}

/// An authenticated, encrypted connection to a paired device.
///
/// Send one-way messages with ``send(_:_:)``, make requests with
/// ``request(_:_:as:timeout:)``, and handle what the other side sends
/// through ``messages`` and ``requests``.
public actor CompanionSession {
    public nonisolated let peer: PairedDevice
    nonisolated let transport: any FrameTransport
    private var channel: SecureChannel
    private var pending: [UUID: CheckedContinuation<Data, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private(set) public var isClosed = false

    private let messageContinuation: AsyncStream<CompanionMessage>.Continuation
    private let requestContinuation: AsyncStream<CompanionRequest>.Continuation
    private let closeContinuation: AsyncStream<Void>.Continuation
    private let cancelContinuation: AsyncStream<UUID>.Continuation

    /// Messages from the peer. Iterate from one place only.
    public nonisolated let messages: AsyncStream<CompanionMessage>
    /// Requests from the peer. Iterate from one place only.
    public nonisolated let requests: AsyncStream<CompanionRequest>
    /// Finishes when the session closes.
    public nonisolated let closed: AsyncStream<Void>
    /// IDs of requests the peer withdrew (for example because another
    /// device answered first).
    nonisolated let cancellations: AsyncStream<UUID>

    init(transport: any FrameTransport, channel: SecureChannel, peer: PairedDevice) {
        self.transport = transport
        self.channel = channel
        self.peer = peer
        (messages, messageContinuation) = AsyncStream.makeStream()
        (requests, requestContinuation) = AsyncStream.makeStream()
        (closed, closeContinuation) = AsyncStream.makeStream()
        (cancellations, cancelContinuation) = AsyncStream.makeStream()
    }

    func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            while let self {
                do {
                    let frame = try await self.transport.receive()
                    try await self.handle(frame)
                } catch {
                    await self.close(error: error)
                    return
                }
            }
        }
    }

    // MARK: - Sending

    /// Sends a one-way message.
    public func send<T: Encodable & Sendable>(_ type: String, _ value: T) throws {
        try write(Envelope(kind: .message, type: type, body: Wire.encode(value)))
    }

    /// Sends a request and waits for the response.
    public func request<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ type: String,
        _ value: Request,
        as responseType: Response.Type,
        timeout: Duration = .seconds(300)
    ) async throws -> Response {
        let id = UUID()
        try write(Envelope(kind: .request, type: type, id: id, body: Wire.encode(value)))
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.resolve(id, with: .failure(CompanionError.timeout))
        }
        defer { timeoutTask.cancel() }
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                if isClosed {
                    continuation.resume(throwing: CompanionError.connectionClosed)
                } else {
                    pending[id] = continuation
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.withdraw(id)
            }
        }
        return try Wire.decode(responseType, from: data)
    }

    /// Closes the session.
    public func close() {
        close(error: CompanionError.connectionClosed)
    }

    // MARK: - Internals

    func reply(to id: UUID, with result: Result<Data, CompanionError>) throws {
        switch result {
        case .success(let body): try write(Envelope(kind: .response, type: "", id: id, body: body))
        case .failure(let error): try write(Envelope(kind: .failure, type: "", id: id, error: error == .declined ? "declined" : "failed"))
        }
    }

    /// Withdraws a request: resolves it locally and tells the peer.
    func withdraw(_ id: UUID) {
        guard pending[id] != nil else { return }
        resolve(id, with: .failure(CancellationError()))
        try? write(Envelope(kind: .cancel, type: "", id: id))
    }

    private func write(_ envelope: Envelope) throws {
        guard !isClosed else { throw CompanionError.connectionClosed }
        // Seal and enqueue without suspending, so frames go out in counter order.
        transport.send(try channel.seal(Wire.encode(envelope)))
    }

    private func handle(_ frame: Data) throws {
        let envelope = try Wire.decode(Envelope.self, from: channel.open(frame))
        switch envelope.kind {
        case .message:
            messageContinuation.yield(CompanionMessage(type: envelope.type, body: envelope.body ?? Data()))
        case .request:
            guard let id = envelope.id else { throw CompanionError.protocolViolation("request without an id") }
            requestContinuation.yield(CompanionRequest(type: envelope.type, body: envelope.body ?? Data(), id: id, session: self))
        case .response:
            guard let id = envelope.id else { return }
            resolve(id, with: .success(envelope.body ?? Data()))
        case .failure:
            guard let id = envelope.id else { return }
            resolve(id, with: .failure(envelope.error == "declined" ? CompanionError.declined : CompanionError.protocolViolation("request failed")))
        case .cancel:
            if let id = envelope.id { cancelContinuation.yield(id) }
        }
    }

    private func resolve(_ id: UUID, with result: Result<Data, any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func close(error: any Error) {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        transport.close()
        for continuation in pending.values {
            continuation.resume(throwing: CompanionError.connectionClosed)
        }
        pending.removeAll()
        messageContinuation.finish()
        requestContinuation.finish()
        cancelContinuation.finish()
        closeContinuation.finish()
    }
}
