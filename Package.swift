// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Parley", targets: ["TranscriberApp"]),
        .executable(name: "audio-capture-helper-xpc", targets: ["AudioCaptureHelperXPC"]),
        .executable(name: "verify-ed-signature", targets: ["VerifyEdSignature"]),
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
        .target(
            name: "VerifyEdSignatureCore",
            path: "Sources/VerifyEdSignatureCore"
        ),
        .executableTarget(
            name: "VerifyEdSignature",
            dependencies: ["VerifyEdSignatureCore"],
            path: "Sources/VerifyEdSignature"
        ),
        // Test support, linked only into the test bundle: it exits the test process before any
        // test runs unless the process runs in a throwaway home (#313; see TestHomeGuard.c).
        .target(
            name: "TestHomeGuard",
            path: "SwiftTests/TestHomeGuard"
        ),
        .testTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberCore", "VerifyEdSignatureCore", "TestHomeGuard"],
            path: "SwiftTests/TranscriberTests",
            // The golden-config snapshot is read via #filePath (and rewritten by UPDATE_GOLDEN=1),
            // not through Bundle.module — excluded so SwiftPM doesn't warn about it.
            exclude: ["fixtures"]
        ),
    ]
)
