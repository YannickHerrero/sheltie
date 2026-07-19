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

        let windowWidth = app.windows.firstMatch.frame.width
        if windowWidth <= 430 {
            XCTAssertTrue(app.staticTexts["SPACES"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["workspace.w1"].exists)
            XCTAssertFalse(app.buttons["esc"].exists)
            app.terminate()

            let workspaceApp = XCUIApplication()
            workspaceApp.launchArguments += ["--demo", "--phone-workspace"]
            workspaceApp.launch()
            XCTAssertTrue(workspaceApp.buttons["Back to spaces and agents"].waitForExistence(timeout: 5))
            XCTAssertTrue(workspaceApp.staticTexts["Implementation Agent"].firstMatch.exists)
            XCTAssertTrue(workspaceApp.buttons["esc"].exists)
        } else {
            XCTAssertTrue(app.buttons["instance.selector"].waitForExistence(timeout: 5))
            if windowWidth > 560 {
                XCTAssertTrue(app.staticTexts["Sheltie"].exists)
            }
            XCTAssertTrue(app.staticTexts["Implementation Agent"].firstMatch.exists)
            XCTAssertTrue(app.descendants(matching: .any)["terminal.keybar"].exists)
            if windowWidth <= 820 {
                XCTAssertTrue(app.buttons["Show spaces and agents"].exists)
            } else {
                XCTAssertTrue(app.staticTexts["SPACES"].exists)
            }
        }
    }
}
