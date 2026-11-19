import SwiftUI

/// My share to one person: start it (duration + precision), or see it, change
/// it and stop it. Shared by the person map's card and the pair settings.
/// Changing a live share is `startSharing` again (the server updates it in place).
struct TraxShareControls: View {
    let engine: TraxEngine
    let personID: UUID
    let personName: String
    let appearance: TraxAppearance

    @State private var duration: ShareDuration = .fifteenMinutes
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
            Button("Change") {
                if let s = outgoing { precision = SharePrecision(rawValue: s.precision?.rawValue ?? "exact") ?? .exact }
                changing = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("share.change")
            Button("Stop", role: .destructive) { stop() }
                .buttonStyle(.bordered)
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
                ForEach(ShareDuration.allCases) { Text($0.label).tag($0) }
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
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier("share.start")
            if changing {
                Button("Cancel") { changing = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("share.cancelChange")
            }
        }
    }

    @ViewBuilder
    private func picker<V: Hashable, C: View>(_ title: String, selection: Binding<V>, id: String,
                                              @ViewBuilder content: () -> C) -> some View {
        if useMenus {
            LabeledContent(title) {
                // Hidden: LabeledContent shows the title (a List would show it twice).
                Picker(title, selection: selection, content: content).pickerStyle(.menu).labelsHidden()
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
                    duration: duration.expiresInSeconds.map { .seconds($0) })
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
