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

        XCTAssertTrue(app.buttons["instance.selector"].waitForExistence(timeout: 5))
        if app.windows.firstMatch.frame.width > 560 {
            XCTAssertTrue(app.staticTexts["Sheltie"].exists)
        }
        XCTAssertTrue(app.staticTexts["Claude Code"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["terminal.keybar"].exists)
        if app.windows.firstMatch.frame.width <= 820 {
            XCTAssertTrue(app.buttons["Show spaces and agents"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["SPACES"].exists)
        }
    }
}
