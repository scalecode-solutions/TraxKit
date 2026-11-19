import Foundation
import Testing
@testable import TraxKit

/// The kit's accent is whatever tint the host passes, so contrast can't be
/// checked against one palette. What the kit controls is what it draws on the
/// tint; these pin those choices against a range of plausible host tints, in
/// both schemes (WCAG 2 relative luminance).
@Suite("Contrast")
struct ContrastTests {
    typealias RGB = (Double, Double, Double)

    /// Host tints: a deep brand blue (light #003B6F and dark
    /// #3380CC), iOS system blue (both schemes), and bright tints a host might
    /// pick: yellow, pink, green.
    static let tints: [(name: String, light: RGB, dark: RGB)] = [
        ("brand", (0, 59, 111), (51, 128, 204)),
        ("system blue", (0, 122, 255), (10, 132, 255)),
        ("yellow", (255, 204, 0), (255, 214, 10)),
        ("pink", (255, 45, 85), (255, 55, 95)),
        ("green", (52, 199, 89), (48, 209, 88)),
    ]
    /// The surfaces avatars sit on: a light panel and a dark one (system
    /// background / secondary background).
    static let lightSurface: RGB = (255, 255, 255)
    static let darkSurface: RGB = (28, 28, 30)

    static func linear(_ v: Double) -> Double {
        let s = v / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    static func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// `top` at `alpha` over `bottom`.
    static func mix(_ top: RGB, _ alpha: Double, over bottom: RGB) -> RGB {
        (top.0 * alpha + bottom.0 * (1 - alpha), top.1 * alpha + bottom.1 * (1 - alpha), top.2 * alpha + bottom.2 * (1 - alpha))
    }

    /// Initials (.primary: black in light, white in dark) on the tint wash
    /// clear AA for normal text with every tint, both schemes.
    @Test(arguments: tints.map(\.name))
    func initialsReadOnTheWash(tint name: String) {
        let t = Self.tints.first { $0.name == name }!
        let lightWash = Self.mix(t.light, TraxAvatar.washOpacity, over: Self.lightSurface)
        let darkWash = Self.mix(t.dark, TraxAvatar.washOpacity, over: Self.darkSurface)
        let light = Self.contrast((0, 0, 0), lightWash), dark = Self.contrast((255, 255, 255), darkWash)
        #expect(light >= 4.5, "\(name) light: \(light)")
        #expect(dark >= 4.5, "\(name) dark: \(dark)")
    }

    /// Why not white on a solid tint (CalendarKit's choice, which works there
    /// because CalendarKit knows its colours and picks black for bright ones):
    /// with the host's own dark-mode brand it misses AA for text.
    @Test func whiteOnSolidBrandMissesAAInDark() {
        let brandDark = Self.tints[0].dark
        #expect(Self.contrast((255, 255, 255), brandDark) < 4.5)
    }

    /// The luminance matches WCAG's reference points.
    @Test func luminanceEnds() {
        #expect(Self.luminance((255, 255, 255)) == 1)
        #expect(Self.luminance((0, 0, 0)) == 0)
        #expect(abs(Self.contrast((255, 255, 255), (0, 0, 0)) - 21) < 0.001)
    }
}
