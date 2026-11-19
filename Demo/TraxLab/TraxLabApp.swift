import SwiftUI
import TraxKit

/// TraxLab — the harness app for TraxKit. Logs into mvServer (real JWT via
/// MvAuth), then hosts the kit the way a production host does: engine built with
/// an injected token provider, running app-wide while signed in, wiped on
/// sign-out. All Trax UI development happens here, against the local stack.
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
    /// The Lab's tint (Pantone 2955 C, "TARDIS Blue"), adaptive: #003B6F light,
    /// #3380CC dark. Hosts inject their own tint; this one stands in for it.
    static let tardisBlue = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0x80 / 255, blue: 0xCC / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x3B / 255, blue: 0x6F / 255, alpha: 1)
    })
}
