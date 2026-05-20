import Foundation

public enum SummaryProviderType: String, Codable, Equatable, Sendable {
    case openai
    case lmstudio
}

public struct SummaryConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: SummaryProviderType
    public var endpoint: String
    public var apiKey: String
    public var model: String
    public var contextLength: Int?
    /// Safety margin on estimated input tokens (default 10 = 10%).
    /// Applied before adding maxOutputTokens to get the final context_length.
    public var contextOverheadPercent: Int?
    /// Tokens reserved for the summary response (default 2048).
    public var maxOutputTokens: Int?

    public init(
        enabled: Bool,
        provider: SummaryProviderType = .openai,
        endpoint: String,
        apiKey: String,
        model: String,
        contextLength: Int? = nil,
        contextOverheadPercent: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.enabled = enabled
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.contextOverheadPercent = contextOverheadPercent
        self.maxOutputTokens = maxOutputTokens
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case provider
        case endpoint
        case apiKey = "api_key"
        case model
        case contextLength = "context_length"
        case contextOverheadPercent = "context_overhead_percent"
        case maxOutputTokens = "max_output_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        provider = try c.decodeIfPresent(SummaryProviderType.self, forKey: .provider) ?? .openai
        endpoint = try c.decode(String.self, forKey: .endpoint)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        contextOverheadPercent = try c.decodeIfPresent(Int.self, forKey: .contextOverheadPercent)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
    }
}

public struct Config: Codable, Equatable {
    public var recordingDirectory: String
    public var silenceTimeoutMinutes: Int
    public var silenceDetectionEnabled: Bool
    public var outputFormat: String
    public var launchOnStartup: Bool
    public var suppressCaptureWarning: Bool
    public var lastMicrophoneDeviceId: String?
    public var engine: EngineID
    public var vadSpeechThreshold: Double?
    /// Minimum diarized-turn duration (seconds) for the smoothing pass; turns
    /// shorter than this are collapsed into their dominant neighbor before
    /// speaker labels are assigned. When nil, defaults to 0.5s at the call site.
    public var minSpeakerTurnDuration: Double?
    public var echoTemporalThreshold: Double?
    public var echoTextThreshold: Double?
    public var echoEmbeddingThreshold: Double?
    public var archiveBitrateKbps: Int
    public var audioArchiveLimitHours: Int
    public var chunkDurationMinutes: Int
    public var chunkProcessingQos: String
    public var mergeChunkedAudio: Bool
    public var modelUpdateCheckEnabled: Bool
    /// Minutes ahead of `now` to consider scheduled meetings as "imminent" for calendar
    /// auto-naming. 10 minutes covers the common "I clicked record before the meeting
    /// actually started" case without dragging unrelated future meetings into the name.
    /// Set to 0 to disable lookahead entirely (current-meeting-only behavior).
    public var calendarLookaheadMinutes: Int
    /// FluidAudio clustering distance threshold. Higher = more merging = fewer speakers.
    /// Valid range (0, sqrt(2)]; SDK default is 0.6. nil = use SDK default.
    public var diarizationClusteringThreshold: Double?
    /// Lower bound on detected speaker count (ignored if `diarizationExactSpeakers` set). nil = unconstrained.
    public var diarizationMinSpeakers: Int?
    /// Upper bound on detected speaker count (ignored if `diarizationExactSpeakers` set). nil = unconstrained.
    public var diarizationMaxSpeakers: Int?
    /// Exact speaker count; overrides min/max when set. nil = unconstrained.
    public var diarizationExactSpeakers: Int?
    public var summary: SummaryConfig?

    /// Returns `chunkDurationMinutes` clamped to a minimum of 10.
    public var validatedChunkDuration: Int {
        max(chunkDurationMinutes, 10)
    }

    /// Maps `chunkProcessingQos` string to a `DispatchQoS.QoSClass`.
    /// Falls back to `.utility` for unrecognised values.
    public var resolvedQos: DispatchQoS.QoSClass {
        switch chunkProcessingQos {
        case "userInteractive": return .userInteractive
        case "userInitiated":   return .userInitiated
        case "utility":         return .utility
        case "background":      return .background
        default:                return .utility
        }
    }

    public static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        suppressCaptureWarning: false,
        lastMicrophoneDeviceId: nil,
        engine: .resolvedDefault,
        vadSpeechThreshold: nil,
        minSpeakerTurnDuration: nil,
        echoTemporalThreshold: nil,
        echoTextThreshold: nil,
        echoEmbeddingThreshold: nil,
        archiveBitrateKbps: 64,
        audioArchiveLimitHours: 15,
        chunkDurationMinutes: 30,
        chunkProcessingQos: "utility",
        mergeChunkedAudio: true,
        modelUpdateCheckEnabled: false,
        calendarLookaheadMinutes: 10,
        diarizationClusteringThreshold: nil,
        diarizationMinSpeakers: nil,
        diarizationMaxSpeakers: nil,
        diarizationExactSpeakers: nil,
        summary: nil
    )

    public init(
        recordingDirectory: String = NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: Int = 5,
        silenceDetectionEnabled: Bool = true,
        outputFormat: String = "txt",
        launchOnStartup: Bool = true,
        suppressCaptureWarning: Bool = false,
        lastMicrophoneDeviceId: String? = nil,
        engine: EngineID = .resolvedDefault,
        vadSpeechThreshold: Double? = nil,
        minSpeakerTurnDuration: Double? = nil,
        echoTemporalThreshold: Double? = nil,
        echoTextThreshold: Double? = nil,
        echoEmbeddingThreshold: Double? = nil,
        archiveBitrateKbps: Int = 64,
        audioArchiveLimitHours: Int = 15,
        chunkDurationMinutes: Int = 30,
        chunkProcessingQos: String = "utility",
        mergeChunkedAudio: Bool = true,
        modelUpdateCheckEnabled: Bool = false,
        calendarLookaheadMinutes: Int = 10,
        diarizationClusteringThreshold: Double? = nil,
        diarizationMinSpeakers: Int? = nil,
        diarizationMaxSpeakers: Int? = nil,
        diarizationExactSpeakers: Int? = nil,
        summary: SummaryConfig? = nil
    ) {
        self.recordingDirectory = recordingDirectory
        self.silenceTimeoutMinutes = silenceTimeoutMinutes
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.outputFormat = outputFormat
        self.launchOnStartup = launchOnStartup
        self.suppressCaptureWarning = suppressCaptureWarning
        self.lastMicrophoneDeviceId = lastMicrophoneDeviceId
        self.engine = engine
        self.vadSpeechThreshold = vadSpeechThreshold
        self.minSpeakerTurnDuration = minSpeakerTurnDuration
        self.echoTemporalThreshold = echoTemporalThreshold
        self.echoTextThreshold = echoTextThreshold
        self.echoEmbeddingThreshold = echoEmbeddingThreshold
        self.archiveBitrateKbps = archiveBitrateKbps
        self.audioArchiveLimitHours = audioArchiveLimitHours
        self.chunkDurationMinutes = chunkDurationMinutes
        self.chunkProcessingQos = chunkProcessingQos
        self.mergeChunkedAudio = mergeChunkedAudio
        self.modelUpdateCheckEnabled = modelUpdateCheckEnabled
        self.calendarLookaheadMinutes = calendarLookaheadMinutes
        self.diarizationClusteringThreshold = diarizationClusteringThreshold
        self.diarizationMinSpeakers = diarizationMinSpeakers
        self.diarizationMaxSpeakers = diarizationMaxSpeakers
        self.diarizationExactSpeakers = diarizationExactSpeakers
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case silenceTimeoutMinutes = "silence_timeout_minutes"
        case silenceDetectionEnabled = "silence_detection_enabled"
        case outputFormat = "output_format"
        case launchOnStartup = "launch_on_startup"
        case suppressCaptureWarning = "suppress_capture_warning"
        case lastMicrophoneDeviceId = "last_microphone_device_id"
        case engine
        case vadSpeechThreshold = "vad_speech_threshold"
        case minSpeakerTurnDuration = "min_speaker_turn_duration"
        case echoTemporalThreshold = "echo_temporal_threshold"
        case echoTextThreshold = "echo_text_threshold"
        case echoEmbeddingThreshold = "echo_embedding_threshold"
        case archiveBitrateKbps = "archive_bitrate_kbps"
        case audioArchiveLimitHours = "audio_archive_limit_hours"
        case chunkDurationMinutes = "chunk_duration_minutes"
        case chunkProcessingQos = "chunk_processing_qos"
        case mergeChunkedAudio = "merge_chunked_audio"
        case modelUpdateCheckEnabled = "model_update_check_enabled"
        case calendarLookaheadMinutes = "calendar_lookahead_minutes"
        case diarizationClusteringThreshold = "diarization_clustering_threshold"
        case diarizationMinSpeakers = "diarization_min_speakers"
        case diarizationMaxSpeakers = "diarization_max_speakers"
        case diarizationExactSpeakers = "diarization_exact_speakers"
        case summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingDirectory = try c.decode(String.self, forKey: .recordingDirectory)
        silenceTimeoutMinutes = try c.decode(Int.self, forKey: .silenceTimeoutMinutes)
        silenceDetectionEnabled = try c.decode(Bool.self, forKey: .silenceDetectionEnabled)
        outputFormat = try c.decode(String.self, forKey: .outputFormat)
        launchOnStartup = try c.decode(Bool.self, forKey: .launchOnStartup)
        suppressCaptureWarning = try c.decode(Bool.self, forKey: .suppressCaptureWarning)
        lastMicrophoneDeviceId = try c.decodeIfPresent(String.self, forKey: .lastMicrophoneDeviceId)
        engine = try c.decodeIfPresent(EngineID.self, forKey: .engine) ?? .resolvedDefault
        vadSpeechThreshold = try c.decodeIfPresent(Double.self, forKey: .vadSpeechThreshold)
        minSpeakerTurnDuration = try c.decodeIfPresent(Double.self, forKey: .minSpeakerTurnDuration)
        echoTemporalThreshold = try c.decodeIfPresent(Double.self, forKey: .echoTemporalThreshold)
        echoTextThreshold = try c.decodeIfPresent(Double.self, forKey: .echoTextThreshold)
        echoEmbeddingThreshold = try c.decodeIfPresent(Double.self, forKey: .echoEmbeddingThreshold)
        archiveBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .archiveBitrateKbps) ?? 64
        audioArchiveLimitHours = try c.decodeIfPresent(Int.self, forKey: .audioArchiveLimitHours) ?? 15
        chunkDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .chunkDurationMinutes) ?? 30
        chunkProcessingQos = try c.decodeIfPresent(String.self, forKey: .chunkProcessingQos) ?? "utility"
        mergeChunkedAudio = try c.decodeIfPresent(Bool.self, forKey: .mergeChunkedAudio) ?? true
        modelUpdateCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .modelUpdateCheckEnabled) ?? false
        calendarLookaheadMinutes = try c.decodeIfPresent(Int.self, forKey: .calendarLookaheadMinutes) ?? 10
        diarizationClusteringThreshold = try c.decodeIfPresent(Double.self, forKey: .diarizationClusteringThreshold)
        diarizationMinSpeakers = try c.decodeIfPresent(Int.self, forKey: .diarizationMinSpeakers)
        diarizationMaxSpeakers = try c.decodeIfPresent(Int.self, forKey: .diarizationMaxSpeakers)
        diarizationExactSpeakers = try c.decodeIfPresent(Int.self, forKey: .diarizationExactSpeakers)
        summary = try c.decodeIfPresent(SummaryConfig.self, forKey: .summary)
    }
}

public extension Config {
    /// Maps the global diarization tuning fields onto a `DiarizationTuning` value
    /// for `FluidAudioDiarizer`. All-nil fields produce an all-nil tuning, which
    /// the diarizer treats as "use SDK defaults" (no behavior change). (#66)
    var diarizationTuning: DiarizationTuning {
        DiarizationTuning(
            clusteringThreshold: diarizationClusteringThreshold,
            minSpeakers: diarizationMinSpeakers,
            maxSpeakers: diarizationMaxSpeakers,
            exactSpeakers: diarizationExactSpeakers
        )
    }
}
