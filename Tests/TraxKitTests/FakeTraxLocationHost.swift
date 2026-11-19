import Foundation
@testable import TraxKit

/// A scriptable `TraxLocationHost` for engine tests: no CoreLocation. Tests push
/// fixes and crossings through it and read back what the kit asked the device
/// for (tracking demand, monitored regions).
@MainActor
final class FakeTraxLocationHost: TraxLocationHost {
    var currentFix: TraxFix?
    var authorization: TraxLocationAuth = .always
    private(set) var accessRequests = 0
    private(set) var demands: [TraxTrackingDemand] = []
    private(set) var regionSets: [[TraxRegion]] = []
    var lastDemand: TraxTrackingDemand? { demands.last }
    var lastRegions: [TraxRegion]? { regionSets.last }

    private var fixCont: AsyncStream<TraxFix>.Continuation?
    private var crossingCont: AsyncStream<TraxTransition>.Continuation?

    func fixStream() -> AsyncStream<TraxFix> {
        let (s, c) = AsyncStream.makeStream(of: TraxFix.self)
        fixCont = c
        return s
    }
    func transitionStream() -> AsyncStream<TraxTransition> {
        let (s, c) = AsyncStream.makeStream(of: TraxTransition.self)
        crossingCont = c
        return s
    }
    func requestLocationAccess() { accessRequests += 1 }
    func setMonitoredRegions(_ regions: [TraxRegion]) { regionSets.append(regions) }
    func setDesiredTracking(_ demand: TraxTrackingDemand) { demands.append(demand) }

    // Scripting.
    func send(_ fix: TraxFix) { currentFix = fix; fixCont?.yield(fix) }
    func cross(_ placeID: UUID, _ event: TraxEvent) {
        crossingCont?.yield(TraxTransition(placeID: placeID, event: event, timestamp: Date()))
    }
}
