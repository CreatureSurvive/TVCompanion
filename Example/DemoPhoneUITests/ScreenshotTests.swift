import TVCompanion
import XCTest

/// Captures the README screenshots of the phone side. The test process plays
/// the Apple TV. Run with `Scripts/screenshots.sh`.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func capture(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits without blocking the main actor, where the test's TV host runs.
    @MainActor
    func appears(_ element: XCUIElement, timeout: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    @MainActor
    func code(of tv: CompanionHost) async throws -> String {
        for _ in 0..<200 {
            if case .showingCode(let code, _) = tv.pairingState { return code }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CompanionError.timeout
    }

    @MainActor
    func testPhoneScreens() async throws {
        let tv = CompanionHost(name: "Living Room", serviceType: "_tvcdemo._tcp", linkScheme: "tvcompaniondemo", store: InMemoryPairingStore())
        try tv.start()
        defer { tv.stop() }
        tv.openPairing()

        let app = XCUIApplication()
        app.launchArguments = ["-testing"]
        app.launch()
        let tvRow = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Living Room'")).firstMatch
        let discovered = await appears(tvRow, timeout: 30)
        XCTAssertTrue(discovered, "the phone should discover the TV")
        tvRow.tap()

        // Code entry, partly typed.
        let field = app.textFields.firstMatch
        let hasField = await appears(field, timeout: 10)
        XCTAssertTrue(hasField)
        let code = try await code(of: tv)
        field.tap()
        field.typeText(String(code.prefix(3)))
        capture("phone-code")
        field.typeText(String(code.dropFirst(3)))
        let waiting = await appears(app.staticTexts["Confirm on the TV…"], timeout: 5)
        XCTAssertTrue(waiting)
        tv.confirmPairing()
        let connected = await appears(app.buttons["Disconnect"], timeout: 10)
        XCTAssertTrue(connected)

        // The TV asks for credentials; the phone shows a sign-in sheet with AutoFill.
        let request = Task { try await tv.requestCredentials(CredentialRequest(service: "Jellyfin", serverURL: URL(string: "https://media.example.com:8920"))) }
        let username = app.textFields["Username"]
        let hasUsername = await appears(username, timeout: 10)
        XCTAssertTrue(hasUsername)
        username.tap()
        username.typeText("dan")
        // Secure field contents are hidden in screenshots; capture before typing.
        app.secureTextFields["Password"].tap()
        capture("phone-credentials")
        app.secureTextFields["Password"].typeText("correct horse")
        app.buttons["Send"].tap()
        let credential = try await request.value
        XCTAssertEqual(credential.username, "dan")
    }
}
