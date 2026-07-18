import XCTest

final class SheltieUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoWorkspaceLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--demo")
        app.launch()

        XCTAssertTrue(app.staticTexts["Sheltie"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connected"].exists)
    }
}
