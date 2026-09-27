import Foundation
import Network
import Testing
@testable import TVCompanion

/// End-to-end tests over real TCP connections on this machine.
@MainActor
@Suite("Host and client", .serialized, .timeLimit(.minutes(2)))
struct NetworkTests {
    let serviceType = "_tvctest\(Int.random(in: 100...999))._tcp"

    func startHost(name: String = "Living Room") async throws -> CompanionHost {
        let host = CompanionHost(name: name, serviceType: serviceType, linkScheme: "tvctest", store: InMemoryPairingStore())
        try host.start()
        try await host.waitUntilReady()
        return host
    }

    func endpoint(_ host: CompanionHost) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port!)!)
    }

    func shownCode(_ host: CompanionHost) async throws -> String {
        for _ in 0..<500 {
            if case .showingCode(let code, _) = host.pairingState { return code }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CompanionError.timeout
    }

    func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CompanionError.timeout
    }

    /// The full code-pairing flow: the phone shows a code field, the user
    /// types the TV's code, then confirms on the TV.
    func pairWithCode(_ client: CompanionClient, _ host: CompanionHost) async throws -> CompanionSession {
        host.openPairing()
        try await waitFor { host.pairingState == .waiting }
        let attempt = client.pair(endpoint: endpoint(host))
        let hostName = try await attempt.codeRequested()
        #expect(hostName == host.name)
        let code = try await shownCode(host)
        async let session = attempt.submit(code: code)
        host.confirmPairing()
        return try await session
    }

    @Test func pairsWithACodeAndExchangesRequests() async throws {
        let host = try await startHost()
        defer { host.stop() }
        let client = CompanionClient(name: "Dan's iPhone", serviceType: serviceType, store: InMemoryPairingStore())

        let session = try await pairWithCode(client, host)
        #expect(session.peer.name == "Living Room")
        #expect(try client.pairedHosts().map(\.name) == ["Living Room"])
        try await waitFor { host.connectedDevices.map(\.name) == ["Dan's iPhone"] }
        #expect(host.pairedDevices.map(\.name) == ["Dan's iPhone"])
        if case .paired(let device) = host.pairingState { #expect(device.name == "Dan's iPhone") } else { Issue.record("expected paired state") }

        // The phone answers the TV's text and credential requests.
        let answering = Task {
            for await request in session.requests {
                if let text = request.textInput {
                    #expect(text.prompt == "Server Address")
                    try await request.respond(text: "https://jellyfin.local:8920")
                } else if let credentials = request.credentialRequest {
                    #expect(credentials.service == "Jellyfin")
                    try await request.respond(credential: CompanionCredential(username: "dan", password: "hunter2"))
                }
            }
        }
        let address = try await host.requestText(TextInputRequest(prompt: "Server Address", contentType: .url))
        #expect(address == "https://jellyfin.local:8920")
        let credential = try await host.requestCredentials(CredentialRequest(service: "Jellyfin", serverURL: URL(string: address)))
        #expect(credential == CompanionCredential(username: "dan", password: "hunter2"))

        // One-way messages in both directions.
        struct Play: Codable, Equatable { var id: String }
        let tvReceived = Task { @MainActor in
            for await (device, message) in host.messages {
                return (device.name, try message.decode(Play.self))
            }
            throw CompanionError.connectionClosed
        }
        try await session.send("play", Play(id: "movie-1"))
        let (sender, play) = try await tvReceived.value
        #expect(sender == "Dan's iPhone")
        #expect(play == Play(id: "movie-1"))

        var phoneMessages = session.messages.makeAsyncIterator()
        await host.broadcast("nowPlaying", Play(id: "movie-1"))
        #expect(try await phoneMessages.next()?.decode(Play.self) == Play(id: "movie-1"))
        answering.cancel()
    }

    @Test func wrongCodeCanBeRetried() async throws {
        let host = try await startHost()
        defer { host.stop() }
        let client = CompanionClient(name: "Phone", serviceType: serviceType, store: InMemoryPairingStore())
        host.openPairing()
        try await waitFor { host.pairingState == .waiting }
        let attempt = client.pair(endpoint: endpoint(host))
        _ = try await attempt.codeRequested()
        let code = try await shownCode(host)
        let wrong = String(code.reversed()) == code ? "000000" : String(code.reversed())
        await #expect(throws: CompanionError.incorrectCode) { try await attempt.submit(code: wrong) }
        async let session = attempt.submit(code: code)
        host.confirmPairing()
        #expect(try await session.peer.name == "Living Room")
    }

    @Test func tvUserCanRejectAPairing() async throws {
        let host = try await startHost()
        defer { host.stop() }
        let client = CompanionClient(name: "Stranger", serviceType: serviceType, store: InMemoryPairingStore())
        host.openPairing()
        try await waitFor { host.pairingState == .waiting }
        let attempt = client.pair(endpoint: endpoint(host))
        let code = try await shownCode(host)
        let session = Task { try await attempt.submit(code: code) }
        host.rejectPairing()
        await #expect(throws: (any Error).self) { try await session.value }
        #expect(host.pairedDevices.isEmpty)
        #expect(try client.pairedHosts().isEmpty)
        try await waitFor { host.pairingState == .waiting }
    }

    @Test func pairingIsClosedByDefault() async throws {
        let host = try await startHost()
        defer { host.stop() }
        let client = CompanionClient(name: "Phone", serviceType: serviceType, store: InMemoryPairingStore())
        let attempt = client.pair(endpoint: endpoint(host))
        await #expect(throws: CompanionError.pairingNotAvailable) { try await attempt.session() }
    }

    @Test func pairsWithTheQRCode() async throws {
        let host = try await startHost()
        defer { host.stop() }
        host.openPairing()
        try await waitFor { host.pairingLink != nil }
        let url = try #require(host.pairingLink)
        #expect(url.scheme == "tvctest")
        let link = try PairingLink(url: url)
        #expect(link.hostName == "Living Room")

        let client = CompanionClient(name: "Phone", serviceType: serviceType, store: InMemoryPairingStore())
        let session = try await client.pair(endpoint: endpoint(host), link: link)
        #expect(session.peer.id == link.hostID)
        try await waitFor { host.pairingLink != url }

        // The QR secret is single-use.
        let other = CompanionClient(name: "Other", serviceType: serviceType, store: InMemoryPairingStore())
        await #expect(throws: (any Error).self) { try await other.pair(endpoint: endpoint(host), link: link) }
    }

    @Test func pairedPhoneReconnectsAndCanBeUnpaired() async throws {
        let host = try await startHost()
        defer { host.stop() }
        let client = CompanionClient(name: "Phone", serviceType: serviceType, store: InMemoryPairingStore())
        let first = try await pairWithCode(client, host)
        await first.close()
        try await waitFor { host.connectedDevices.isEmpty }
        host.closePairing()

        let tv = try #require(try client.pairedHosts().first)
        let second = try await client.connect(endpoint: endpoint(host), host: tv)
        try await waitFor { host.connectedDevices.count == 1 }
        #expect(second.peer.id == tv.id)

        host.unpair(try #require(host.pairedDevices.first))
        for await _ in second.closed {}
        await #expect(throws: CompanionError.notPaired) { try await client.connect(endpoint: endpoint(host), host: tv) }
        #expect(try client.pairedHosts().isEmpty, "the phone forgets a TV that forgot it")
    }

    @Test func firstAnswerWinsAcrossDevices() async throws {
        let host = try await startHost()
        defer { host.stop() }
        let phone = CompanionClient(name: "Phone", serviceType: serviceType, store: InMemoryPairingStore())
        let tablet = CompanionClient(name: "iPad", serviceType: serviceType, store: InMemoryPairingStore())
        let phoneSession = try await pairWithCode(phone, host)
        let tabletSession = try await pairWithCode(tablet, host)
        try await waitFor { host.connectedDevices.count == 2 }

        let phoneDeclines = Task {
            for await request in phoneSession.requests { await request.decline() }
        }
        let tabletAnswers = Task {
            for await request in tabletSession.requests {
                try await Task.sleep(for: .milliseconds(100))
                try await request.respond(text: "from iPad")
            }
        }
        #expect(try await host.requestText(TextInputRequest(prompt: "Search")) == "from iPad")
        phoneDeclines.cancel()
        tabletAnswers.cancel()
    }

    @Test func requestsFailWithoutConnectedDevices() async throws {
        let host = try await startHost()
        defer { host.stop() }
        await #expect(throws: CompanionError.noConnectedDevices) { try await host.requestText(TextInputRequest(prompt: "x")) }
    }

    @Test func discoversHostsWithBonjour() async throws {
        let host = try await startHost(name: "Bonjour TV \(Int.random(in: 1...999))")
        defer { host.stop() }
        let client = CompanionClient(name: "Phone", serviceType: serviceType, store: InMemoryPairingStore())
        let hostName = host.name
        let found = try await withThrowingTaskGroup(of: DiscoveredHost?.self) { group in
            group.addTask {
                for await hosts in client.discover() {
                    if let match = hosts.first(where: { $0.name == hostName }) { return match }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        let discovered = try #require(found, "Bonjour should find the host")
        #expect(discovered.id.count == 24, "the TXT record carries the host identity")
        #expect(!discovered.isPaired)

        // Pair through the discovered endpoint.
        host.openPairing()
        try await waitFor { host.pairingLink != nil }
        let session = try await client.pair(using: PairingLink(url: host.pairingLink!), host: discovered)
        #expect(session.peer.id == discovered.id)
    }
}

@Suite("Pairing links")
struct PairingLinkTests {
    @Test func roundTrips() throws {
        let link = PairingLink(hostID: "abc123", hostName: "Living Room & Den", serviceType: "_x._tcp", secret: .init(size: .bits128))
        let url = link.url(scheme: "myapp")
        #expect(url.absoluteString.hasPrefix("myapp://pair?"))
        #expect(try PairingLink(url: url) == link)
    }

    @Test func rejectsInvalidLinks() {
        for string in ["myapp://other?host=a&service=b&secret=AAAAAAAAAAAAAAAAAAAAAA", "myapp://pair?host=a&service=b", "myapp://pair?host=a&service=b&secret=short", "myapp://pair?service=b&secret=AAAAAAAAAAAAAAAAAAAAAA"] {
            #expect(throws: CompanionError.invalidPairingLink, "\(string)") { try PairingLink(url: URL(string: string)!) }
        }
    }
}
