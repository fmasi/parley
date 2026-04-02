import Foundation

public struct EngineDescriptor: Sendable {
    public let displayName: String
    public let description: String
    public let requiresModelDownload: Bool
    public let approximateSizeMB: Int
    public let minimumMacOS: String

    public var isAvailableOnThisOS: Bool {
        let parts = minimumMacOS.split(separator: ".")
        guard let requiredMajor = parts.first.flatMap({ Int($0) }) else { return true }
        let requiredMinor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let current = ProcessInfo.processInfo.operatingSystemVersion
        if current.majorVersion != requiredMajor {
            return current.majorVersion > requiredMajor
        }
        return current.minorVersion >= requiredMinor
    }
}

public enum EngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "speech_analyzer"
    case fluidAudio = "fluid_audio"

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
                description: "Apple's on-device model. No download. Best for multilingual (JA, KO). Requires macOS 26.",
                requiresModelDownload: false,
                approximateSizeMB: 0,
                minimumMacOS: "26.0"
            )
        case .fluidAudio:
            EngineDescriptor(
                displayName: "FluidAudio (dev)",
                description: "Fastest engine, best accuracy for European languages. Downloads ~500MB on first use. macOS 15+.",
                requiresModelDownload: true,
                approximateSizeMB: 500,
                minimumMacOS: "15.0"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = EngineID(rawValue: raw) ?? .resolvedDefault
    }
}
