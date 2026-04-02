import Foundation

public struct EngineDescriptor: Sendable {
    public let displayName: String
    public let description: String
    public let requiresModelDownload: Bool
    public let approximateSizeMB: Int
    public let minimumMacOS: String

    public var isAvailableOnThisOS: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return minimumMacOS != "26.0"
    }
}

public enum EngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "speech_analyzer"
    case fluidAudio = "fluid_audio"
    case whisperCpp = "whisper_cpp"

    public var id: String { rawValue }

    public static let `default`: EngineID = .speechAnalyzer

    /// The default engine, falling back if the preferred default is unavailable on this OS.
    public static var resolvedDefault: EngineID {
        if EngineID.default.descriptor.isAvailableOnThisOS {
            return .default
        }
        return .fluidAudio
    }

    /// All engines available on the current OS version.
    public static var availableEngines: [EngineID] {
        allCases.filter { $0.descriptor.isAvailableOnThisOS }
    }

    public var descriptor: EngineDescriptor {
        switch self {
        case .speechAnalyzer:
            EngineDescriptor(
                displayName: "Apple Speech (recommended)",
                description: "Apple's built-in speech recognition. No download required.",
                requiresModelDownload: false,
                approximateSizeMB: 0,
                minimumMacOS: "26.0"
            )
        case .fluidAudio:
            EngineDescriptor(
                displayName: "FluidAudio",
                description: "Fast Parakeet model via CoreML. Downloads ~500MB on first use.",
                requiresModelDownload: true,
                approximateSizeMB: 500,
                minimumMacOS: "15.0"
            )
        case .whisperCpp:
            EngineDescriptor(
                displayName: "Whisper (whisper.cpp)",
                description: "OpenAI Whisper large-v3-turbo via whisper.cpp. Downloads ~1.6GB GGML model.",
                requiresModelDownload: true,
                approximateSizeMB: 1600,
                minimumMacOS: "15.0"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = EngineID(rawValue: raw) ?? .default
    }
}
