import SwiftUI
import MapKit

/// The user's own timeline — Life360 map-forward: the day's route on a map up
/// top, a chronological trips+visits journey list below, a day scrubber. Tapping
/// a row focuses the map on it. Self-only (v1); friend timelines come later.
public struct TraxTimelineView: View {
    let sync: TraxSync

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var camera: MapCameraPosition = .automatic
    @State private var loading = false

    public init(sync: TraxSync) { self.sync = sync }

    /// Trips + visits interleaved by start time (the journey).
    private var items: [TimelineItem] {
        let t = sync.timelineTrips.map { TimelineItem.trip($0) }
        let v = sync.timelineVisits.map { TimelineItem.visit($0) }
        return (t + v).sorted { $0.startTs < $1.startTs }
    }

    private var routeCoords: [CLLocationCoordinate2D] {
        sync.timelinePoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            scrubber
            mapHeader.frame(height: 240)
            journeyList
        }
        .task(id: day) { await reload() }
    }

    // MARK: - scrubber

    private var scrubber: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(dayLabel).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isToday)
                .opacity(isToday ? 0.3 : 1)
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
        }
    }

    // MARK: - map

    private var mapHeader: some View {
        Map(position: $camera) {
            UserAnnotation()
            if routeCoords.count > 1 {
                MapPolyline(coordinates: routeCoords)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(sync.timelineVisits) { v in
                Marker(v.placeName ?? "Stop", monogram: Text(v.placeEmoji ?? "📍"),
                       coordinate: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lng))
            }
        }
        .onChange(of: sync.timelinePoints.count) { _, _ in fitRoute() }
    }

    private func fitRoute() {
        guard !routeCoords.isEmpty else { camera = .userLocation(fallback: .automatic); return }
        withAnimation { camera = .automatic }   // MapKit fits the content
    }

    private func focus(_ coord: CLLocationCoordinate2D) {
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
    }

    // MARK: - journey list

    @ViewBuilder private var journeyList: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label(loading ? "Loading…" : "No activity", systemImage: "clock")
            } description: {
                Text(loading ? "" : "Trips and stops for this day will appear here.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List(items) { item in
                Button { focus(item.coordinate) } label: { row(item) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .visit(let v):
            HStack(spacing: 12) {
                Text(v.placeEmoji ?? "📍").font(.title2)
                    .frame(width: 34, height: 34).background(Color.accentColor.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.placeName ?? "Stop").font(.body)
                    Text("\(timeRange(v.startTs, v.endTs)) · \(durationText(v.durationSeconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .trip(let t):
            HStack(spacing: 12) {
                Image(systemName: motionSymbol(t.motionType)).font(.body)
                    .frame(width: 34, height: 34)
                    .background(motionColor(t.motionType).opacity(0.18), in: .circle)
                    .foregroundStyle(motionColor(t.motionType))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tripTitle(t)).font(.body)
                    Text("\(timeRange(t.startTs, t.endTs)) · \(distanceText(t.distanceMeters))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - load + formatting

    private func reload() async {
        loading = true
        await sync.loadTimeline(day: day)
        loading = false
        fitRoute()
    }

    private func tripTitle(_ t: TripDTO) -> String {
        let a = t.startPlaceName ?? "Start", b = t.endPlaceName ?? "End"
        return "\(a) → \(b)"
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
    private func durationText(_ s: Int) -> String {
        s < 3600 ? "\(s/60)m" : "\(s/3600)h \((s%3600)/60)m"
    }
    private func distanceText(_ m: Double) -> String {
        let mi = m / 1609.34
        return mi < 0.1 ? "\(Int(m)) m" : String(format: "%.1f mi", mi)
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
