import TVCompanion
import XCTest

/// Captures the README screenshots of the TV side. Run with `Scripts/screenshots.sh`.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func capture(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPairingScreens() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshots", "-dark"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pairButton"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["Pairing QR code"].waitForExistence(timeout: 10))
        capture("tv-pairing")

        // A phone starts code pairing, and the TV shows the code to confirm.
        let phone = CompanionClient(name: "Dan's iPhone", serviceType: "_tvcdemo._tcp", store: InMemoryPairingStore())
        let host = try await CompanionUITests.firstHost(named: "Living Room", using: phone)
        let attempt = phone.pair(with: host)
        _ = try await attempt.codeRequested()
        XCTAssertTrue(app.buttons["confirmPairing"].waitForExistence(timeout: 10))
        capture("tv-confirm")
        await attempt.cancel()
    }
}
