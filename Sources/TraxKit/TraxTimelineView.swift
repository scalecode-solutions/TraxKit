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

    /// The day, prepared once when it loads: trips + visits interleaved (most
    /// recent first) and the points in time order. Sorting a whole day (up to
    /// 2,000 points) on every render was the cost.
    @State private var prepared = PreparedDay()

    private var items: [TimelineItem] { prepared.items }
    private var dayCoords: [CLLocationCoordinate2D] { prepared.coords }

    /// The selected trip's sub-segment (points within its window), highlighted.
    private var journeyCoords: [CLLocationCoordinate2D] {
        guard let id = selectedJourney,
              case let .trip(t)? = items.first(where: { $0.id == id }) else { return [] }
        return zip(prepared.times, prepared.coords)
            .filter { $0.0 >= t.startTs && $0.0 <= t.endTs }
            .map(\.1)
    }

    public var body: some View {
        VStack(spacing: 0) {
            scrubber
            mapHeader.frame(height: 240)
            journeyList
        }
        .background { TraxBackdrop() }
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
                    .stroke(.tint.opacity(selectedJourney == nil ? 0.7 : 0.25),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if journeyCoords.count > 1 {
                MapPolyline(coordinates: journeyCoords)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
        case .trip(let t):
            // The trip's own points, computed here rather than read back from
            // journeyCoords on the next runloop.
            frame(zip(prepared.times, prepared.coords)
                .filter { $0.0 >= t.startTs && $0.0 <= t.endTs }.map(\.1))
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
                    .listRowBackground(selectedJourney == item.id ? Rectangle().fill(.tint.opacity(0.12)) : nil)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)   // the backdrop shows through
        }
    }

    private func reload() async {
        loading = true
        let fetched = await sync.timeline(ownerID: owner, day: day)
        // A cancelled load (the day changed, the view re-appeared) comes back
        // empty: dropping it keeps it from wiping the trail and leaving the
        // camera un-framed, the "continent and no trail" a screenshot caught.
        guard !Task.isCancelled else { return }
        data = fetched
        prepared = PreparedDay(data)
        loading = false
        selectedJourney = nil
        // Frame the trail, or the day's stops when there's no trail.
        frame(dayCoords.isEmpty ? data.visits.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) } : dayCoords)
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

/// A compact journey row (a trip or a dwell) used in the timeline list.
struct JourneyRow: View {
    let item: TimelineItem

    var body: some View {
        switch item {
        case .visit(let v):
            row(emoji: v.placeEmoji ?? "📍", color: AnyShapeStyle(.tint),
                title: v.placeName ?? "Stop",
                detail: "\(timeRange(v.startTs, v.endTs)) · \(durationText(v.durationSeconds))")
        case .trip(let t):
            HStack(spacing: 12) {
                Image(systemName: motionSymbol(t.motionType)).font(.body)
                    .frame(width: 32, height: 32)
                    .background(motionColor(t.motionType).opacity(0.18), in: .circle)
                    .foregroundStyle(motionColor(t.motionType))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(t.startPlaceName ?? "Start") → \(t.endPlaceName ?? "End")").font(.subheadline)
                    Text("\(timeRange(t.startTs, t.endTs)) · \(distanceText(t.distanceMeters))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func row(emoji: String, color: AnyShapeStyle, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.title3).frame(width: 32, height: 32).background(color.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func motionSymbol(_ m: String?) -> String {
        switch m { case "automotive": "car.fill"; case "cycling": "bicycle"
        case "running": "figure.run"; case "walking": "figure.walk"; default: "arrow.right" }
    }
    private func motionColor(_ m: String?) -> Color {
        switch m { case "automotive": .orange; case "cycling": .green
        case "running": .red; case "walking": .blue; default: .gray }
    }
    private func timeRange(_ a: Int64, _ b: Int64) -> String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(Date(timeIntervalSince1970: Double(a)/1000).formatted(f))–\(Date(timeIntervalSince1970: Double(b)/1000).formatted(f))"
    }
    private func durationText(_ s: Int) -> String { s < 3600 ? "\(s/60)m" : "\(s/3600)h \((s%3600)/60)m" }
    private func distanceText(_ m: Double) -> String {
        let mi = m / 1609.34; return mi < 0.1 ? "\(Int(m)) m" : String(format: "%.1f mi", mi)
    }
}

/// A day's timeline in the order the screen shows it, built once per load.
struct PreparedDay {
    var items: [TimelineItem] = []
    var coords: [CLLocationCoordinate2D] = []
    var times: [Int64] = []

    init() {}
    init(_ day: TimelineDay) {
        items = (day.trips.map { TimelineItem.trip($0) } + day.visits.map { TimelineItem.visit($0) })
            .sorted { $0.startTs > $1.startTs }
        let pts = day.points.sorted { $0.recordedAt < $1.recordedAt }
        coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        times = pts.map(\.recordedAt)
    }
}
