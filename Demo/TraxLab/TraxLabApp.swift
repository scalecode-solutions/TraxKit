import SwiftUI
import TraxKit

/// TraxLab — a harness app for exercising TraxKit against real iOS coupling
/// (Liquid Glass, SwiftData, the simulator). Loads the local package and renders
/// the feed with curated offline sample data so the whole card design can be
/// tuned without the backend running.
@main
struct TraxLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.tardisBlue)
        }
    }
}

extension Color {
    /// Clingy's `AppColors.primary` (Pantone 2955 C, "TARDIS Blue") — adaptive:
    /// #003B6F light / #3380CC dark. Matching it makes the lab pixel-faithful to
    /// the in-app look (avatar tint, own-pulse stroke, reaction accent).
    static let tardisBlue = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0x80 / 255, blue: 0xCC / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x3B / 255, blue: 0x6F / 255, alpha: 1)
    })
}
