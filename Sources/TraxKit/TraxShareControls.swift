import SwiftUI

/// My share to one person: start it (duration + precision), or see it, change
/// it and stop it. Shared by the person map's card and the pair settings.
/// Changing a live share is `startSharing` again (the server updates it in place).
struct TraxShareControls: View {
    let engine: TraxEngine
    let personID: UUID
    let personName: String
    let appearance: TraxAppearance

    @State private var duration: DurationChoice = .fallback
    @State private var precision: SharePrecision = .exact
    @State private var busy = false
    @State private var error: String?
    @State private var changing = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var outgoing: TraxOutgoingShare? {
        engine.outgoingShares.first { $0.viewerID == personID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outgoing, !changing {
                sharingRow(outgoing)
            } else {
                chooser
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("share.error")
            }
        }
        // The share ended or was stopped elsewhere while changing it: back to
        // a fresh chooser, not a half-kept change.
        .onChange(of: outgoing == nil) { _, gone in
            guard gone else { return }
            changing = false
            duration = .fallback
        }
    }

    // MARK: sharing now

    private func sharingRow(_ s: TraxOutgoingShare) -> some View {
        // One row when it fits; stacked at large text, never squeezed.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                sharingLabel(s)
                Spacer(minLength: 8)
                sharingButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                sharingLabel(s)
                sharingButtons
            }
        }
    }

    private func sharingLabel(_ s: TraxOutgoingShare) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(appearance.sharingWith, systemImage: "location.fill")
                .font(.subheadline.weight(.semibold))
            Text(detail(s)).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("share.detail")
        }
    }

    private var sharingButtons: some View {
        HStack(spacing: 10) {
            // "Edit": short enough to stay on one line at the largest text.
            Button("Edit") {
                if let s = outgoing {
                    precision = SharePrecision(rawValue: s.precision?.rawValue ?? "exact") ?? .exact
                    duration = DurationChoice.initial(for: s)
                }
                changing = true
            }
            .traxSecondaryAction()
            .accessibilityIdentifier("share.change")
            Button("Stop", role: .destructive) { stop() }
                .traxDestructiveAction()
                .disabled(busy)
                .accessibilityIdentifier("share.stop")
        }
        .frame(minHeight: 44)
    }

    private func detail(_ s: TraxOutgoingShare) -> String {
        let p = SharePrecision(rawValue: s.precision?.rawValue ?? "")?.label ?? "Exact"
        if let until = s.expiresAt {
            return "\(p) · until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "\(p) · until you stop"
    }

    // MARK: choosing

    /// Segmented pickers while they fit; menus from extra-extra-large text.
    private var useMenus: Bool { typeSize >= .xxLarge }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            picker("Duration", selection: $duration, id: "share.duration") {
                ForEach(DurationChoice.options(changing: changing ? outgoing : nil), id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            picker("Precision", selection: $precision, id: "share.precision") {
                ForEach(SharePrecision.allCases) { Text($0.label).tag($0) }
            }
            Text(precision.blurb).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { start() } label: {
                Group {
                    if busy { ProgressView() }
                    else {
                        HStack(spacing: 8) {
                            Image(systemName: "location.fill")
                            Text(outgoing == nil ? appearance.with(appearance.shareButton, personName) : "Update sharing")
                                .multilineTextAlignment(.center)
                        }
                        // On the host's tint: the host's own pick (it knows its
                        // colours; white misses AA on some, e.g. a mid blue).
                        .foregroundStyle(appearance.onTint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(busy)
            .accessibilityIdentifier("share.start")
            if changing {
                Button("Cancel") { changing = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(Color.primary)
                    .accessibilityIdentifier("share.cancelChange")
            }
        }
    }

    @ViewBuilder
    private func picker<V: Hashable, C: View>(_ title: String, selection: Binding<V>, id: String,
                                              @ViewBuilder content: () -> C) -> some View {
        if typeSize.isAccessibilitySize {
            // Title above its menu: side by side, the largest sizes break the
            // words ("Dura-tion") outside a List, which stacks on its own.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Picker(title, selection: selection, content: content).pickerStyle(.menu).labelsHidden()
                    .tint(Color.primary)   // the value is text: never the host's tint
                    .frame(minHeight: 44)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        } else if useMenus {
            LabeledContent(title) {
                // Hidden: LabeledContent shows the title (a List would show it twice).
                Picker(title, selection: selection, content: content).pickerStyle(.menu).labelsHidden()
                    .tint(Color.primary)   // the value is text: never the host's tint
            }
            .accessibilityIdentifier(id)
        } else {
            Picker(title, selection: selection, content: content)
                .pickerStyle(.segmented)
                .accessibilityIdentifier(id)
        }
    }

    // MARK: actions

    private func start() {
        // The active decision: the only moment the kit asks for location access.
        engine.requestLocationAccess()
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await engine.startSharing(
                    with: personID, precision: TraxPrecision(rawValue: precision.rawValue) ?? .exact,
                    duration: duration.duration(current: outgoing, now: Date()))
                changing = false
            } catch {
                self.error = "Couldn't update sharing. Try again."
            }
        }
    }

    private func stop() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await engine.stopSharing(with: personID) }
            catch { self.error = "Couldn't stop sharing. Try again." }
        }
    }
}

/// The duration picker's choices. Changing a timed share offers to keep its
/// current end; without that, changing only the precision would also reset
/// how long it lasts (starting a share again replaces its expiry).
enum DurationChoice: Hashable {
    case preset(ShareDuration)
    case keepCurrent

    /// The chooser's starting choice for a new share.
    static let fallback = DurationChoice.preset(.fifteenMinutes)

    var label: String {
        switch self {
        case .preset(let d): d.label
        case .keepCurrent: "Keep current end"
        }
    }

    /// Changing `share`: keep its end if it has one, else "until I stop".
    static func initial(for share: TraxOutgoingShare) -> DurationChoice {
        share.expiresAt == nil ? .preset(.indefinite) : .keepCurrent
    }

    /// What to offer: the presets, plus "keep current end" when changing a timed share.
    static func options(changing share: TraxOutgoingShare?) -> [DurationChoice] {
        let presets = ShareDuration.allCases.map(DurationChoice.preset)
        return share?.expiresAt != nil ? [.keepCurrent] + presets : presets
    }

    /// The duration to send: a preset's length, nil for until-I-stop, or what's
    /// left of the current share (at least a minute, so a share about to end
    /// isn't sent a zero).
    func duration(current: TraxOutgoingShare?, now: Date) -> Duration? {
        switch self {
        case .preset(let d):
            return d.expiresInSeconds.map { .seconds($0) }
        case .keepCurrent:
            // No timed share to keep (it ended or was stopped meanwhile): the
            // default length, never an until-I-stop nobody chose.
            guard let end = current?.expiresAt else { return Self.fallback.duration(current: nil, now: now) }
            return .seconds(max(60, Int(end.timeIntervalSince(now).rounded(.up))))
        }
    }
}
