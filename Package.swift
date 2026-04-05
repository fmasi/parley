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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
    ],
    targets: [
        .target(
            name: "AudioCaptureProtocol",
            path: "AudioCaptureProtocol"
        ),
        .target(
            name: "TranscriberCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "TranscriberCore"
        ),
        .executableTarget(
            name: "TranscriberApp",
            dependencies: ["AudioCaptureProtocol", "SettingsAccess", "TranscriberCore"],
            path: "TranscriberApp"
        ),
        .executableTarget(
            name: "AudioCaptureHelperXPC",
            dependencies: ["AudioCaptureProtocol", "TranscriberCore"],
            path: "AudioCaptureHelper/XPC"
        ),
        .testTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberCore"],
            path: "SwiftTests/TranscriberTests"
        ),
    ]
)
