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

extension View {
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
