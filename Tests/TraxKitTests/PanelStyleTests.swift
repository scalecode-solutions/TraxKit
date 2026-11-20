import Foundation
import Testing
import SwiftUI
@testable import TraxKit

/// The panels-over-the-map choice: what's stored, what wins, and that every
/// layered level keeps the panel's text readable over a map. Clear glass
/// can't promise that (it takes on the map's colour), which is why the
/// levels exist.
@Suite struct PanelStyleTests {
    @Test func theStoredChoiceWinsOverTheHostDefault() {
        #expect(TraxPanelStyle.resolved(stored: nil, default: .smoked) == .smoked)
        #expect(TraxPanelStyle.resolved(stored: "strong", default: .smoked) == .strong)
        #expect(TraxPanelStyle.resolved(stored: "nonsense", default: .solid) == .solid)
        #expect(TraxPanelStyle.storageKey.hasPrefix("trax."))
        #expect(TraxAppearance.standard.panelStyle == .clear, "the kit's default is today's look")
    }

    @Test func onlyClearGlassTakesGlassButtons() {
        #expect(TraxPanelStyle.clear.buttonsAreGlass)
        for s in [TraxPanelStyle.smoked, .strong, .solid] { #expect(!s.buttonsAreGlass) }
    }

    typealias RGB = (Double, Double, Double)
    static func lum(_ c: RGB) -> Double {
        func l(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * l(c.0) + 0.7152 * l(c.1) + 0.0722 * l(c.2)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// `layer` at `alpha` over `map`, the panel's surface (the glass's own
    /// blur only pulls it further toward the layer).
    static func surface(_ map: RGB, layer white: Double, _ alpha: Double) -> RGB {
        let w = white * 255
        return (w * alpha + map.0 * (1 - alpha), w * alpha + map.1 * (1 - alpha), w * alpha + map.2 * (1 - alpha))
    }

    /// The worst map behind the panel in each scheme: Dark maps are dark,
    /// their brightest common area a mid grey (roads, labels, parks); Light
    /// maps are light, their darkest common area a deep water blue.
    static let darkSchemeWorstMap: RGB = (128, 128, 128)
    static let lightSchemeWorstMap: RGB = (40, 60, 110)

    @Test(arguments: [TraxPanelStyle.smoked, .strong, .solid])
    func layeredLevelsKeepTextReadable(_ style: TraxPanelStyle) {
        let d = style.layer(dark: true)!, l = style.layer(dark: false)!
        let darkSurface = Self.surface(Self.darkSchemeWorstMap, layer: d.white, d.opacity)
        let lightSurface = Self.surface(Self.lightSchemeWorstMap, layer: l.white, l.opacity)
        #expect(Self.contrast((255, 255, 255), darkSurface) >= 4.5, "\(style) Dark")
        #expect(Self.contrast((0, 0, 0), lightSurface) >= 4.5, "\(style) Light")
    }

    /// The brand whisper on Smoked and Strong can't undo it: even a saturated
    /// host tint at that opacity over each level's surface keeps AA.
    @Test(arguments: [TraxPanelStyle.smoked, .strong])
    func theBrandWhisperKeepsTextReadable(_ style: TraxPanelStyle) {
        let a = TraxPanelSurface<Rectangle>.brandWhisper
        let d = style.layer(dark: true)!, l = style.layer(dark: false)!
        for tint in [(51.0, 128.0, 204.0), (255.0, 204.0, 0.0), (255.0, 45.0, 85.0)] {
            let darkBase = Self.surface(Self.darkSchemeWorstMap, layer: d.white, d.opacity)
            let lightBase = Self.surface(Self.lightSchemeWorstMap, layer: l.white, l.opacity)
            let dark: RGB = (tint.0 * a + darkBase.0 * (1 - a), tint.1 * a + darkBase.1 * (1 - a), tint.2 * a + darkBase.2 * (1 - a))
            let light: RGB = (tint.0 * a + lightBase.0 * (1 - a), tint.1 * a + lightBase.1 * (1 - a), tint.2 * a + lightBase.2 * (1 - a))
            #expect(Self.contrast((255, 255, 255), dark) >= 4.5, "\(style) Dark, tint \(tint)")
            #expect(Self.contrast((0, 0, 0), light) >= 4.5, "\(style) Light, tint \(tint)")
        }
    }

    /// Why clear can't promise it: white text straight over a mid-grey map.
    @Test func clearGlassAloneDoesNot() {
        #expect(TraxPanelStyle.clear.layer(dark: true) == nil)
        #expect(Self.contrast((255, 255, 255), Self.darkSchemeWorstMap) < 4.5)
    }
}
