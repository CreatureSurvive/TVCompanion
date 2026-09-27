import Foundation
import Network

/// An ordered, reliable stream of frames.
protocol FrameTransport: AnyObject, Sendable {
    /// Queues a frame. Frames are delivered in the order `send` is called.
    func send(_ payload: Data)
    /// The next frame. Only one caller may wait at a time.
    func receive() async throws -> Data
    func close()
    var isClosed: Bool { get }
}

extension FrameTransport {
    func send<T: Encodable>(message: T) throws {
        send(try Wire.encode(message))
    }

    func receive<T: Decodable>(_ type: T.Type, timeout: Duration) async throws -> T {
        try Wire.decode(type, from: try await receive(timeout: timeout))
    }

    func receive(timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CompanionError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CompanionError.timeout }
            return first
        }
    }
}

/// Frames over a TCP `NWConnection`.
final class NetworkFrameTransport: FrameTransport, @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "TVCompanion.connection")
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var frames: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var failure: (any Error)?
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits until it's ready.
    func start(timeout: Duration = .seconds(10)) async throws {
        let once = OnceFlag()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    self.connection.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            if once.claim() { continuation.resume() }
                            self?.readLoop()
                        case .failed(let error):
                            if once.claim() { continuation.resume(throwing: CompanionError.network(error.localizedDescription)) }
                            self?.fail(CompanionError.network(error.localizedDescription))
                        case .waiting(let error):
                            if once.claim() { continuation.resume(throwing: CompanionError.network(error.localizedDescription)) }
                        case .cancelled:
                            if once.claim() { continuation.resume(throwing: CompanionError.connectionClosed) }
                            self?.fail(CompanionError.connectionClosed)
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CompanionError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ payload: Data) {
        connection.send(content: FrameDecoder.frame(payload), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(CompanionError.network(error.localizedDescription)) }
        })
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if !frames.isEmpty {
                        continuation.resume(returning: frames.removeFirst())
                    } else if let failure {
                        continuation.resume(throwing: failure)
                    } else {
                        waiter = continuation
                    }
                }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    func close() {
        fail(CompanionError.connectionClosed)
        connection.cancel()
    }

    var isClosed: Bool { lock.withLock { closed } }

    private func readLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let decoded = try self.lock.withLock { try self.decoder.append(data) }
                    for frame in decoded { self.deliver(frame) }
                } catch {
                    self.fail(error)
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.fail(CompanionError.network(error.localizedDescription))
            } else if isComplete {
                self.fail(CompanionError.connectionClosed)
            } else {
                self.readLoop()
            }
        }
    }

    private func deliver(_ frame: Data) {
        let waiting = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            if let waiter {
                self.waiter = nil
                return waiter
            }
            frames.append(frame)
            return nil
        }
        waiting?.resume(returning: frame)
    }

    private func fail(_ error: any Error) {
        let waiting = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            closed = true
            if failure == nil { failure = error }
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(throwing: error)
    }
}

/// A connected pair of in-memory transports, for tests.
final class PipeTransport: FrameTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var closed = false
    weak var peer: PipeTransport?

    static func pair() -> (PipeTransport, PipeTransport) {
        let a = PipeTransport()
        let b = PipeTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ payload: Data) {
        peer?.deliver(payload)
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if !inbox.isEmpty {
                        continuation.resume(returning: inbox.removeFirst())
                    } else if closed {
                        continuation.resume(throwing: CompanionError.connectionClosed)
                    } else {
                        waiter = continuation
                    }
                }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    func close() {
        shutdown()
        peer?.shutdown()
    }

    var isClosed: Bool { lock.withLock { closed } }

    fileprivate func deliver(_ payload: Data) {
        let waiting = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            guard !closed else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            inbox.append(payload)
            return nil
        }
        waiting?.resume(returning: payload)
    }

    fileprivate func shutdown() {
        let waiting = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            closed = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(throwing: CompanionError.connectionClosed)
    }
}

/// A flag that can be claimed once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
