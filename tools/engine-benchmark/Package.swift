// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EngineBenchmark",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/Justmalhar/WhisperCppKit.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "EngineBenchmark",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperCppKit", package: "WhisperCppKit"),
            ],
            path: "Sources/EngineBenchmark"
        ),
        .executableTarget(
            name: "SpeechTest",
            dependencies: [],
            path: "Sources/SpeechTest"
        ),
    ]
)
