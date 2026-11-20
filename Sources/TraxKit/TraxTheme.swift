import SwiftUI

/// TraxKit's look: the family's living mesh backdrop (the recipe the sibling
/// kits use: neutral edges that follow the color scheme, near-black in dark and
/// near-white in light, an opaque base, 12 fps, still under Reduce Motion),
/// glowing in the host's `.tint`. The map is full bleed and doesn't get it;
/// lists, settings and history do.
///
/// A mesh gradient takes concrete colors, and the host's tint is a style, so
/// the tint glows through a mask: the neutral mesh underneath, then the tint
/// filled through a moving alpha mesh on top.
public struct TraxBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var dark: Bool { colorScheme == .dark }
    private var edge: Color { dark ? .black : Color(white: 0.97) }
    private var rim: Color { dark ? Color(white: 0.06) : Color(white: 0.93) }
    private var base: Color { dark ? .black : .white }

    public var body: some View {
        let strong = dark ? 0.34 : 0.24
        let soft = dark ? 0.18 : 0.12
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : Float(ctx.date.timeIntervalSinceReferenceDate) * 0.6
            let points: [SIMD2<Float>] = [
                [0, 0], [0.5 + 0.10 * sin(t * 0.21), 0], [1, 0],
                [0, 0.42 + 0.10 * sin(t * 0.33)],
                [0.5 + 0.16 * sin(t * 0.19), 0.5 + 0.12 * cos(t * 0.27)],
                [1, 0.58 + 0.10 * cos(t * 0.29)],
                [0, 1], [0.5 + 0.10 * cos(t * 0.23), 1], [1, 1],
            ]
            ZStack {
                MeshGradient(width: 3, height: 3, points: points,
                             colors: [edge, rim, edge, rim, rim, rim, edge, rim, edge])
                // The tint, strongest at the sides' middles and softer at the
                // center, as the sibling kits' own colors are.
                Rectangle().fill(.tint)
                    .mask {
                        MeshGradient(width: 3, height: 3, points: points, colors: [
                            .clear, .black.opacity(0.15), .clear,
                            .black.opacity(strong), .black.opacity(soft), .black.opacity(strong),
                            .clear, .black.opacity(0.12), .clear,
                        ])
                    }
            }
        }
        // The tinted layer is translucent: an opaque base keeps the host from
        // bleeding through.
        .background(base)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Colours the kit sets itself rather than taking from the host's tint, so
/// text over glass holds 4.5:1 whatever the host picks (the tint is for fills
/// and icons, never for text: ContrastTests).
enum TraxPalette {
    typealias RGB = (r: Double, g: Double, b: Double)
    /// Destructive text and labels. Light #D70015 (5.4:1 on white; system red
    /// #FF3B30 is 3.6 and misses AA), dark #FF453A (5.0:1 on #1C1C1E).
    static let destructiveLight: RGB = (215, 0, 21)
    static let destructiveDark: RGB = (255, 69, 58)
    static let destructive = Color(light: destructiveLight, dark: destructiveDark)
}

extension Color {
    /// A colour that follows the light/dark scheme.
    init(light: TraxPalette.RGB, dark: TraxPalette.RGB) {
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
        })
    }
}

extension View {
    /// A secondary action on glass: a glass capsule with the label in the
    /// text colour, never the host's tint (tinted text misses AA on glass).
    func traxSecondaryAction() -> some View {
        buttonStyle(.glass).foregroundStyle(Color.primary)
    }

    /// A destructive action on glass: explicit red, which a host's tint
    /// can't override (the role alone shows the tint on a styled button).
    func traxDestructiveAction() -> some View {
        buttonStyle(.glass).foregroundStyle(TraxPalette.destructive)
    }

    /// The kit's backdrop behind a list or form (its own background hidden).
    func traxBackdrop() -> some View {
        scrollContentBackground(.hidden)
            .background { TraxBackdrop() }
    }

    /// A Liquid Glass surface for content over the map or the backdrop.
    func traxGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}

/// A list row's action label, as a host's own settings rows draw one: the
/// icon in the tint (or red, destructive), the words in the text colour
/// (tinted words miss AA on a dark grouped cell with a mid-blue tint).
struct TraxRowLabel: View {
    let title: String
    let systemImage: String
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Label {
            Text(title).foregroundStyle(style(text: true))
        } icon: {
            Image(systemName: systemImage).foregroundStyle(style(text: false))
        }
    }

    /// Explicit colours don't dim on their own: a disabled row goes grey.
    private func style(text: Bool) -> AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Color.secondary) }
        if destructive { return AnyShapeStyle(TraxPalette.destructive) }
        return text ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tint)
    }
}
