import CryptoKit
import Foundation
import Network

/// A TV found on the local network.
public struct DiscoveredHost: Sendable, Hashable, Identifiable {
    /// The host's identity, or its service name if it didn't publish one.
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    /// Whether this device has already paired with the host.
    public let isPaired: Bool

    public init(id: String, name: String, endpoint: NWEndpoint, isPaired: Bool) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isPaired = isPaired
    }
}

/// The phone side: finds TVs, pairs with them, and answers their requests.
///
/// ```swift
/// let companion = CompanionClient(name: UIDevice.current.name, serviceType: "_myapp-companion._tcp")
///
/// for await hosts in companion.discover() { self.hosts = hosts }
///
/// // Code pairing
/// let attempt = companion.pair(with: host)
/// let hostName = try await attempt.codeRequested()   // show a code field
/// let session = try await attempt.submit(code: typedCode)
///
/// // Later
/// let session = try await companion.connect(to: host)
/// for await request in session.requests {
///     if let text = request.textInput { present(text, answering: request) }
/// }
/// ```
///
/// The phone app needs `NSLocalNetworkUsageDescription` and the service type
/// in `NSBonjourServices`.
public final class CompanionClient: Sendable {
    public let name: String
    public let serviceType: String
    let store: any PairingStore

    public init(name: String, serviceType: String = "_tvcompanion._tcp", store: any PairingStore = KeychainPairingStore()) {
        self.name = name
        self.serviceType = serviceType
        self.store = store
    }

    /// TVs this device has paired with.
    public func pairedHosts() throws -> [PairedDevice] {
        try store.pairedDevices()
    }

    /// Forgets a TV. It must be paired again to connect.
    public func unpair(_ host: PairedDevice) throws {
        try store.removeDevice(id: host.id)
    }

    // MARK: - Discovery

    /// Streams the TVs currently advertising on the local network.
    public func discover() -> AsyncStream<[DiscoveredHost]> {
        let serviceType = serviceType
        let store = store
        return AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { results, _ in
                let paired = Set(((try? store.pairedDevices()) ?? []).map(\.id))
                let hosts = results.compactMap { result -> DiscoveredHost? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    var id = name
                    if case .bonjour(let record) = result.metadata, let published = record["id"] { id = published }
                    return DiscoveredHost(id: id, name: name, endpoint: result.endpoint, isPaired: paired.contains(id))
                }
                continuation.yield(hosts.sorted { $0.name < $1.name })
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "TVCompanion.browser"))
        }
    }

    /// Finds a host by ID, waiting up to `timeout`.
    public func find(hostID: String, timeout: Duration = .seconds(10)) async throws -> DiscoveredHost {
        let hosts = discover()
        return try await HandshakeRunner.withTimeout(timeout) {
            for await list in hosts {
                if let host = list.first(where: { $0.id == hostID }) { return host }
            }
            throw CompanionError.connectionClosed
        }
    }

    // MARK: - Pairing and connecting

    /// Starts pairing with a code shown on the TV.
    public func pair(with host: DiscoveredHost) -> PairingAttempt {
        pair(endpoint: host.endpoint)
    }

    func pair(endpoint: NWEndpoint) -> PairingAttempt {
        let attempt = PairingAttempt()
        let store = store
        let name = name
        Task {
            do {
                let identity = try store.identity()
                let transport = try await Self.open(endpoint)
                await attempt.attach(transport)
                let result = try await HandshakeRunner.client(
                    over: transport, mode: .pairCode, identity: identity, name: name,
                    verifyCode: { code, hostName in try await attempt.waitForMatchingCode(code, hostName: hostName) }
                )
                try store.save(result.peer)
                let session = CompanionSession(transport: transport, channel: result.channel, peer: result.peer)
                await session.start()
                await attempt.finish(.success(session))
            } catch {
                await attempt.finish(.failure(error))
            }
        }
        return attempt
    }

    /// Pairs using a scanned QR code. No code entry is needed.
    public func pair(using link: PairingLink, host: DiscoveredHost? = nil) async throws -> CompanionSession {
        let target = if let host { host } else { try await find(hostID: link.hostID) }
        return try await pair(endpoint: target.endpoint, link: link)
    }

    func pair(endpoint: NWEndpoint, link: PairingLink) async throws -> CompanionSession {
        let identity = try store.identity()
        let transport = try await Self.open(endpoint)
        do {
            let result = try await HandshakeRunner.client(
                over: transport, mode: .pairSecret, identity: identity, name: name,
                secret: link.secret, expectedHostID: link.hostID
            )
            try store.save(result.peer)
            let session = CompanionSession(transport: transport, channel: result.channel, peer: result.peer)
            await session.start()
            return session
        } catch {
            transport.close()
            throw error
        }
    }

    /// Connects to a paired TV.
    public func connect(to host: DiscoveredHost) async throws -> CompanionSession {
        guard let paired = try store.pairedDevices().first(where: { $0.id == host.id }) else { throw CompanionError.notPaired }
        return try await connect(endpoint: host.endpoint, host: paired)
    }

    func connect(endpoint: NWEndpoint, host: PairedDevice) async throws -> CompanionSession {
        let identity = try store.identity()
        let transport = try await Self.open(endpoint)
        do {
            let result = try await HandshakeRunner.client(over: transport, mode: .resume, identity: identity, name: name, expectedHost: host)
            let session = CompanionSession(transport: transport, channel: result.channel, peer: result.peer)
            await session.start()
            return session
        } catch CompanionError.notPaired {
            // The TV forgot this device; forget it too.
            try? store.removeDevice(id: host.id)
            transport.close()
            throw CompanionError.notPaired
        } catch {
            transport.close()
            throw error
        }
    }

    static func open(_ endpoint: NWEndpoint) async throws -> NetworkFrameTransport {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        let transport = NetworkFrameTransport(connection: NWConnection(to: endpoint, using: parameters))
        do {
            try await transport.start()
        } catch {
            transport.close()
            throw error
        }
        return transport
    }
}

/// A pairing in progress that needs the code shown on the TV.
public actor PairingAttempt {
    public static let maximumCodeAttempts = 5

    private var expectedCode: String?
    private(set) public var hostName: String?
    private var codeWaiter: CheckedContinuation<Void, any Error>?
    private var codeRequestWaiters: [CheckedContinuation<String, any Error>] = []
    private var resultWaiters: [CheckedContinuation<CompanionSession, any Error>] = []
    private var result: Result<CompanionSession, any Error>?
    private var remainingAttempts = PairingAttempt.maximumCodeAttempts
    private var transport: (any FrameTransport)?

    init() {}

    /// Waits until the TV is showing its code, and returns the TV's name.
    /// Show a code field when this returns.
    public func codeRequested() async throws -> String {
        if let hostName, expectedCode != nil { return hostName }
        if case .failure(let error) = result { throw error }
        return try await withCheckedThrowingContinuation { codeRequestWaiters.append($0) }
    }

    /// Submits the code the user typed. On a mismatch this throws
    /// ``CompanionError/incorrectCode`` and the user can try again (up to
    /// five times). On a match it completes pairing; the user must also
    /// confirm on the TV.
    public func submit(code: String) async throws -> CompanionSession {
        guard let expectedCode, let waiter = codeWaiter else {
            if case .failure(let error) = result { throw error }
            throw CompanionError.protocolViolation("the TV isn't showing a code yet")
        }
        let typed = code.filter(\.isNumber)
        guard constantTimeEqual(Data(typed.utf8), Data(expectedCode.utf8)) else {
            remainingAttempts -= 1
            if remainingAttempts <= 0 {
                codeWaiter = nil
                waiter.resume(throwing: CompanionError.incorrectCode)
            }
            throw CompanionError.incorrectCode
        }
        codeWaiter = nil
        waiter.resume()
        return try await session()
    }

    /// Waits for the pairing to finish.
    public func session() async throws -> CompanionSession {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { resultWaiters.append($0) }
    }

    /// Abandons the pairing. Does nothing once pairing has finished, so
    /// the session it produced stays connected.
    public func cancel() {
        guard result == nil else { return }
        codeWaiter?.resume(throwing: CancellationError())
        codeWaiter = nil
        transport?.close()
    }

    // MARK: - Internal

    func attach(_ transport: any FrameTransport) {
        self.transport = transport
    }

    func waitForMatchingCode(_ code: String, hostName: String) async throws {
        expectedCode = code
        self.hostName = hostName
        for waiter in codeRequestWaiters { waiter.resume(returning: hostName) }
        codeRequestWaiters.removeAll()
        try await withCheckedThrowingContinuation { codeWaiter = $0 }
    }

    func finish(_ outcome: Result<CompanionSession, any Error>) {
        guard result == nil else { return }
        result = outcome
        if case .failure = outcome { transport?.close() }
        for waiter in resultWaiters { waiter.resume(with: outcome) }
        resultWaiters.removeAll()
        if case .failure(let error) = outcome {
            for waiter in codeRequestWaiters { waiter.resume(throwing: error) }
            codeRequestWaiters.removeAll()
            codeWaiter?.resume(throwing: error)
            codeWaiter = nil
        }
    }
}
