// swift-tools-version: 6.2
import PackageDescription

// TraxKit — the location-sharing client as a self-contained SPM: wire DTOs, REST
// transport, SwiftData persistence, pull-sync, and the embedded map/share UI.
// Talks to mvTrax (trax.mvchat.app). A host (TraxLab/Clingy) adds a thin wrapper.
//
// Friend-gated, directed sharing over HTTP — the family-locator model delivered
// as clean infrastructure (see mvTrax/docs/DESIGN.md). Mirrors PulseKit's shape.
//
// Swift 6 strict concurrency from line one — NOT v5-with-a-TODO. If something
// won't compile under complete checking, we fix the design, not the flag.
let package = Package(
    name: "TraxKit",
    platforms: [.iOS(.v26)], // iOS-only — the consumer is the iOS app (TraxLab/Clingy)
    products: [
        .library(name: "TraxKit", targets: ["TraxKit"]),
    ],
    targets: [
        .target(
            name: "TraxKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TraxKitTests",
            dependencies: ["TraxKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
