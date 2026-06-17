import Foundation
import CoreLocation
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

    public override init() {
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

    /// Request the next step: undetermined → When-In-Use; When-In-Use → Always.
    public func request() {
        switch status {
        case .notDetermined:       manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
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
