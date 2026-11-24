// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EngineBenchmark",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),
        // Same version as the app (Package.swift at the repo root), so the benchmark measures what ships.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "EngineBenchmark",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/EngineBenchmark"
        ),
        // ASR model comparison (#350, #338): v3 .int8 vs v3 .int8V2 vs Parakeet Ultra, one config per process
        // so `/usr/bin/time -l` gives each its own peak memory footprint. See run-asr-model-bench.sh.
        .executableTarget(
            name: "AsrModelBench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/AsrModelBench"
        ),
        .executableTarget(
            name: "SpeechTest",
            dependencies: [],
            path: "Sources/SpeechTest"
        ),
    ]
)
