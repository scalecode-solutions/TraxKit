import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Live "me" signals for the self row + self pin: current coordinate and battery.
/// A lightweight CLLocationManager separate from the producer (the OS coalesces
/// the two), so the UI has an observable self-position without reaching into the
/// producer's send path.
@MainActor
@Observable
public final class TraxSelfState: NSObject, CLLocationManagerDelegate {
    public private(set) var coordinate: CLLocationCoordinate2D?
    public private(set) var batteryLevel: Int?
    public private(set) var batteryCharging = false

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func start() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged),
                                               name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged),
                                               name: UIDevice.batteryStateDidChangeNotification, object: nil)
        #endif
        refreshBattery()
        coordinate = manager.location?.coordinate
        manager.startUpdatingLocation()
    }

    public func stop() { manager.stopUpdatingLocation() }

    /// Battery in the shared presentation shape (reuses the member-status pill).
    public var battery: TraxBatteryStatus { TraxBatteryStatus(level: batteryLevel, charging: batteryCharging) }

    @objc private func batteryChanged() { refreshBattery() }

    private func refreshBattery() {
        #if canImport(UIKit)
        let l = UIDevice.current.batteryLevel
        batteryLevel = l >= 0 ? Int((l * 100).rounded()) : nil
        switch UIDevice.current.batteryState {
        case .charging, .full: batteryCharging = true
        default:               batteryCharging = false
        }
        #endif
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in self?.coordinate = loc.coordinate }
    }
}
