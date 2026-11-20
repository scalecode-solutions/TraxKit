import XCTest

/// Drives TraxLab against the LOCAL mvTrax, signed in through the debug dev
/// sign-in. Run by ../scripts/ui-test.sh (it mints the token). Each check keeps
/// a screenshot attachment.
final class TraxLabUITests: XCTestCase {
    var app: XCUIApplication!
    var friend: String?
    /// The host's own name for the friend (LAB_NICKNAME): the kit must show it
    /// instead of the directory's.
    let nickname = "Lab Nickname"
    /// Where the Lab opens for this test (LAB_START); nil = the map.
    var startTab: String? {
        switch name {
        case let n where n.contains("Settings]") && !n.contains("Pair"): "me"
        case let n where n.contains("Conversation") || n.contains("PersonMap") || n.contains("Pair"): "chats"
        default: nil
        }
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["TRAX_DEV_TOKEN"], let user = env["TRAX_DEV_USER"] else {
            throw XCTSkip("run through scripts/ui-test.sh")
        }
        continueAfterFailure = false
        friend = env["LAB_FRIEND"].flatMap { $0.isEmpty ? nil : $0 }
        app = XCUIApplication()
        var launch = ["TRAX_DEV_TOKEN": token, "TRAX_DEV_USER": user]
        if let friend { launch["LAB_FRIEND"] = friend; launch["LAB_NICKNAME"] = nickname }
        if let start = startTab { launch["LAB_START"] = start }
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

    /// Scrolls `e` into view, then requires it to be hittable and clear of the
    /// tab bar (the Lab's tab bar floats over every screen, like a host's).
    /// Lists create rows lazily and scroll them under the floating tab bar, so
    /// this scrolls until the element exists, is hittable and is clear of the bar.
    @discardableResult
    func reachable(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 15) -> XCUIElement {
        _ = e.waitForExistence(timeout: timeout)
        let bar = app.tabBars.firstMatch
        func clear() -> Bool { !bar.exists || e.frame.maxY <= bar.frame.minY + 1 }
        for _ in 0..<8 where !(e.exists && e.isHittable && clear()) {
            app.swipeUp()
            _ = e.waitForExistence(timeout: 1)
        }
        XCTAssert(e.exists, "no \(what)")
        XCTAssert(e.isHittable, "\(what) can't be tapped")
        XCTAssert(clear(), "\(what) sits under the tab bar")
        return e
    }

    /// The person map from a conversation: the card shows their status and my
    /// share controls, all reachable above the tab bar at any text size.
    func testPersonMapFromConversation() throws {
        guard friend != nil else { throw XCTSkip("set LAB_FRIEND") }
        reachable(app.buttons["conversation.map"], "map link").tap()
        XCTAssert(app.otherElements["person.card"].waitForExistence(timeout: 15) || app.scrollViews["person.card"].exists,
                  "no person card")
        reachable(app.staticTexts["person.status"], "status line")
        let start = app.buttons["share.start"], stop = app.buttons["share.stop"]
        XCTAssert(start.waitForExistence(timeout: 5) || stop.exists, "no share controls")
        reachable(start.exists ? start : stop, "share button")
        if app.buttons["person.recenter"].exists {
            XCTAssert(app.buttons["person.recenter"].isHittable, "recenter can't be tapped")
        }
        XCTAssert(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", nickname)).firstMatch
                    .waitForExistence(timeout: 5), "the person map doesn't use the host's name")
        shot("person-map")
    }

    /// Pair settings from a conversation: my share to them and their places.
    func testPairSettingsFromConversation() throws {
        guard friend != nil else { throw XCTSkip("set LAB_FRIEND") }
        reachable(app.buttons["conversation.pairSettings"], "location settings link").tap()
        let start = app.buttons["share.start"], change = app.buttons["share.change"]
        XCTAssert(start.waitForExistence(timeout: 10) || change.exists, "no share controls")
        reachable(start.exists ? start : change, "share control")
        XCTAssert(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", nickname)).firstMatch
                    .waitForExistence(timeout: 5), "pair settings don't use the host's name")
        shot("pair-settings")
    }

    /// My settings: places, stop all, clear history, all reachable.
    func testSettings() {
        reachable(app.buttons["settings.addPlace"], "add place")
        reachable(app.buttons["settings.clearHistory"], "clear history")
        reachable(app.buttons["settings.stopAll"], "stop all")
        shot("settings")
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
