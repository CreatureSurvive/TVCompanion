import CryptoKit
import Foundation
import Testing
@testable import TVCompanion

/// Collects what the host's pairing screen would show.
final class ScreenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PairingState] = []
    private var secret: SymmetricKey?

    var onChange: @Sendable (PairingState, SymmetricKey?) -> Void {
        { [weak self] state, secret in
            self?.lock.withLock {
                self?.states.append(state)
                if let secret { self?.secret = secret }
            }
        }
    }

    var latest: PairingState? { lock.withLock { states.last } }
    var currentSecret: SymmetricKey? { lock.withLock { secret } }
    var all: [PairingState] { lock.withLock { states } }

    /// Waits for the host to display a code.
    func shownCode() async throws -> String {
        for _ in 0..<500 {
            let code = lock.withLock { () -> String? in
                for state in states.reversed() {
                    if case .showingCode(let code, _) = state { return code }
                }
                return nil
            }
            if let code { return code }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CompanionError.timeout
    }
}

struct Peer {
    let store = InMemoryPairingStore()
    var identity: CompanionIdentity { try! store.identity() }
}

@Suite("Handshake", .timeLimit(.minutes(1)))
struct HandshakeTests {
    /// The user compares the code on the TV with the phone (typing it on the
    /// phone), and if they match, presses Confirm on the TV.
    func userChecksCodes(_ screen: ScreenRecorder, _ gate: PairingGate) -> @Sendable (String, String) async throws -> Void {
        { expected, _ in
            let shown = try await screen.shownCode()
            guard constantTimeEqual(Data(shown.utf8), Data(expected.utf8)) else {
                await gate.reject()
                throw CompanionError.incorrectCode
            }
            await gate.confirm()
        }
    }

    @Test func pairsWithACodeAndStoresBothSides() async throws {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer()
        let screen = ScreenRecorder()
        let gate = PairingGate(onChange: screen.onChange)
        await gate.open()

        async let hostResult = HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "Living Room", store: tv.store, gate: gate)
        let clientResult = try await HandshakeRunner.client(over: clientPipe, mode: .pairCode, identity: phone.identity, name: "Dan's iPhone", verifyCode: userChecksCodes(screen, gate))
        let host = try await hostResult

        #expect(clientResult.peer.id == tv.identity.id)
        #expect(clientResult.peer.name == "Living Room")
        #expect(host.peer.id == phone.identity.id)
        #expect(try tv.store.pairedDevices().map(\.name) == ["Dan's iPhone"])
        #expect(screen.all.contains { if case .showingCode(_, "Dan's iPhone") = $0 { true } else { false } })
        #expect(screen.latest == .paired(host.peer))

        // The channel works in both directions.
        var clientChannel = clientResult.channel
        var hostChannel = host.channel
        #expect(try hostChannel.open(clientChannel.seal(Data("hello tv".utf8))) == Data("hello tv".utf8))
        #expect(try clientChannel.open(hostChannel.seal(Data("hello phone".utf8))) == Data("hello phone".utf8))
    }

    @Test func codesAreSixDigitsAndDifferPerSession() throws {
        var codes = Set<String>()
        for _ in 0..<20 {
            let a = Handshake.Ephemeral(), b = Handshake.Ephemeral()
            let transcript = randomBytes(32)
            let keysA = try Handshake.deriveKeys(privateKey: a.privateKey, peerPublicKey: b.publicKey, transcript: transcript, secret: nil)
            let keysB = try Handshake.deriveKeys(privateKey: b.privateKey, peerPublicKey: a.publicKey, transcript: transcript, secret: nil)
            #expect(keysA.pairingCode == keysB.pairingCode)
            #expect(keysA.pairingCode.count == 6 && keysA.pairingCode.allSatisfy(\.isNumber))
            codes.insert(keysA.pairingCode)
        }
        #expect(codes.count > 15)
    }

    /// An attacker in the middle runs one handshake with the phone (posing as
    /// the TV) and one with the TV (posing as the phone). The user types the
    /// code shown on the real TV, which doesn't match the phone's session.
    @Test func activeManInTheMiddleIsDetected() async throws {
        let (phonePipe, malloryFacingPhone) = PipeTransport.pair()
        let (malloryFacingTV, tvPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer(), mallory = Peer()
        let tvScreen = ScreenRecorder()
        let tvGate = PairingGate(onChange: tvScreen.onChange)
        await tvGate.open()
        let malloryGate = PairingGate()
        await malloryGate.open()

        // Mallory impersonates the TV to the phone...
        let fakeTV = Task {
            try await HandshakeRunner.host(over: malloryFacingPhone, identity: mallory.identity, name: "Living Room", store: mallory.store, gate: malloryGate)
        }
        // ...and the phone to the TV, "confirming" whatever code it computes.
        let fakePhone = Task {
            try await HandshakeRunner.client(over: malloryFacingTV, mode: .pairCode, identity: mallory.identity, name: "Dan's iPhone")
        }
        let realTV = Task {
            try await HandshakeRunner.host(over: tvPipe, identity: tv.identity, name: "Living Room", store: tv.store, gate: tvGate)
        }

        await #expect(throws: CompanionError.incorrectCode) {
            try await HandshakeRunner.client(over: phonePipe, mode: .pairCode, identity: phone.identity, name: "Dan's iPhone", verifyCode: userChecksCodes(tvScreen, tvGate))
        }
        // The phone saw a mismatch, so the user rejects on the TV too.
        await #expect(throws: CompanionError.declined) { try await realTV.value }
        #expect(try phone.store.pairedDevices().isEmpty)
        #expect(try tv.store.pairedDevices().isEmpty, "the attacker isn't paired with the TV either")
        phonePipe.close()
        malloryFacingTV.close()
        fakeTV.cancel()
        _ = try? await fakePhone.value
    }

    /// Another device on the network tries to pair while the pairing screen
    /// is open. It can compute the code itself, but the TV waits for its own
    /// user, who sees a code their phone isn't showing and rejects it.
    @Test func rogueClientNeedsTheTVUsersApproval() async throws {
        let (roguePipe, hostPipe) = PipeTransport.pair()
        let tv = Peer(), rogue = Peer()
        let screen = ScreenRecorder()
        let gate = PairingGate(onChange: screen.onChange)
        await gate.open()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate) }
        let attacker = Task {
            try await HandshakeRunner.client(over: roguePipe, mode: .pairCode, identity: rogue.identity, name: "Dan's iPhone")
        }
        _ = try await screen.shownCode()
        await gate.reject()
        await #expect(throws: CompanionError.declined) { try await host.value }
        hostPipe.close()
        _ = try? await attacker.value
        #expect(try tv.store.pairedDevices().isEmpty)
    }

    @Test func confirmationCanArriveBeforeTheHandshakeAsks() async throws {
        let gate = PairingGate()
        await gate.open()
        let attempt = try await gate.begin(mode: .pairCode, clientName: "Phone")
        await gate.confirm()
        try await gate.waitForConfirmation(attempt)
        await gate.fail(attempt, error: CompanionError.connectionClosed)
        let second = try await gate.begin(mode: .pairCode, clientName: "Phone")
        await gate.reject()
        await #expect(throws: CompanionError.declined) { try await gate.waitForConfirmation(second) }
    }

    @Test func revealMustMatchTheCommitment() async throws {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let tv = Peer()
        let gate = PairingGate()
        await gate.open()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate) }

        let committed = Handshake.Ephemeral()
        let swapped = Handshake.Ephemeral()
        clientPipe.send(try Wire.encode(ClientHello(version: 1, mode: .pairCode, clientName: "Evil", clientID: nil, commitment: committed.commitment)))
        _ = try await clientPipe.receive()
        // Reveal a different key than the one committed to.
        clientPipe.send(try Wire.encode(ClientReveal(ephemeralKey: swapped.publicKey, nonce: swapped.nonce)))
        await #expect(throws: CompanionError.self) { try await host.value }
    }

    @Test func pairsWithTheQRSecret() async throws {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer()
        let screen = ScreenRecorder()
        let gate = PairingGate(onChange: screen.onChange)
        await gate.open()
        let secret = try #require(screen.currentSecret)

        async let hostResult = HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate)
        let result = try await HandshakeRunner.client(over: clientPipe, mode: .pairSecret, identity: phone.identity, name: "Phone", secret: secret, expectedHostID: tv.identity.id)
        _ = try await hostResult
        #expect(result.peer.id == tv.identity.id)
        #expect(!screen.all.contains { if case .showingCode = $0 { true } else { false } }, "no code is needed with a QR secret")
        let rotated = try #require(screen.currentSecret)
        #expect(rotated != secret, "secrets are single-use")
    }

    @Test func wrongQRSecretFails() async throws {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer()
        let gate = PairingGate()
        await gate.open()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate) }
        let client = Task {
            try await HandshakeRunner.client(over: clientPipe, mode: .pairSecret, identity: phone.identity, name: "Phone", secret: SymmetricKey(size: .bits128))
        }
        await #expect(throws: CompanionError.incorrectCode) { try await host.value }
        hostPipe.close()
        await #expect(throws: (any Error).self) { try await client.value }
        #expect(try tv.store.pairedDevices().isEmpty)
    }

    @Test func qrCodeForAnotherTVIsRejected() async throws {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer()
        let gate = PairingGate()
        await gate.open()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate) }
        await #expect(throws: CompanionError.self) {
            try await HandshakeRunner.client(over: clientPipe, mode: .pairSecret, identity: phone.identity, name: "Phone", secret: SymmetricKey(size: .bits128), expectedHostID: "someone-else")
        }
        clientPipe.close()
        _ = try? await host.value
    }

    @Test func pairingRequiresTheScreenToBeOpen() async throws {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer()
        let gate = PairingGate() // never opened
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate) }
        await #expect(throws: CompanionError.pairingNotAvailable) {
            try await HandshakeRunner.client(over: clientPipe, mode: .pairCode, identity: phone.identity, name: "Phone")
        }
        await #expect(throws: CompanionError.pairingNotAvailable) { try await host.value }
    }

    @Test func pairingLocksAfterRepeatedFailures() async throws {
        let screen = ScreenRecorder()
        let gate = PairingGate(onChange: screen.onChange)
        await gate.open()
        for _ in 0..<PairingGate.maximumFailures {
            let attempt = try await gate.begin(mode: .pairCode, clientName: "Guesser")
            await gate.fail(attempt, error: CompanionError.incorrectCode)
        }
        #expect(screen.latest == .locked)
        await #expect(throws: CompanionError.pairingNotAvailable) { try await gate.begin(mode: .pairCode, clientName: "Guesser") }
        await gate.open()
        _ = try await gate.begin(mode: .pairCode, clientName: "Owner")
    }

    @Test func oneAttemptAtATime() async throws {
        let gate = PairingGate()
        await gate.open()
        let first = try await gate.begin(mode: .pairCode, clientName: "A")
        await #expect(throws: CompanionError.pairingNotAvailable) { try await gate.begin(mode: .pairCode, clientName: "B") }
        await gate.fail(first, error: CompanionError.connectionClosed)
        _ = try await gate.begin(mode: .pairCode, clientName: "B")
    }

    // MARK: - Resume

    func pairedPeers() async throws -> (phone: Peer, tv: Peer, tvDevice: PairedDevice) {
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let phone = Peer(), tv = Peer()
        let screen = ScreenRecorder()
        let gate = PairingGate(onChange: screen.onChange)
        await gate.open()
        async let hostResult = HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate)
        let result = try await HandshakeRunner.client(over: clientPipe, mode: .pairCode, identity: phone.identity, name: "Phone", verifyCode: userChecksCodes(screen, gate))
        _ = try await hostResult
        try phone.store.save(result.peer)
        return (phone, tv, result.peer)
    }

    @Test func pairedDevicesResumeWithoutACode() async throws {
        let (phone, tv, tvDevice) = try await pairedPeers()
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let gate = PairingGate() // closed: resuming doesn't need the pairing screen
        async let hostResult = HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: gate)
        let result = try await HandshakeRunner.client(over: clientPipe, mode: .resume, identity: phone.identity, name: "Phone", expectedHost: tvDevice)
        let host = try await hostResult
        #expect(host.peer.id == phone.identity.id)
        var a = result.channel, b = host.channel
        #expect(try b.open(a.seal(Data([1, 2, 3]))) == Data([1, 2, 3]))
    }

    @Test func unpairedDevicesCantResume() async throws {
        let (phone, tv, tvDevice) = try await pairedPeers()
        try tv.store.removeDevice(id: phone.identity.id)
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: PairingGate()) }
        await #expect(throws: CompanionError.notPaired) {
            try await HandshakeRunner.client(over: clientPipe, mode: .resume, identity: phone.identity, name: "Phone", expectedHost: tvDevice)
        }
        await #expect(throws: CompanionError.notPaired) { try await host.value }
    }

    /// Knowing a paired device's ID (it's in Bonjour TXT records and the
    /// handshake) isn't enough: resuming needs its private key.
    @Test func impostorWithAStolenIDFails() async throws {
        let (phone, tv, tvDevice) = try await pairedPeers()
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: tv.identity, name: "TV", store: tv.store, gate: PairingGate()) }

        let impostor = CompanionIdentity()
        var transcript = Transcript(mode: .resume)
        let ephemeral = Handshake.Ephemeral()
        let hello = try Wire.encode(ClientHello(version: 1, mode: .resume, clientName: "Phone", clientID: phone.identity.id, commitment: ephemeral.commitment))
        transcript.append(hello)
        clientPipe.send(hello)
        let responseData = try await clientPipe.receive()
        transcript.append(responseData)
        let hostHello = try #require(try Wire.decode(HostResponse.self, from: responseData).hello)
        let reveal = try Wire.encode(ClientReveal(ephemeralKey: ephemeral.publicKey, nonce: ephemeral.nonce))
        transcript.append(reveal)
        clientPipe.send(reveal)
        let keys = try Handshake.deriveKeys(privateKey: ephemeral.privateKey, peerPublicKey: hostHello.ephemeralKey, transcript: transcript.digest, secret: nil)
        var channel = SecureChannel(keys: keys, role: .client)
        try HandshakeRunner.sendSealed(AuthMessage(signature: impostor.sign(Handshake.signedData(keys, role: .client))), over: clientPipe, channel: &channel)
        await #expect(throws: CompanionError.self) { try await host.value }
        _ = tvDevice
    }

    @Test func impostorTVFailsResume() async throws {
        let (phone, _, tvDevice) = try await pairedPeers()
        let fakeTV = Peer()
        try fakeTV.store.save(PairedDevice(name: "Phone", publicKey: phone.identity.publicKey))
        let (clientPipe, hostPipe) = PipeTransport.pair()
        let host = Task { try await HandshakeRunner.host(over: hostPipe, identity: fakeTV.identity, name: "TV", store: fakeTV.store, gate: PairingGate()) }
        await #expect(throws: CompanionError.self) {
            try await HandshakeRunner.client(over: clientPipe, mode: .resume, identity: phone.identity, name: "Phone", expectedHost: tvDevice)
        }
        clientPipe.close()
        _ = try? await host.value
    }
}

@Suite("Secure channel")
struct SecureChannelTests {
    func channels() throws -> (SecureChannel, SecureChannel) {
        let a = Handshake.Ephemeral(), b = Handshake.Ephemeral()
        let transcript = randomBytes(32)
        let keysA = try Handshake.deriveKeys(privateKey: a.privateKey, peerPublicKey: b.publicKey, transcript: transcript, secret: nil)
        let keysB = try Handshake.deriveKeys(privateKey: b.privateKey, peerPublicKey: a.publicKey, transcript: transcript, secret: nil)
        return (SecureChannel(keys: keysA, role: .client), SecureChannel(keys: keysB, role: .host))
    }

    @Test func rejectsTamperingReplayAndReordering() throws {
        var (client, host) = try channels()
        let first = try client.seal(Data("one".utf8))
        let second = try client.seal(Data("two".utf8))

        var flipped = first
        flipped[flipped.startIndex] ^= 1
        var tamperedHost = host
        #expect(throws: CompanionError.self) { try tamperedHost.open(flipped) }

        var reorderedHost = host
        #expect(throws: CompanionError.self) { try reorderedHost.open(second) }

        #expect(try host.open(first) == Data("one".utf8))
        #expect(throws: CompanionError.self) { try host.open(first) } // replay
        #expect(try host.open(second) == Data("two".utf8))
    }

    @Test func directionsUseDifferentKeys() throws {
        var (client, host) = try channels()
        let fromClient = try client.seal(Data("x".utf8))
        var echo = client
        #expect(throws: CompanionError.self) { try echo.open(fromClient) }
        #expect(try host.open(fromClient) == Data("x".utf8))
    }

    @Test func differentSecretsGiveDifferentKeys() throws {
        let a = Handshake.Ephemeral(), b = Handshake.Ephemeral()
        let transcript = randomBytes(32)
        let one = try Handshake.deriveKeys(privateKey: a.privateKey, peerPublicKey: b.publicKey, transcript: transcript, secret: SymmetricKey(size: .bits128))
        let two = try Handshake.deriveKeys(privateKey: b.privateKey, peerPublicKey: a.publicKey, transcript: transcript, secret: SymmetricKey(size: .bits128))
        #expect(one.pairingCode == two.pairingCode, "the code only depends on the key agreement")
        #expect(!Handshake.verifyConfirmation(Handshake.confirmationMAC(one, role: .client), keys: two, role: .client))
    }

    @Test func rejectsLowOrderKeys() {
        let ephemeral = Handshake.Ephemeral()
        #expect(throws: (any Error).self) {
            try Handshake.deriveKeys(privateKey: ephemeral.privateKey, peerPublicKey: Data(count: 32), transcript: Data(), secret: nil)
        }
    }

    @Test func framing() throws {
        var decoder = FrameDecoder()
        let payloads = [Data("a".utf8), Data(), Data(repeating: 7, count: 70_000)]
        let stream = payloads.map(FrameDecoder.frame).reduce(Data(), +)
        var received: [Data] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = min(index + Int.random(in: 1...5000), stream.endIndex)
            received += try decoder.append(stream[index..<end])
            index = end
        }
        #expect(received == payloads)
        var oversized = FrameDecoder()
        #expect(throws: CompanionError.self) { try oversized.append(Data([0x7F, 0xFF, 0xFF, 0xFF])) }
    }
}
