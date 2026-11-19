import XCTest

/// Drives TraxLab against the LOCAL mvTrax, signed in through the debug dev
/// sign-in. Run by ../scripts/ui-test.sh (it mints the token). Each check keeps
/// a screenshot attachment.
final class TraxLabUITests: XCTestCase {
    var app: XCUIApplication!
    var friend: String?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["TRAX_DEV_TOKEN"], let user = env["TRAX_DEV_USER"] else {
            throw XCTSkip("run through scripts/ui-test.sh")
        }
        continueAfterFailure = false
        friend = env["LAB_FRIEND"].flatMap { $0.isEmpty ? nil : $0 }
        app = XCUIApplication()
        var launch = ["TRAX_DEV_TOKEN": token, "TRAX_DEV_USER": user]
        if let friend { launch["LAB_FRIEND"] = friend }
        app.launchEnvironment = launch
        // Location prompts would cover the hub; the test isn't about them.
        addUIInterruptionMonitor(withDescription: "location") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Signed in through the dev sign-in, the Lab skips the login and opens on
    /// the kit's hub: the Trax tab is selected and the map is on screen.
    func testSignedInHubLoads() {
        XCTAssertFalse(app.buttons["Sign In"].exists, "the dev sign-in fell through to the login screen")
        let trax = app.tabBars.buttons["Trax"]
        XCTAssert(trax.waitForExistence(timeout: 10), "no Trax tab")
        XCTAssert(trax.isSelected, "the Lab didn't open on the Trax tab")
        XCTAssert(app.maps.firstMatch.waitForExistence(timeout: 15), "the hub's map didn't load")
        app.tap() // lets the interruption monitor answer a pending prompt
        shot("hub")
    }

    /// The conversation's header reads the kit's bridge. With a friend who
    /// shares with this account, it shows their location (LAB_FRIEND).
    func testConversationShowsFriend() throws {
        guard friend != nil else { throw XCTSkip("set LAB_FRIEND to a friend who shares with this account") }
        app.tabBars.buttons["Chats"].tap()
        let coordinate = app.staticTexts["friend.coordinate"]
        XCTAssert(coordinate.waitForExistence(timeout: 30), "the friend's share never arrived")
        XCTAssertNotEqual(coordinate.label, "—", "a share, but no coordinate")
        shot("conversation")
    }
}
