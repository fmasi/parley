// swift-tools-version: 5.9
import PackageDescription

// LocalVQE's echo canceller and the ggml it pins, vendored by scripts/vendor-localvqe.sh (#342): CPU
// backend only, with Accelerate. The defines are the ones upstream's CMake passes on Apple arm64, minus
// Metal and BLAS. LOCALVQE_STATIC_BACKENDS stops the engine scanning directories for backend dylibs.
let localVQEDefines: [(String, String?)] = [
    ("GGML_USE_CPU", nil), ("GGML_USE_ACCELERATE", nil), ("ACCELERATE_NEW_LAPACK", nil),
    ("ACCELERATE_LAPACK_ILP64", nil), ("GGML_USE_CPU_REPACK", nil), ("GGML_SCHED_MAX_COPIES", "4"),
    ("GGML_VERSION", "\"0.9.8\""), ("GGML_COMMIT", "\"c044a8e\""), ("_DARWIN_C_SOURCE", nil),
    ("_XOPEN_SOURCE", "600"), ("NDEBUG", nil), ("LOCALVQE_BUILD", nil), ("LOCALVQE_STATIC_BACKENDS", nil),
]
let localVQEHeaderPaths = ["ggml/include", "ggml/src", "ggml/src/ggml-cpu", "localvqe"]

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
            name: "CLocalVQE",
            path: "ThirdParty/CLocalVQE",
            exclude: ["LICENSE-LocalVQE", "LICENSE-ggml", "VERSION"],
            // -w: upstream's code, warnings and all; it is reviewed as vendored, not rewritten.
            cSettings: localVQEDefines.map { .define($0.0, to: $0.1) }
                + localVQEHeaderPaths.map { .headerSearchPath($0) } + [.unsafeFlags(["-w"])],
            cxxSettings: localVQEDefines.map { .define($0.0, to: $0.1) }
                + localVQEHeaderPaths.map { .headerSearchPath($0) } + [.unsafeFlags(["-w"])],
            linkerSettings: [.linkedFramework("Accelerate")]
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
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx17
)
