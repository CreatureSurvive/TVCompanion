import CryptoKit
import Foundation

/// The host's first reply: its hello, or a rejection.
struct HostResponse: Codable, Sendable {
    var hello: HostHello?
    var rejection: HandshakeRejection?
}

/// Runs the handshake over a transport. Returns the encrypted channel and
/// the authenticated peer.
enum HandshakeRunner {
    static let stepTimeout: Duration = .seconds(15)
    static let codeEntryTimeout: Duration = .seconds(180)

    struct Result: Sendable {
        var channel: SecureChannel
        var peer: PairedDevice
    }

    // MARK: - Client

    /// - Parameters:
    ///   - verifyCode: For `pairCode`, called with the expected code and the
    ///     host's name. It must return once the user has entered a matching
    ///     code, or throw.
    ///   - expectedHost: For `resume`, the paired host. For `pairSecret`,
    ///     the host ID from the QR code is checked instead.
    static func client(
        over transport: any FrameTransport,
        mode: HandshakeMode,
        identity: CompanionIdentity,
        name: String,
        secret: SymmetricKey? = nil,
        expectedHostID: String? = nil,
        expectedHost: PairedDevice? = nil,
        verifyCode: @Sendable (_ code: String, _ hostName: String) async throws -> Void = { _, _ in }
    ) async throws -> Result {
        var transcript = Transcript(mode: mode)
        let ephemeral = Handshake.Ephemeral()

        let hello = ClientHello(
            version: Handshake.version,
            mode: mode,
            clientName: name,
            clientID: mode == .resume ? identity.id : nil,
            commitment: ephemeral.commitment
        )
        let helloData = try Wire.encode(hello)
        transcript.append(helloData)
        transport.send(helloData)

        let responseData = try await transport.receive(timeout: stepTimeout)
        let response = try Wire.decode(HostResponse.self, from: responseData)
        if let rejection = response.rejection {
            throw CompanionError.rejection(rejection.reason)
        }
        guard let hostHello = response.hello, hostHello.version == Handshake.version, hostHello.nonce.count == Handshake.nonceSize else {
            throw CompanionError.protocolViolation("unexpected host hello")
        }
        if let expectedHostID, hostHello.hostID != expectedHostID {
            throw CompanionError.handshakeFailed("connected to a different TV")
        }
        if let expectedHost, hostHello.hostID != expectedHost.id {
            throw CompanionError.handshakeFailed("connected to a different TV")
        }
        transcript.append(responseData)

        let reveal = ClientReveal(ephemeralKey: ephemeral.publicKey, nonce: ephemeral.nonce)
        let revealData = try Wire.encode(reveal)
        transcript.append(revealData)
        transport.send(revealData)

        let keys = try Handshake.deriveKeys(
            privateKey: ephemeral.privateKey,
            peerPublicKey: hostHello.ephemeralKey,
            transcript: transcript.digest,
            secret: mode == .pairSecret ? secret : nil
        )
        var channel = SecureChannel(keys: keys, role: .client)

        switch mode {
        case .pairCode, .pairSecret:
            if mode == .pairCode {
                try await verifyCode(keys.pairingCode, hostHello.hostName)
            }
            try sendSealed(ConfirmMessage(mac: Handshake.confirmationMAC(keys, role: .client)), over: transport, channel: &channel)
            // In code pairing the host answers only after its user confirms.
            let hostConfirm = try await receiveSealed(ConfirmMessage.self, over: transport, channel: &channel, timeout: mode == .pairCode ? codeEntryTimeout : stepTimeout)
            guard Handshake.verifyConfirmation(hostConfirm.mac, keys: keys, role: .host) else {
                throw CompanionError.handshakeFailed("the TV couldn't be verified")
            }
            try sendSealed(IdentityMessage(name: name, publicKey: identity.publicKey), over: transport, channel: &channel)
            let hostIdentity = try await receiveSealed(IdentityMessage.self, over: transport, channel: &channel, timeout: stepTimeout)
            let host = PairedDevice(name: hostIdentity.name, publicKey: hostIdentity.publicKey)
            guard host.id == hostHello.hostID else {
                throw CompanionError.handshakeFailed("the TV's identity doesn't match")
            }
            return Result(channel: channel, peer: host)

        case .resume:
            guard let expectedHost else { throw CompanionError.notPaired }
            let signature = try identity.sign(Handshake.signedData(keys, role: .client))
            try sendSealed(AuthMessage(signature: signature), over: transport, channel: &channel)
            let hostAuth = try await receiveSealed(AuthMessage.self, over: transport, channel: &channel, timeout: stepTimeout)
            guard expectedHost.verify(hostAuth.signature, for: Handshake.signedData(keys, role: .host)) else {
                throw CompanionError.handshakeFailed("the TV's signature is invalid")
            }
            return Result(channel: channel, peer: expectedHost)
        }
    }

    // MARK: - Host

    static func host(
        over transport: any FrameTransport,
        identity: CompanionIdentity,
        name: String,
        store: any PairingStore,
        gate: PairingGate
    ) async throws -> Result {
        let helloData = try await transport.receive(timeout: stepTimeout)
        let hello = try Wire.decode(ClientHello.self, from: helloData)
        guard hello.version == Handshake.version, hello.commitment.count == 32 else {
            reject(transport, "unsupported version")
            throw CompanionError.protocolViolation("unsupported client version")
        }

        var knownClient: PairedDevice?
        var secret: SymmetricKey?
        var attempt: PairingGate.Attempt?
        switch hello.mode {
        case .resume:
            knownClient = try store.pairedDevices().first { $0.id == hello.clientID }
            guard knownClient != nil else {
                reject(transport, CompanionError.notPaired.rejectionReason)
                throw CompanionError.notPaired
            }
        case .pairCode, .pairSecret:
            do {
                let started = try await gate.begin(mode: hello.mode, clientName: hello.clientName)
                attempt = started
                secret = started.secret
            } catch {
                reject(transport, (error as? CompanionError)?.rejectionReason ?? "pairing unavailable")
                throw error
            }
        }

        do {
            var transcript = Transcript(mode: hello.mode)
            transcript.append(helloData)
            let ephemeral = Handshake.Ephemeral()
            let response = HostResponse(hello: HostHello(
                version: Handshake.version,
                hostName: name,
                hostID: identity.id,
                ephemeralKey: ephemeral.publicKey,
                nonce: ephemeral.nonce
            ))
            let responseData = try Wire.encode(response)
            transcript.append(responseData)
            transport.send(responseData)

            let revealData = try await transport.receive(timeout: stepTimeout)
            let reveal = try Wire.decode(ClientReveal.self, from: revealData)
            guard Handshake.verifyCommitment(hello.commitment, reveal: reveal) else {
                throw CompanionError.handshakeFailed("the client's key doesn't match its commitment")
            }
            transcript.append(revealData)

            let keys = try Handshake.deriveKeys(
                privateKey: ephemeral.privateKey,
                peerPublicKey: reveal.ephemeralKey,
                transcript: transcript.digest,
                secret: secret
            )
            var channel = SecureChannel(keys: keys, role: .host)

            switch hello.mode {
            case .pairCode, .pairSecret:
                if hello.mode == .pairCode, let attempt {
                    await gate.showCode(keys.pairingCode, deviceName: hello.clientName, for: attempt)
                    try await withTimeout(codeEntryTimeout) { try await gate.waitForConfirmation(attempt) }
                }
                let clientConfirm: ConfirmMessage
                do {
                    clientConfirm = try await receiveSealed(ConfirmMessage.self, over: transport, channel: &channel, timeout: hello.mode == .pairCode ? codeEntryTimeout : stepTimeout)
                } catch CompanionError.protocolViolation {
                    // Keys derived with a different secret can't open the message.
                    throw CompanionError.incorrectCode
                }
                guard Handshake.verifyConfirmation(clientConfirm.mac, keys: keys, role: .client) else {
                    throw CompanionError.incorrectCode
                }
                try sendSealed(ConfirmMessage(mac: Handshake.confirmationMAC(keys, role: .host)), over: transport, channel: &channel)
                let clientIdentity = try await receiveSealed(IdentityMessage.self, over: transport, channel: &channel, timeout: stepTimeout)
                try sendSealed(IdentityMessage(name: name, publicKey: identity.publicKey), over: transport, channel: &channel)
                let client = PairedDevice(name: clientIdentity.name, publicKey: clientIdentity.publicKey)
                try store.save(client)
                if let attempt { await gate.succeed(attempt, device: client) }
                return Result(channel: channel, peer: client)

            case .resume:
                guard let knownClient else { throw CompanionError.notPaired }
                let clientAuth = try await receiveSealed(AuthMessage.self, over: transport, channel: &channel, timeout: stepTimeout)
                guard knownClient.verify(clientAuth.signature, for: Handshake.signedData(keys, role: .client)) else {
                    throw CompanionError.handshakeFailed("the device's signature is invalid")
                }
                let signature = try identity.sign(Handshake.signedData(keys, role: .host))
                try sendSealed(AuthMessage(signature: signature), over: transport, channel: &channel)
                return Result(channel: channel, peer: knownClient)
            }
        } catch {
            if let attempt { await gate.fail(attempt, error: error) }
            throw error
        }
    }

    // MARK: - Helpers

    static func sendSealed<T: Encodable>(_ message: T, over transport: any FrameTransport, channel: inout SecureChannel) throws {
        transport.send(try channel.seal(Wire.encode(message)))
    }

    static func receiveSealed<T: Decodable>(_ type: T.Type, over transport: any FrameTransport, channel: inout SecureChannel, timeout: Duration) async throws -> T {
        let data = try await transport.receive(timeout: timeout)
        return try Wire.decode(type, from: channel.open(data))
    }

    static func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CompanionError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CompanionError.timeout }
            return result
        }
    }

    static func reject(_ transport: any FrameTransport, _ reason: String) {
        if let data = try? Wire.encode(HostResponse(rejection: HandshakeRejection(reason: reason))) {
            transport.send(data)
        }
    }
}

extension CompanionError {
    var rejectionReason: String {
        switch self {
        case .notPaired: "notPaired"
        case .pairingNotAvailable: "pairingNotAvailable"
        default: "rejected"
        }
    }

    static func rejection(_ reason: String) -> CompanionError {
        switch reason {
        case "notPaired": .notPaired
        case "pairingNotAvailable": .pairingNotAvailable
        default: .handshakeFailed(reason)
        }
    }
}
