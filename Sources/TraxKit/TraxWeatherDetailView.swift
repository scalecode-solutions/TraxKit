import SwiftUI

/// Full forecast for a coordinate — the Tier 2 drill-down. Pushed from the Me tab
/// (own weather) and a sharer's glance card (their weather). Faithful to Tangle's
/// in-panel stack (now → precip → hourly 24h → 10-day → metrics) but as its own
/// navigable screen rather than crammed into a sheet.
public struct TraxWeatherDetailView: View {
    let store: TraxWeatherStore
    let latitude: Double
    let longitude: Double
    var title: String

    @State private var detail: TraxWeatherDetail?

    public init(store: TraxWeatherStore, latitude: Double, longitude: Double, title: String = "Weather") {
        self.store = store; self.latitude = latitude; self.longitude = longitude; self.title = title
    }

    private var regionKey: String { "\(Int(latitude * 10)),\(Int(longitude * 10))" }

    public var body: some View {
        ScrollView {
            if let d = detail {
                VStack(spacing: 18) {
                    nowHeader(d)
                    if let s = d.precipSummary { precipCard(s) }
                    if !d.hourly.isEmpty { hourlyStrip(d) }
                    if !d.daily.isEmpty { dailyList(d) }
                    metricsGrid(d)
                }
                .padding()
            } else {
                ContentUnavailableView("Weather unavailable", systemImage: "cloud.slash",
                                       description: Text("No forecast for this location right now."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: regionKey) {
            detail = store.cachedDetail(latitude: latitude, longitude: longitude)
            await store.refreshDetail(latitude: latitude, longitude: longitude)
            detail = store.cachedDetail(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: Now

    private func nowHeader(_ d: TraxWeatherDetail) -> some View {
        let c = d.current
        return VStack(spacing: 6) {
            Image(systemName: c.symbolName).symbolRenderingMode(.multicolor).font(.system(size: 52))
            Text(c.tempText).font(.system(size: 56, weight: .thin))
            Text(c.condition).font(.headline)
            HStack(spacing: 12) {
                if let f = c.feelsLikeC { Text("Feels \(TraxWeather.temp(f))") }
                if let h = c.highC, let l = c.lowC {
                    Text("H:\(TraxWeather.temp(h))  L:\(TraxWeather.temp(l))")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func precipCard(_ summary: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "umbrella.fill").foregroundStyle(.blue)
            Text(summary).font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
    }

    // MARK: Hourly (24h strip)

    private static let hourFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "ha"; return f
    }()

    private func hourlyStrip(_ d: TraxWeatherDetail) -> some View {
        section("Hourly") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(Array(d.hourly.enumerated()), id: \.element.id) { i, h in
                        VStack(spacing: 6) {
                            Text(i == 0 ? "Now" : Self.hourFmt.string(from: h.date).lowercased())
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: h.symbolName).symbolRenderingMode(.multicolor).font(.title3)
                            Text(h.precipChance > 0.15 ? "\(Int(h.precipChance * 100))%" : " ")
                                .font(.caption2).foregroundStyle(.blue)
                            Text(TraxWeather.temp(h.temperatureC)).font(.subheadline.weight(.medium))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 10-day list

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    private func dailyList(_ d: TraxWeatherDetail) -> some View {
        let lo = d.daily.map(\.lowC).min() ?? 0
        let hi = d.daily.map(\.highC).max() ?? 1
        let range = max(hi - lo, 1)
        return section("\(d.daily.count)-Day Forecast") {
            VStack(spacing: 10) {
                ForEach(Array(d.daily.enumerated()), id: \.element.id) { i, day in
                    HStack(spacing: 12) {
                        Text(i == 0 ? "Today" : Self.dayFmt.string(from: day.date))
                            .font(.subheadline).frame(width: 44, alignment: .leading)
                        Image(systemName: day.symbolName).symbolRenderingMode(.multicolor)
                            .frame(width: 24)
                        Text(TraxWeather.temp(day.lowC)).font(.subheadline)
                            .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        rangeBar(low: day.lowC, high: day.highC, globalLow: lo, globalRange: range)
                        Text(TraxWeather.temp(day.highC)).font(.subheadline)
                            .frame(width: 36, alignment: .leading)
                    }
                }
            }
        }
    }

    private func rangeBar(low: Double, high: Double, globalLow: Double, globalRange: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let start = CGFloat((low - globalLow) / globalRange) * w
            let len = max(CGFloat((high - low) / globalRange) * w, 6)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 5)
                Capsule()
                    .fill(LinearGradient(colors: [.blue.opacity(0.7), .orange.opacity(0.85)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: len, height: 5).offset(x: start)
            }
        }
        .frame(height: 16)
    }

    // MARK: Metrics grid

    private func metricsGrid(_ d: TraxWeatherDetail) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return section("Details") {
            LazyVGrid(columns: cols, spacing: 12) {
                if let uv = d.uvIndex {
                    metric("UV Index", "\(uv)\(d.uvCategory.map { " · \($0)" } ?? "")", "sun.max.fill")
                }
                if let s = d.windSpeedKmh {
                    metric("Wind", "\(TraxWeather.wind(s))\(d.windDirection.map { " \($0)" } ?? "")", "wind")
                }
                if let h = d.humidity { metric("Humidity", "\(Int(h * 100))%", "humidity.fill") }
                if let p = d.pressureHpa { metric("Pressure", "\(Int(p.rounded())) hPa", "gauge.with.dots.needle.50percent") }
                if let v = d.visibilityKm { metric("Visibility", TraxWeather.distance(v), "eye.fill") }
                if let r = d.sunrise { metric("Sunrise", Self.timeFmt.string(from: r), "sunrise.fill") }
                if let s = d.sunset { metric("Sunset", Self.timeFmt.string(from: s), "sunset.fill") }
            }
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            Text(value).font(.title3.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
    }

    // MARK: section chrome

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }
}
