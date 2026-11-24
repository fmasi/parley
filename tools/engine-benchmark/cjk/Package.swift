// swift-tools-version: 6.2
// CJK + automatic-language benchmark (#339). Separate package so the main EngineBenchmark keeps its
// pinned FluidAudio; this one pins the FluidAudio Parley ships (0.17.7), which carries the CJK models.
import PackageDescription

let package = Package(
    name: "CJKBench",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "CJKBench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/CJKBench"
        )
    ]
)
