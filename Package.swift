// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "AudioTranscribe", targets: ["TranscriberApp"]),
        .executable(name: "audio-capture-helper-xpc", targets: ["AudioCaptureHelperXPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/SettingsAccess", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AudioCaptureProtocol",
            path: "AudioCaptureProtocol"
        ),
        .target(
            name: "TranscriberCore",
            path: "TranscriberCore"
        ),
        .executableTarget(
            name: "TranscriberApp",
            dependencies: ["AudioCaptureProtocol", "SettingsAccess", "TranscriberCore"],
            path: "TranscriberApp"
        ),
        .executableTarget(
            name: "AudioCaptureHelperXPC",
            dependencies: ["AudioCaptureProtocol"],
            path: "AudioCaptureHelper/XPC"
        ),
        .testTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberCore"],
            path: "SwiftTests/TranscriberTests"
        ),
    ]
)
