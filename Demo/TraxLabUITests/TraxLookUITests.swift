import XCTest

/// A look at Trax's screens, for eyes rather than asserts: it opens each one
/// and keeps a screenshot. Nothing is saved. Skipped unless LOOK=1; run by
/// ../scripts/look.sh, which sets the scheme and text size on the simulator
/// (light, dark, and the largest accessibility text) and runs it once each.
final class TraxLookUITests: XCTestCase {
    var app: XCUIApplication!
    var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["LOOK"] == "1", env["TRAX_DEV_TOKEN"] != nil, env["TRAX_DEV_USER"] != nil else {
            throw XCTSkip("a look, run by scripts/look.sh")
        }
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "location") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
    }

    func launch(start: String?) {
        app = XCUIApplication()
        var launch = ["TRAX_DEV_TOKEN": env["TRAX_DEV_TOKEN"]!, "TRAX_DEV_USER": env["TRAX_DEV_USER"]!]
        if let f = env["LAB_FRIEND"], !f.isEmpty { launch["LAB_FRIEND"] = f }
        if let start { launch["LAB_START"] = start }
        app.launchEnvironment = launch
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(env["LOOK_MODE"] ?? "look")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// Taps `e`, scrolling to it first (at the largest text it's often below
    /// the fold). False, and a recorded failure, if it can't be reached.
    @discardableResult
    func tapIfThere(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        _ = e.waitForExistence(timeout: timeout)
        for _ in 0..<6 where !(e.exists && e.isHittable) {
            app.swipeUp()
            _ = e.waitForExistence(timeout: 1)
        }
        guard e.exists, e.isHittable else {
            XCTFail("couldn't reach \(e.identifier.isEmpty ? e.label : e.identifier)")
            return false
        }
        e.tap()
        return true
    }

    func testLook() {
        // The hub and its three pills.
        launch(start: nil)
        XCTAssert(app.maps.firstMatch.waitForExistence(timeout: 15), "the hub's map didn't load")
        // Lets the interruption monitor answer a prompt. Tap the top of the map:
        // at large text the panel covers the centre, and a tap there hits a pill.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        sleep(3)
        shot("1-hub-people")
        if tapIfThere(app.buttons["Weather"]) { sleep(2); shot("2-hub-weather") }
        if tapIfThere(app.buttons["Places"]) { sleep(1); shot("3-hub-places") }

        // My settings (the Me tab).
        launch(start: "me")
        sleep(2)
        shot("4-settings")
        app.swipeUp()
        shot("5-settings-more")

        // A conversation's person map and pair settings, when there's a friend.
        guard let f = env["LAB_FRIEND"], !f.isEmpty else { return }
        launch(start: "chats")
        if tapIfThere(app.buttons["conversation.map"], timeout: 10) {
            sleep(3)
            shot("6-person-map")
            app.navigationBars.buttons.firstMatch.tap()
        }
        if tapIfThere(app.buttons["conversation.pairSettings"]) {
            sleep(2)
            shot("7-pair-settings")
        }
    }
}
