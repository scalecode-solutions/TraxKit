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
        case let n where n.contains(" testSettings"): "me"
        case let n where n.contains("Conversation") || n.contains("PersonMap") || n.contains("PersonCard") || n.contains("Pair"): "chats"
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
        if name.contains("WithoutTabBar") { launch["LAB_HIDE_TAB_BAR"] = "1" }
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

    /// The person map's card is drawn to the screen's bottom edge (its glass
    /// under the home indicator, or under a host's tab bar), with no strip of
    /// map below it, and the share button is still reachable above the edge.
    func cardReachesTheBottomEdge() throws {
        guard friend != nil else { throw XCTSkip("set LAB_FRIEND") }
        reachable(app.buttons["conversation.map"], "map link").tap()
        let card = app.descendants(matching: .any)["person.card"].firstMatch
        XCTAssert(card.waitForExistence(timeout: 15), "no person card")
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(card.frame.maxY, screen.maxY, accuracy: 1,
                       "the card stops \(screen.maxY - card.frame.maxY) pt above the bottom edge")
        let start = app.buttons["share.start"], stop = app.buttons["share.stop"]
        XCTAssert(start.waitForExistence(timeout: 5) || stop.exists, "no share controls")
        shot("person-card-edge")
    }

    /// The standard deviation of the grey levels in the screen's bottom band
    /// (the lowest 25 pt, above the very edge): ~4 over glass, far more over
    /// an unblurred map.
    func bottomBandSpread(_ shot: XCUIScreenshot) -> Double {
        let height = app.windows.firstMatch.frame.height
        return bandSpread(shot, fromTop: height - 25, height: 21)
    }

    /// The standard deviation of the grey levels in a full-width band, `height`
    /// pt tall, starting `fromTop` pt down the screen.
    func bandSpread(_ shot: XCUIScreenshot, fromTop top: Double, height: Double) -> Double {
        guard let cg = shot.image.cgImage else { return .infinity }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = Double(h) / Double(app.windows.firstMatch.frame.height)
        let y0 = max(0, Int(top * scale)), y1 = min(h, Int((top + height) * scale))
        var values: [Double] = []
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: 0, to: w, by: 2) { values.append(Double(px[y * w + x])) }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    func testPersonMapCardReachesTheBottomEdge() throws { try cardReachesTheBottomEdge() }

    /// The same with the tab bar hidden, as a chat host pushes it: nothing
    /// covers the strip under the card there, so a gap would show.
    func testPersonMapCardReachesTheBottomEdgeWithoutTabBar() throws {
        try cardReachesTheBottomEdge()
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "the tab bar should be hidden on this path")
        // The card's frame reaches the edge even when its glass doesn't (the
        // scroll view runs into the safe area on its own), so look at the
        // pixels: the bottom band must be the card's frosted glass, nearly
        // uniform, not the sharp map (roads, labels) a gap shows. (With a tab
        // bar the band is the bar's icons, so this check is for this path.)
        // Fails on 0.7.1's card: spread 33 against ~4 over glass.
        let shot = app.screenshot()
        // Control: the map itself must have rendered (an untiled map is plain
        // and would pass the check below on a broken card). A band of map just
        // under the navigation bar, well above the card.
        let mapSpread = bandSpread(shot, fromTop: 140, height: 60)
        XCTAssertGreaterThan(mapSpread, 12, "the map didn't render (pixel spread \(mapSpread)): can't judge the card's edge")
        let spread = bottomBandSpread(shot)
        XCTAssertLessThan(spread, 12, "the bottom edge shows the map under the card (pixel spread \(spread))")
    }

    /// The person card's controls while I share (Change, Stop) and while I
    /// don't (the share button), for eyes in Light and Dark: their labels are
    /// text colours, never the host's tint. Starts a share against the LOCAL
    /// server if there isn't one, and stops it again at the end.
    func testPersonCardControlsLook() throws {
        guard friend != nil else { throw XCTSkip("set LAB_FRIEND") }
        reachable(app.buttons["conversation.map"], "map link").tap()
        let start = app.buttons["share.start"], stop = app.buttons["share.stop"]
        XCTAssert(start.waitForExistence(timeout: 15) || stop.exists, "no share controls")
        if !stop.exists { shot("card-not-sharing"); start.tap() }
        XCTAssert(stop.waitForExistence(timeout: 15), "the share didn't start")
        XCTAssert(app.buttons["share.change"].exists, "no Change")
        shot("card-sharing")
        stop.tap()
        XCTAssert(start.waitForExistence(timeout: 15), "the share didn't stop")
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
        _ = app.buttons["settings.addPlace"].waitForExistence(timeout: 15)
        shot("settings-top")   // the access row, before any scroll
        reachable(app.buttons["settings.addPlace"], "add place")
        reachable(app.buttons["settings.clearHistory"], "clear history")
        reachable(app.buttons["settings.stopAll"], "stop all")
        shot("settings")
    }

    /// A place a friend shares with me (LAB_FRIEND shares one with this
    /// account): listed under Shared with me as "Shared by <host name>". It
    /// opens as a member: its name is the owner's, the rest is mine to adjust.
    func testSettingsSharedWithMe() throws {
        guard friend != nil else { throw XCTSkip("set LAB_FRIEND to a friend who shares a place with this account") }
        let row = reachable(app.buttons["settings.sharedPlace"].firstMatch, "a place shared with me", timeout: 20)
        XCTAssert(row.label.contains("Shared by \(nickname)"), "the shared place's row reads \(row.label)")
        shot("settings-shared-with-me")
        row.tap()
        XCTAssert(app.navigationBars["Edit place"].waitForExistence(timeout: 5), "a friend's place didn't open")
        XCTAssert(app.buttons["Save"].exists, "a member can't save their adjustments")
        XCTAssertFalse(app.textFields["place.name"].isEnabled, "a member can rename a friend's place")
        XCTAssertFalse(app.descendants(matching: .any)["place.type"].exists, "a member can change a friend's place's type")
        // A sheet: the tab bar is behind it, so scroll the form rather than
        // use reachable(), which keeps elements clear of the bar.
        let sharedBy = app.staticTexts["place.sharedBy"]
        for _ in 0..<6 where !(sharedBy.exists && sharedBy.isHittable) { app.swipeUp() }
        XCTAssert(sharedBy.exists, "no line saying who shares it")
        XCTAssert(sharedBy.label.contains(nickname), "the editor doesn't use the host's name: \(sharedBy.label)")
        shot("settings-shared-place")
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
