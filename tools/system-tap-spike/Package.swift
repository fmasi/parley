// swift-tools-version: 5.9
import PackageDescription

// Standalone, throwaway spike for issue #103 phase 1 (read-only device validation).
// Deliberately NOT wired into the main Transcriber package: no FluidAudio, no TranscriberCore.
// Goal: confirm a Core Audio global output tap captures Continuity/telephony audio that
// ScreenCaptureKit misses, before committing to the SystemTapSession migration.
let package = Package(
    name: "system-tap-spike",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "system-tap-spike",
            path: "Sources/system-tap-spike"
        ),
    ]
)
