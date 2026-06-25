import Foundation
import CoreLocation
import CoreMotion
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Observes + requests location authorization for the onboarding gate. iOS
/// permission prompts are one-shot — if a user denies, the only recovery is
/// Settings — so the app primes (explains why) before requesting, and surfaces a
/// remediation path if denied/downgraded.
@MainActor
@Observable
public final class TraxPermissions: NSObject, CLLocationManagerDelegate {
    public private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private let motionMgr = CMMotionActivityManager()
    private var dialogObserver: NSObjectProtocol?

    /// Host hook around the OS permission prompts. Called `true` just before a
    /// prompt (or a queued run of them) appears and `false` once they're all
    /// dismissed, so a host (e.g. Clingy) can flag the prompts' inactive blips and
    /// keep its scene-phase security chain from treating them as a real
    /// backgrounding (privacy-lock / socket-drop).
    private let onSystemDialog: (@MainActor (Bool) -> Void)?

    public init(onSystemDialog: (@MainActor (Bool) -> Void)? = nil) {
        self.onSystemDialog = onSystemDialog
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Has the user made a usable choice (When-In-Use or Always)? The app proper
    /// opens once this is true; background + the Always escalation come later from
    /// the producer.
    public var isAuthorized: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }
    public var isAlways: Bool { status == .authorizedAlways }
    public var isDenied: Bool { status == .denied || status == .restricted }
    /// Has the user responded to the location prompt yet (granted OR denied)?
    /// Drives the onboarding exit: a denial still enters the app in watch-only
    /// mode — you see the people who share with you without sharing your own.
    public var hasChosen: Bool { status != .notDetermined }

    /// Onboarding action: ask for location AND motion together, so motion never
    /// ambush-prompts later (it's queued right behind location at a known moment),
    /// and bracket the whole sequence in the host's system-dialog guard so the
    /// prompts' inactive blips don't read as a real backgrounding.
    ///
    /// Denying is a first-class outcome — the app still opens (watch-only); sharing
    /// just won't produce until location is granted. Requesting Always up front
    /// shows the same first prompt as When-In-Use but lets iOS later offer the
    /// background upgrade, so sharing can keep working when backgrounded.
    public func requestPermissions() {
        let willPromptLocation = status == .notDetermined || status == .authorizedWhenInUse
        let willPromptMotion = CMMotionActivityManager.isActivityAvailable()
            && CMMotionActivityManager.authorizationStatus() == .notDetermined
        guard willPromptLocation || willPromptMotion else { return }

        beginDialogGuard()
        if willPromptLocation { manager.requestAlwaysAuthorization() }
        if willPromptMotion {
            // A zero-window query is the lightest way to surface the Motion &
            // Fitness prompt without committing to live activity updates.
            let now = Date()
            motionMgr.queryActivityStarting(from: now, to: now, to: .main) { _, _ in }
        }
    }

    /// Flag the host that a prompt (or queued run) is up and arm a one-shot end on
    /// the next app re-activation — the reliable "all dismissed" signal that covers
    /// allow, deny, and back-to-back prompts alike, without sticking the flag true.
    private func beginDialogGuard() {
        onSystemDialog?(true)
        #if canImport(UIKit)
        guard dialogObserver == nil else { return }
        dialogObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.endDialogGuard() } }
        #else
        onSystemDialog?(false)
        #endif
    }
    private func endDialogGuard() {
        onSystemDialog?(false)
        #if canImport(UIKit)
        if let o = dialogObserver { NotificationCenter.default.removeObserver(o); dialogObserver = nil }
        #endif
    }

    public func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
