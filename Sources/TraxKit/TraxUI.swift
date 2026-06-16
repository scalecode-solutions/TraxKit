import SwiftUI
import UIKit

// Shared UI primitives for TraxKit — the glass pane and the member avatar.
// Themeable: colors come from the host's `.accentColor` (Clingy's tardisBlue),
// no hard-coded brand colors, so the SPM matches whatever app embeds it. Mirrors
// PulseKit's PulseUI conventions.

extension View {
    /// Inline nav title.
    func traxInlineNavTitle(_ title: String) -> some View {
        self.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    /// The cardless glass pane (iOS 26 Liquid Glass; material fallback otherwise).
    @ViewBuilder
    func traxGlassPane(_ cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, *) {
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Member avatar — renders the base64 thumbnail synced from the social-graph
/// people directory (`TraxContact.avatar` / `ContactEntity.avatar`), with an
/// initials-circle fallback. Decoded once per person and cached.
public struct TraxAvatar: View {
    let id: UUID?
    let name: String?
    let avatarBase64: String?
    var size: CGFloat = 40

    @State private var image: UIImage?

    public init(id: UUID?, name: String?, avatarBase64: String?, size: CGFloat = 40) {
        self.id = id; self.name = name; self.avatarBase64 = avatarBase64; self.size = size
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: id) { image = TraxAvatarCache.image(id: id, base64: avatarBase64) }
    }

    private var initials: String {
        guard let name, !name.isEmpty else { return "?" }
        return name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

/// Decodes + caches avatar thumbnails (base64 → UIImage once per person).
enum TraxAvatarCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func image(id: UUID?, base64: String?) -> UIImage? {
        guard let id, let b64 = base64, !b64.isEmpty else { return nil }
        let key = id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: b64), let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
