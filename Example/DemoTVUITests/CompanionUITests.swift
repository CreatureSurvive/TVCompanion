import TVCompanion
import XCTest

/// The test process plays the phone: it discovers the TV app over Bonjour,
/// reads the pairing code off the screen, and presses Confirm with the remote.
final class CompanionUITests: XCTestCase {
    @MainActor
    func testPairAndTypeOnPhone() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-testing"]
        app.launch()
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.descendants(matching: .any)["pairButton"].waitForExistence(timeout: 10))

        // Open the pairing screen on the TV.
        remote.press(.select)
        XCTAssertTrue(app.images["Pairing QR code"].waitForExistence(timeout: 10), "the pairing screen shows a QR code")

        // The phone finds the TV and starts code pairing.
        let phone = CompanionClient(name: "Test Phone", serviceType: "_tvcdemo._tcp", store: InMemoryPairingStore())
        let host = try await Self.firstHost(named: "Test TV", using: phone)
        let attempt = phone.pair(with: host)
        let hostName = try await attempt.codeRequested()
        XCTAssertEqual(hostName, "Test TV")

        // The user reads the code on the TV and types it on the phone...
        let codeLabel = app.staticTexts["pairingCode"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 10))
        let code = codeLabel.label.filter(\.isNumber)
        XCTAssertEqual(code.count, 6)
        let pairing = Task { try await attempt.submit(code: code) }

        // ...and presses Confirm on the TV, which has focus.
        let confirm = app.buttons["confirmPairing"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        await fulfillment(of: [expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: confirm)], timeout: 5)
        remote.press(.select)
        let session = try await pairing.value
        XCTAssertEqual(session.peer.name, "Test TV")
        XCTAssertTrue(app.staticTexts["Test Phone is paired"].waitForExistence(timeout: 10))

        // Back on the main screen, "Type on iPhone" asks the phone for text.
        remote.press(.menu)
        let typeButton = app.buttons["typeOnPhone"]
        XCTAssertTrue(typeButton.waitForExistence(timeout: 10))
        let answering = Task {
            for await request in session.requests {
                if request.textInput?.prompt == "Server Address" {
                    try await request.respond(text: "https://jellyfin.example:8920")
                }
            }
        }
        for _ in 0..<4 where !typeButton.hasFocus {
            remote.press(.down)
            if !typeButton.hasFocus { remote.press(.right) }
        }
        XCTAssertTrue(typeButton.hasFocus, "focus should reach the Type on iPhone button")
        remote.press(.select)
        let value = app.staticTexts["serverValue"]
        let predicate = NSPredicate(format: "label == 'Server: https://jellyfin.example:8920'")
        await fulfillment(of: [expectation(for: predicate, evaluatedWith: value)], timeout: 10)
        answering.cancel()
        await session.close()
    }

    static func firstHost(named name: String, using client: CompanionClient) async throws -> DiscoveredHost {
        try await withThrowingTaskGroup(of: DiscoveredHost.self) { group in
            group.addTask {
                for await hosts in client.discover() {
                    if let host = hosts.first(where: { $0.name == name }) { return host }
                }
                throw CompanionError.connectionClosed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw CompanionError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
