// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The custom-vocabulary benchmark (#340, docs/benchmarks/2026-11-24-custom-vocabulary.md).
// FLUIDAUDIO_VERSION picks the FluidAudio release to measure, so the same corpus can be run
// against the version Parley ships and the one it is about to move to.
let fluidAudioVersion = ProcessInfo.processInfo.environment["FLUIDAUDIO_VERSION"] ?? "0.17.7"

let package = Package(
    name: "VocabBenchmark",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: Version(stringLiteral: fluidAudioVersion)),
    ],
    targets: [
        .executableTarget(
            name: "VocabBenchmark",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/VocabBenchmark"
        ),
    ]
)
