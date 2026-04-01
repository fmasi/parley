// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EngineBenchmark",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "EngineBenchmark",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ],
            path: "Sources"
        ),
    ]
)
