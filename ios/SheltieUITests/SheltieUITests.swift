import XCTest

final class SheltieUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoWorkspaceLaunches() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append("--demo")
        app.launch()

        XCTAssertTrue(app.staticTexts["Sheltie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["instance.selector"].exists)
        XCTAssertTrue(app.staticTexts["Claude Code"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["terminal.keybar"].exists)
        XCTAssertTrue(app.staticTexts["SPACES"].exists)
    }
}
