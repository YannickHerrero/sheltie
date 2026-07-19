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
            XCTAssertTrue(app.descendants(matching: .any)["Resize Spaces and Agents"].exists)
            XCTAssertTrue(app.buttons["workspace.w1"].exists)
            XCTAssertFalse(app.buttons["esc"].exists)
            app.terminate()

            let workspaceApp = XCUIApplication()
            workspaceApp.launchArguments += ["--demo", "--phone-workspace"]
            workspaceApp.launch()
            XCTAssertTrue(workspaceApp.buttons["Back to spaces and agents"].waitForExistence(timeout: 5))
            XCTAssertTrue(workspaceApp.staticTexts["Implementation Agent"].firstMatch.exists)
            XCTAssertTrue(workspaceApp.buttons["esc"].exists)
            workspaceApp.terminate()
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
                XCTAssertTrue(app.descendants(matching: .any)["Resize Spaces and Agents"].exists)
            }
        }
        app.terminate()
    }

    func testTerminalHistoryScrollsAndReturnsToLatest() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--demo", "--phone-workspace"]
        app.launch()

        let terminalTitle = app.staticTexts["Implementation Agent"].firstMatch
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 5))
        app.buttons["Show terminal history"].firstMatch.tap()

        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        let history = app.textViews["Terminal history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.swipeDown()
        XCTAssertEqual(history.value as? String, "Earlier output")

        latest.tap()
        XCTAssertFalse(latest.exists)
        XCTAssertTrue(terminalTitle.exists)
        app.terminate()
    }

    func testSidebarDividerResizesOnPhone() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments.append("--demo")
        app.launch()

        let window = app.windows.firstMatch
        guard window.frame.width <= 430 else { return }
        let agentsLabel = app.staticTexts["AGENTS"]
        XCTAssertTrue(agentsLabel.waitForExistence(timeout: 5))
        let originalAgentsY = agentsLabel.frame.minY
        let divider = app.descendants(matching: .any)["Resize Spaces and Agents"]
        XCTAssertTrue(divider.exists)

        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
            )
        XCTAssertGreaterThan(agentsLabel.frame.minY, originalAgentsY + 40)

        app.descendants(matching: .any)["Resize Spaces and Agents"].doubleTap()
        XCTAssertEqual(agentsLabel.frame.minY, originalAgentsY, accuracy: 3)
        app.terminate()
    }
}
