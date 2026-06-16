import SwiftUI
import MapKit

/// A timeline/history screen for ONE owner (self or a friend who shares with
/// you) — Life360's full-screen History: the day's route on a map up top, a
/// day scrubber, a chronological trips+visits journey list below. Tapping a
/// journey highlights + frames it on THIS screen's own map (the list stays put —
/// no stuck sheet). Pushed onto a nav stack (back button returns), or hosted in
/// the self Timeline tab.
public struct TraxTimelineView: View {
    let sync: TraxSync
    let owner: UUID
    let title: String

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var data = TimelineDay()
    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedJourney: UUID?
    @State private var loading = false

    public init(sync: TraxSync, owner: UUID, title: String) {
        self.sync = sync
        self.owner = owner
        self.title = title
    }

    /// Trips + visits interleaved, most recent first.
    private var items: [TimelineItem] {
        let t = data.trips.map { TimelineItem.trip($0) }
        let v = data.visits.map { TimelineItem.visit($0) }
        return (t + v).sorted { $0.startTs > $1.startTs }
    }

    private var dayCoords: [CLLocationCoordinate2D] {
        data.points.sorted { $0.recordedAt < $1.recordedAt }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }

    /// The selected trip's sub-segment (points within its window), highlighted.
    private var journeyCoords: [CLLocationCoordinate2D] {
        guard let id = selectedJourney,
              case let .trip(t)? = items.first(where: { $0.id == id }) else { return [] }
        return data.points
            .filter { $0.recordedAt >= t.startTs && $0.recordedAt <= t.endTs }
            .sorted { $0.recordedAt < $1.recordedAt }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            scrubber
            mapHeader.frame(height: 240)
            journeyList
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dayKey) { await reload() }
    }

    private var dayKey: String { "\(owner)-\(day.timeIntervalSince1970)" }

    // MARK: - scrubber

    private var scrubber: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(dayLabel).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isToday).opacity(isToday ? 0.3 : 1)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var dayLabel: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: day) {
            day = Calendar.current.startOfDay(for: d)
            selectedJourney = nil
        }
    }

    // MARK: - map

    private var mapHeader: some View {
        Map(position: $camera) {
            UserAnnotation()
            // Whole day faint; selected trip bold on top.
            if dayCoords.count > 1 {
                MapPolyline(coordinates: dayCoords)
                    .stroke(Color.accentColor.opacity(selectedJourney == nil ? 0.7 : 0.25),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if journeyCoords.count > 1 {
                MapPolyline(coordinates: journeyCoords)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            ForEach(data.visits) { v in
                Marker(v.placeName ?? "Stop", monogram: Text(v.placeEmoji ?? "📍"),
                       coordinate: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lng))
            }
        }
    }

    private func frame(_ coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.5),
                                    longitudeDelta: max(0.005, (lngs.max()! - lngs.min()!) * 1.5))
        withAnimation(.easeInOut) { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    private func select(_ item: TimelineItem) {
        selectedJourney = item.id
        switch item {
        case .trip:
            // journeyCoords recomputes from the new selection; frame it next runloop.
            DispatchQueue.main.async { frame(journeyCoords) }
        case .visit(let v):
            withAnimation(.easeInOut) {
                camera = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lng),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
        }
    }

    // MARK: - list

    @ViewBuilder private var journeyList: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label(loading ? "Loading…" : "No activity", systemImage: "clock")
            } description: {
                Text(loading ? "" : "Trips and stops for this day will appear here.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List(items, selection: $selectedJourney) { item in
                Button { select(item) } label: { JourneyRow(item: item) }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedJourney == item.id ? Color.accentColor.opacity(0.12) : nil)
            }
            .listStyle(.plain)
        }
    }

    private func reload() async {
        loading = true
        data = await sync.timeline(ownerID: owner, day: day)
        loading = false
        selectedJourney = nil
        frame(dayCoords)
    }
}

/// One entry in the interleaved journey (a trip or a dwell).
enum TimelineItem: Identifiable {
    case trip(TripDTO)
    case visit(VisitDTO)

    var id: UUID { switch self { case .trip(let t): t.id; case .visit(let v): v.id } }
    var startTs: Int64 { switch self { case .trip(let t): t.startTs; case .visit(let v): v.startTs } }
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .trip(let t): CLLocationCoordinate2D(latitude: t.startLat, longitude: t.startLng)
        case .visit(let v): CLLocationCoordinate2D(latitude: v.lat, longitude: v.lng)
        }
    }
}
