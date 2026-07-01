// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Parley", targets: ["TranscriberApp"]),
        .executable(name: "audio-capture-helper-xpc", targets: ["AudioCaptureHelperXPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/SettingsAccess", from: "2.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
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
            dependencies: [
                "AudioCaptureProtocol", "SettingsAccess", "TranscriberCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
