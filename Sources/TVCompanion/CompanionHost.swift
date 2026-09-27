import CryptoKit
import Foundation
import Network
import Observation

/// The TV side: advertises itself on the local network, pairs with phones,
/// and asks them for text or credentials.
///
/// ```swift
/// @State private var companion = CompanionHost(name: "Living Room", linkScheme: "myapp")
///
/// .task { try? companion.start() }
///
/// // Settings → Pair iPhone
/// CompanionPairingView(host: companion)
///
/// // A text field's "Use iPhone" button
/// let address = try await companion.requestText(TextInputRequest(prompt: "Server Address", contentType: .url))
/// ```
@MainActor
@Observable
public final class CompanionHost {
    public let name: String
    public let serviceType: String
    public let linkScheme: String

    /// What the pairing screen should show.
    public private(set) var pairingState: PairingState = .closed
    /// The URL for the pairing QR code, while pairing is open.
    public private(set) var pairingLink: URL?
    /// Paired devices currently connected.
    public private(set) var connectedDevices: [PairedDevice] = []
    /// Every paired device.
    public private(set) var pairedDevices: [PairedDevice] = []
    public private(set) var isRunning = false
    /// The most recent listener or connection error.
    public private(set) var lastError: CompanionError?

    @ObservationIgnored private let store: any PairingStore
    @ObservationIgnored private var identity: CompanionIdentity?
    @ObservationIgnored private var gate: PairingGate!
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [String: CompanionSession] = [:]
    @ObservationIgnored private var handshakes: [UUID: NetworkFrameTransport] = [:]
    @ObservationIgnored private let messageStream = AsyncStream<(PairedDevice, CompanionMessage)>.makeStream()
    @ObservationIgnored private let requestStream = AsyncStream<(PairedDevice, CompanionRequest)>.makeStream()
    @ObservationIgnored private(set) var port: UInt16?

    /// - Parameters:
    ///   - name: Shown on phones, for example the room name.
    ///   - serviceType: The Bonjour service type. Use one unique to your
    ///     app (`_myapp-companion._tcp`) and list it in the phone app's
    ///     `NSBonjourServices`.
    ///   - linkScheme: The URL scheme for pairing QR codes, normally your
    ///     phone app's scheme.
    public init(
        name: String,
        serviceType: String = "_tvcompanion._tcp",
        linkScheme: String = "tvcompanion",
        store: any PairingStore = KeychainPairingStore()
    ) {
        self.name = name
        self.serviceType = serviceType
        self.linkScheme = linkScheme
        self.store = store
        gate = PairingGate { [weak self] state, secret in
            Task { @MainActor in self?.pairingStateChanged(state, secret: secret) }
        }
    }

    /// Messages from any connected device.
    public var messages: AsyncStream<(PairedDevice, CompanionMessage)> { messageStream.stream }
    /// Requests from any connected device.
    public var requests: AsyncStream<(PairedDevice, CompanionRequest)> { requestStream.stream }

    // MARK: - Lifecycle

    /// Starts advertising and accepting connections.
    public func start() throws {
        guard !isRunning else { return }
        let identity = try store.identity()
        self.identity = identity
        pairedDevices = try store.pairedDevices()

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: name, type: serviceType, txtRecord: Self.txtRecord(id: identity.id))
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerStateChanged(state) }
        }
        listener.start(queue: .main)
        self.listener = listener
        isRunning = true
    }

    /// Waits until the listener is accepting connections.
    func waitUntilReady() async throws {
        for _ in 0..<500 {
            if port != nil { return }
            if let lastError { throw lastError }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CompanionError.timeout
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
        for session in sessions.values { Task { await session.close() } }
        for transport in handshakes.values { transport.close() }
        handshakes.removeAll()
        sessions.removeAll()
        connectedDevices = []
        Task { await gate.close() }
    }

    // MARK: - Pairing

    /// Starts accepting new pairings. Call when the pairing screen appears.
    public func openPairing() {
        Task { await gate.open() }
    }

    /// Stops accepting new pairings. Call when the pairing screen closes.
    public func closePairing() {
        Task { await gate.close() }
    }

    /// Confirms that the code shown matches the one on the user's device.
    public func confirmPairing() {
        Task { await gate.confirm() }
    }

    /// Rejects the pairing: the codes don't match, or it wasn't the user.
    public func rejectPairing() {
        Task { await gate.reject() }
    }

    /// Removes a pairing and disconnects the device.
    public func unpair(_ device: PairedDevice) {
        try? store.removeDevice(id: device.id)
        pairedDevices.removeAll { $0.id == device.id }
        if let session = sessions.removeValue(forKey: device.id) {
            Task { await session.close() }
        }
        connectedDevices.removeAll { $0.id == device.id }
    }

    // MARK: - Requests

    /// The session for a connected device.
    public func session(for device: PairedDevice) -> CompanionSession? {
        sessions[device.id]
    }

    /// Asks connected devices to type text. The first device to answer
    /// wins; the request is withdrawn from the others.
    public func requestText(_ request: TextInputRequest, timeout: Duration = .seconds(300)) async throws -> String {
        try await firstAnswer { try await $0.requestText(request, timeout: timeout) }
    }

    /// Asks connected devices for credentials. The first answer wins.
    public func requestCredentials(_ request: CredentialRequest, timeout: Duration = .seconds(300)) async throws -> CompanionCredential {
        try await firstAnswer { try await $0.requestCredentials(request, timeout: timeout) }
    }

    /// Sends a message to every connected device.
    public func broadcast<T: Encodable & Sendable>(_ type: String, _ value: T) async {
        for session in sessions.values {
            try? await session.send(type, value)
        }
    }

    private func firstAnswer<T: Sendable>(_ ask: @escaping @Sendable (CompanionSession) async throws -> T) async throws -> T {
        let targets = Array(sessions.values)
        guard !targets.isEmpty else { throw CompanionError.noConnectedDevices }
        return try await withThrowingTaskGroup(of: T.self) { group in
            for session in targets {
                group.addTask { try await ask(session) }
            }
            var lastError: any Error = CompanionError.declined
            while let result = await group.nextResult() {
                switch result {
                case .success(let value):
                    group.cancelAll()
                    return value
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard let identity else { connection.cancel(); return }
        let transport = NetworkFrameTransport(connection: connection)
        let handshakeID = UUID()
        handshakes[handshakeID] = transport
        let store = store
        let gate = gate!
        let name = name
        Task {
            defer { Task { @MainActor in self.handshakes[handshakeID] = nil } }
            do {
                try await transport.start()
                let result = try await HandshakeRunner.host(over: transport, identity: identity, name: name, store: store, gate: gate)
                let session = CompanionSession(transport: transport, channel: result.channel, peer: result.peer)
                await self.register(session)
            } catch {
                transport.close()
            }
        }
    }

    private func register(_ session: CompanionSession) async {
        let device = session.peer
        if let previous = sessions[device.id] {
            await previous.close()
        }
        sessions[device.id] = session
        pairedDevices = (try? store.pairedDevices()) ?? pairedDevices
        connectedDevices.removeAll { $0.id == device.id }
        connectedDevices.append(device)
        await session.start()

        let messages = messageStream.continuation
        let requests = requestStream.continuation
        Task {
            for await message in session.messages { messages.yield((device, message)) }
        }
        Task {
            for await request in session.requests { requests.yield((device, request)) }
        }
        Task { [weak self] in
            for await _ in session.closed {}
            self?.sessionClosed(session)
        }
    }

    private func sessionClosed(_ session: CompanionSession) {
        guard sessions[session.peer.id] === session else { return }
        sessions[session.peer.id] = nil
        connectedDevices.removeAll { $0.id == session.peer.id }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            lastError = nil
        case .failed(let error):
            lastError = .network(error.localizedDescription)
            isRunning = false
        case .waiting(let error):
            lastError = .network(error.localizedDescription)
        default:
            break
        }
    }

    private func pairingStateChanged(_ state: PairingState, secret: SymmetricKey?) {
        pairingState = state
        if case .paired = state {
            pairedDevices = (try? store.pairedDevices()) ?? pairedDevices
        }
        switch state {
        case .waiting, .paired:
            if let secret, let identity {
                pairingLink = PairingLink(hostID: identity.id, hostName: name, serviceType: serviceType, secret: secret).url(scheme: linkScheme)
            }
        case .closed, .locked:
            pairingLink = nil
        case .showingCode:
            break
        }
    }

    static func txtRecord(id: String) -> NWTXTRecord {
        var record = NWTXTRecord()
        record["id"] = id
        record["v"] = String(Handshake.version)
        return record
    }
}
