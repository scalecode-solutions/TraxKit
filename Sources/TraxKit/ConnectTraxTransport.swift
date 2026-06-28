import Foundation
import Connect
import SwiftProtobuf

/// `TraxTransport` over Connect/protobuf — the new rail. Wraps the codegen'd
/// `Trax_V1_TraxServiceClient`, injects the bearer token per call, and maps the
/// kit's DTOs ↔ proto messages. A drop-in for `HTTPTraxTransport` behind the
/// protocol; the host chooses which via `TraxConfig`.
public struct ConnectTraxTransport: TraxTransport {
    private let client: Trax_V1_TraxServiceClient
    private let tokenProvider: @Sendable () async -> String?

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        let config = ProtocolClientConfig(host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec())
        let proto = ProtocolClient(httpClient: URLSessionHTTPClient(), config: config)
        self.client = Trax_V1_TraxServiceClient(client: proto)
        self.tokenProvider = tokenProvider
    }

    // MARK: - plumbing

    private func authHeaders() async throws -> Headers {
        // No token (expired with no refresh available) → fail fast with the
        // dedicated sentinel instead of sending an anonymous request that the
        // server would only reject as CodeUnauthenticated. TraxSync treats this
        // as transient and doesn't surface it as an error banner.
        guard let tok = await tokenProvider() else { throw TraxTransportError.notAuthenticated }
        return ["Authorization": ["Bearer \(tok)"]]
    }

    private func value<T>(_ r: ResponseMessage<T>) throws -> T {
        if let m = r.message { return m }
        if let e = r.error {
            // A token that reached the server but failed validation (expired /
            // bad signature) comes back as `.unauthenticated`. Collapse it onto
            // the same transient sentinel as the missing-token case so the host
            // can swallow it uniformly rather than flashing a raw RPC dump.
            if e.code == .unauthenticated { throw TraxTransportError.notAuthenticated }
            throw TraxError(error: .init(code: "\(e.code)", reason: nil,
                                         message: e.message ?? "rpc failed"), httpStatus: nil)
        }
        throw TraxTransportError.network("empty rpc response")
    }

    // MARK: - Feed

    public func feed(since: Int64?, limit: Int?) async throws -> FeedDTO {
        var req = Trax_V1_FeedRequest()
        if let since { req.since = since }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.feed(request: req, headers: try await authHeaders()))
        return FeedDTO(shares: r.shares.map(shareDTO),
                       transitions: r.transitions.map(transitionDTO),
                       syncTs: r.syncTs, hasMore: r.hasMore_p,
                       stoppedIds: r.stoppedIds.map(uid))
    }

    // MARK: - Producer

    public func track(_ body: TrackBody) async throws -> TrackAckDTO {
        var req = Trax_V1_TrackRequest()
        req.lat = body.lat; req.lng = body.lng
        if let v = body.accuracy { req.accuracy = v }
        if let v = body.altitude { req.altitude = v }
        if let v = body.speed { req.speed = v }
        if let v = body.heading { req.heading = v }
        if let v = body.motion { req.motion = v }
        if let v = body.network { req.network = v }
        if let v = body.batteryLevel { req.batteryLevel = Int32(v) }
        if let v = body.batteryCharging { req.batteryCharging = v }
        if let v = body.clientTs { req.clientTs = v }
        if let v = body.recordedAt { req.recordedAt = v }
        let r = try value(await client.track(request: req, headers: try await authHeaders()))
        return TrackAckDTO(ok: r.ok, shares: Int(r.shares), ts: r.ts)
    }

    // MARK: - Shares

    public func startShare(_ body: StartShareBody) async throws -> ShareDTO {
        var req = Trax_V1_StartShareRequest()
        req.viewer = body.viewer.uuidString
        if let v = body.mode { req.mode = v }
        if let v = body.retention { req.retention = v }
        if let v = body.precision { req.precision = v }
        if let v = body.expiresIn { req.expiresIn = Int32(v) }
        return shareDTO(try value(await client.startShare(request: req, headers: try await authHeaders())))
    }

    public func stopShare(id: UUID) async throws {
        var req = Trax_V1_StopShareRequest(); req.id = id.uuidString
        _ = try value(await client.stopShare(request: req, headers: try await authHeaders()))
    }

    public func stopAllShares() async throws -> CountDTO {
        let r = try value(await client.stopAllShares(request: .init(), headers: try await authHeaders()))
        return CountDTO(count: r.count)
    }

    public func shares() async throws -> SharesDTO {
        let r = try value(await client.listShares(request: .init(), headers: try await authHeaders()))
        return SharesDTO(outgoing: r.outgoing.map(shareDTO), incoming: r.incoming.map(shareDTO))
    }

    // MARK: - Trail / history

    public func points(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> PointsDTO {
        var req = Trax_V1_ListPointsRequest()
        req.ownerID = ownerId.uuidString
        if let since { req.since = since }
        if let before { req.before = before }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.listPoints(request: req, headers: try await authHeaders()))
        return PointsDTO(ownerId: uid(r.ownerID), points: r.points.map(pointDTO))
    }

    public func clearHistory(before: Int64?) async throws -> CountDTO {
        var req = Trax_V1_ClearHistoryRequest()
        if let before { req.before = before }
        let r = try value(await client.clearHistory(request: req, headers: try await authHeaders()))
        return CountDTO(count: r.count)
    }

    // MARK: - Directory

    public func contacts() async throws -> [TraxContact] {
        let r = try value(await client.listContacts(request: .init(), headers: try await authHeaders()))
        return r.contacts.map(contact)
    }

    public func me() async throws -> TraxContact {
        contact(try value(await client.getMe(request: .init(), headers: try await authHeaders())))
    }

    // MARK: - Places

    public func places() async throws -> [PlaceDTO] {
        let r = try value(await client.listPlaces(request: .init(), headers: try await authHeaders()))
        return r.places.map(placeDTO)
    }

    public func createPlace(_ body: PlaceBody) async throws -> PlaceDTO {
        var req = Trax_V1_CreatePlaceRequest()
        req.name = body.name; req.type = body.type; req.lat = body.lat; req.lng = body.lng
        req.radiusM = Int32(body.radiusM)
        if let v = body.emoji { req.emoji = v }
        if let v = body.address { req.address = v }
        return placeDTO(try value(await client.createPlace(request: req, headers: try await authHeaders())))
    }

    public func updatePlace(id: UUID, _ body: PlaceBody) async throws -> PlaceDTO {
        var req = Trax_V1_UpdatePlaceRequest()
        req.id = id.uuidString
        req.name = body.name; req.type = body.type; req.lat = body.lat; req.lng = body.lng
        req.radiusM = Int32(body.radiusM)
        if let v = body.emoji { req.emoji = v }
        if let v = body.address { req.address = v }
        return placeDTO(try value(await client.updatePlace(request: req, headers: try await authHeaders())))
    }

    public func deletePlace(id: UUID) async throws {
        var req = Trax_V1_DeletePlaceRequest(); req.id = id.uuidString
        _ = try value(await client.deletePlace(request: req, headers: try await authHeaders()))
    }

    public func sharePlace(id: UUID, viewer: UUID) async throws {
        var req = Trax_V1_SharePlaceRequest(); req.id = id.uuidString; req.viewer = viewer.uuidString
        _ = try value(await client.sharePlace(request: req, headers: try await authHeaders()))
    }

    public func unsharePlace(id: UUID, viewer: UUID) async throws {
        var req = Trax_V1_UnsharePlaceRequest(); req.id = id.uuidString; req.viewer = viewer.uuidString
        _ = try value(await client.unsharePlace(request: req, headers: try await authHeaders()))
    }

    public func postTransition(_ body: TransitionBody) async throws {
        var req = Trax_V1_PostTransitionRequest()
        req.placeID = body.placeId.uuidString; req.event = body.event
        if let v = body.lat { req.lat = v }
        if let v = body.lng { req.lng = v }
        _ = try value(await client.postTransition(request: req, headers: try await authHeaders()))
    }

    // MARK: - Timeline

    public func trips(since: Int64?, limit: Int?) async throws -> [TripDTO] {
        var req = Trax_V1_ListTripsRequest()
        if let since { req.since = since }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.listTrips(request: req, headers: try await authHeaders()))
        return r.trips.map(tripDTO)
    }

    public func visits(since: Int64?, limit: Int?) async throws -> [VisitDTO] {
        var req = Trax_V1_ListVisitsRequest()
        if let since { req.since = since }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.listVisits(request: req, headers: try await authHeaders()))
        return r.visits.map(visitDTO)
    }

    public func tripsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [TripDTO] {
        var req = Trax_V1_ListOwnerTripsRequest()
        req.ownerID = ownerId.uuidString
        if let since { req.since = since }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.listOwnerTrips(request: req, headers: try await authHeaders()))
        return r.trips.map(tripDTO)
    }

    public func visitsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [VisitDTO] {
        var req = Trax_V1_ListOwnerVisitsRequest()
        req.ownerID = ownerId.uuidString
        if let since { req.since = since }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.listOwnerVisits(request: req, headers: try await authHeaders()))
        return r.visits.map(visitDTO)
    }

    public func transitionsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [TransitionDTO] {
        var req = Trax_V1_ListOwnerTransitionsRequest()
        req.ownerID = ownerId.uuidString
        if let since { req.since = since }
        if let limit { req.limit = Int32(limit) }
        let r = try value(await client.listOwnerTransitions(request: req, headers: try await authHeaders()))
        return r.transitions.map(transitionDTO)
    }
}

// MARK: - proto → DTO mapping

private func uid(_ s: String) -> UUID { UUID(uuidString: s) ?? UUID() }

private func locationDTO(_ l: Trax_V1_Location) -> LocationDTO {
    LocationDTO(
        lat: l.lat, lng: l.lng,
        accuracy: l.hasAccuracy ? l.accuracy : nil,
        altitude: l.hasAltitude ? l.altitude : nil,
        speed: l.hasSpeed ? l.speed : nil,
        heading: l.hasHeading ? l.heading : nil,
        motion: l.hasMotion ? l.motion : nil,
        network: l.hasNetwork ? l.network : nil,
        batteryLevel: l.hasBatteryLevel ? Int(l.batteryLevel) : nil,
        batteryCharging: l.hasBatteryCharging ? l.batteryCharging : nil,
        clientTs: l.hasClientTs ? l.clientTs : nil,
        recordedAt: l.recordedAt)
}

private func shareDTO(_ s: Trax_V1_Share) -> ShareDTO {
    ShareDTO(id: uid(s.id), ownerId: uid(s.ownerID), viewerId: uid(s.viewerID),
             mode: s.mode, retention: s.retention, precision: s.precision,
             startedAt: s.startedAt, expiresAt: s.hasExpiresAt ? s.expiresAt : nil,
             location: s.hasLocation ? locationDTO(s.location) : nil,
             fuzzRadiusM: s.hasFuzzRadiusM ? s.fuzzRadiusM : nil,
             placeName: s.hasPlaceName ? s.placeName : nil,
             placeEmoji: s.hasPlaceEmoji ? s.placeEmoji : nil,
             atPlace: s.hasAtPlace ? s.atPlace : nil)
}

private func transitionDTO(_ t: Trax_V1_Transition) -> TransitionDTO {
    TransitionDTO(id: uid(t.id), ownerId: uid(t.ownerID), placeId: uid(t.placeID),
                  placeName: t.placeName, placeEmoji: t.hasPlaceEmoji ? t.placeEmoji : nil,
                  event: t.event, createdAt: t.createdAt)
}

private func pointDTO(_ p: Trax_V1_Point) -> PointDTO {
    PointDTO(id: uid(p.id), lat: p.lat, lng: p.lng,
             accuracy: p.hasAccuracy ? p.accuracy : nil,
             altitude: p.hasAltitude ? p.altitude : nil,
             speed: p.hasSpeed ? p.speed : nil,
             heading: p.hasHeading ? p.heading : nil,
             motion: p.hasMotion ? p.motion : nil,
             network: p.hasNetwork ? p.network : nil,
             batteryLevel: p.hasBatteryLevel ? Int(p.batteryLevel) : nil,
             batteryCharging: p.hasBatteryCharging ? p.batteryCharging : nil,
             clientTs: p.hasClientTs ? p.clientTs : nil,
             recordedAt: p.recordedAt)
}

private func placeDTO(_ p: Trax_V1_Place) -> PlaceDTO {
    PlaceDTO(id: uid(p.id), ownerId: uid(p.ownerID), name: p.name, type: p.type,
             lat: p.lat, lng: p.lng, radiusM: Int(p.radiusM),
             emoji: p.hasEmoji ? p.emoji : nil, address: p.hasAddress ? p.address : nil,
             sharedWith: p.sharedWith.isEmpty ? nil : p.sharedWith.map(uid),
             createdAt: p.createdAt, updatedAt: p.updatedAt)
}

private func contact(_ c: Trax_V1_Contact) -> TraxContact {
    TraxContact(id: uid(c.id), name: c.name, avatar: c.hasAvatar ? c.avatar : nil)
}

private func tripDTO(_ t: Trax_V1_Trip) -> TripDTO {
    TripDTO(id: uid(t.id), startTs: t.startTs, endTs: t.endTs,
            startLat: t.startLat, startLng: t.startLng, endLat: t.endLat, endLng: t.endLng,
            startPlaceName: t.hasStartPlaceName ? t.startPlaceName : nil,
            startPlaceEmoji: t.hasStartPlaceEmoji ? t.startPlaceEmoji : nil,
            endPlaceName: t.hasEndPlaceName ? t.endPlaceName : nil,
            endPlaceEmoji: t.hasEndPlaceEmoji ? t.endPlaceEmoji : nil,
            distanceMeters: t.distanceMeters, durationSeconds: Int(t.durationSeconds),
            maxSpeed: t.hasMaxSpeed ? t.maxSpeed : nil,
            avgSpeed: t.hasAvgSpeed ? t.avgSpeed : nil,
            motionType: t.hasMotionType ? t.motionType : nil,
            pointCount: Int(t.pointCount))
}

private func visitDTO(_ v: Trax_V1_Visit) -> VisitDTO {
    VisitDTO(id: uid(v.id), startTs: v.startTs, endTs: v.endTs, lat: v.lat, lng: v.lng,
             durationSeconds: Int(v.durationSeconds),
             placeName: v.hasPlaceName ? v.placeName : nil,
             placeEmoji: v.hasPlaceEmoji ? v.placeEmoji : nil,
             pointCount: Int(v.pointCount))
}
