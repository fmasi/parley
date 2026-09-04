import Foundation
import os

public enum SummaryProviderType: String, Codable, Equatable, Sendable {
    case openai
    case lmstudio
}

/// Which mechanism captures system (remote) audio. `screenCaptureKit` is the shipped default;
/// `coreAudioTap` selects the Core Audio output process tap (#103) — a strict superset that also
/// captures Continuity/telephony + VoIP that SCK misses. Behind a flag during phase 2 rollout.
public enum SystemAudioSource: String, Codable, Equatable, Sendable {
    case screenCaptureKit = "sck"
    case coreAudioTap = "core_audio_tap"
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
    /// Seconds to wait for the model to produce a summary (default 600).
    ///
    /// URLSession's stock 60s is the wrong order of magnitude for a LOCAL model summarising a long
    /// meeting: it accepts the request immediately, then generates for minutes. Two real recordings
    /// failed at exactly 60s (#173) — the transcript was fine both times, only the summary was lost.
    public var requestTimeoutSeconds: Int?

    public init(
        enabled: Bool,
        provider: SummaryProviderType = .openai,
        endpoint: String,
        apiKey: String,
        model: String,
        contextLength: Int? = nil,
        contextOverheadPercent: Int? = nil,
        maxOutputTokens: Int? = nil,
        requestTimeoutSeconds: Int? = nil
    ) {
        self.enabled = enabled
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.contextOverheadPercent = contextOverheadPercent
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeoutSeconds = requestTimeoutSeconds
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
        case requestTimeoutSeconds = "request_timeout_seconds"
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
        // Hand-written decoder: adding a property to CodingKeys is NOT enough, it must be decoded
        // here too. Omitting this line meant `request_timeout_seconds` was accepted in config.json
        // and silently ignored — the knob added to fix #173 did nothing.
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds)
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var recordingDirectory: String
    public var silenceTimeoutMinutes: Int
    public var silenceDetectionEnabled: Bool
    public var outputFormat: String
    public var launchOnStartup: Bool
    public var suppressCaptureWarning: Bool
    public var lastMicrophoneDeviceId: String?
    public var engine: EngineID
    public var systemAudioSource: SystemAudioSource
    public var vadSpeechThreshold: Double?
    /// Diarization clustering distance threshold (Euclidean, unit-normalized embeddings).
    /// LOWER = stricter = keeps speakers apart; HIGHER = merges them. nil = FluidAudio default (0.6).
    public var diarizationClusteringThreshold: Double?
    /// Upper bound on diarized speakers per stream. nil = unbounded.
    public var diarizationMaxSpeakers: Int?
    /// Share of a stream's speech below which a diarization cluster is absorbed into the dominant
    /// speaker (#65). nil = `DiarizationCleanup.defaultMinShare`; `0` disables absorption.
    public var diarizationMinSpeakerShare: Double?

    /// The value handed to `DiarizationCleanup`. `0` in config means "off", which must become `nil`
    /// here rather than a literal 0 — a 0 threshold would absorb nothing while still claiming to be
    /// enabled, and the difference matters when reading a log.
    public var resolvedDiarizationMinSpeakerShare: Double? {
        guard let share = diarizationMinSpeakerShare else { return DiarizationCleanup.defaultMinShare }
        guard share > 0 else { return nil }
        // Past `maxSensibleShare` the knob stops describing fragments and starts deleting people:
        // absorption only runs when some cluster holds >= 50%, so a share of 0.45 would swallow a
        // speaker holding 40% of the conversation. Clamp rather than obey.
        //
        // Deliberately SILENT here: this is read once per stream per chunk, so warning from a
        // computed property would print the same line eight times on a two-hour meeting.
        // `ConfigManager.load` warns once, when the file is read.
        guard share <= DiarizationCleanup.maxSensibleShare else {
            return DiarizationCleanup.defaultMinShare
        }
        return share
    }
    /// Exclude overlapped speech when computing speaker embeddings. **Defaults to TRUE** (nil resolves
    /// to true at every consumer). Do not set this to false.
    ///
    /// Including overlap makes every embedding a blend of whoever was talking, so they all converge
    /// and the clusterer sees ONE speaker. Measured on AMI ES2004a, a 4-speaker reference meeting:
    ///     false -> 1 speaker  (639 of 642 embeddings in a single cluster)
    ///     true  -> 4 speakers (correct)
    /// The old code forced false on the theory that a mixed mono stream is "all overlap"; that is
    /// wrong (the mask marks frames where two SPEAKERS overlap) and it silently destroyed speaker
    /// identity on every multi-party recording for months.
    public var diarizationExcludeOverlap: Bool?
    /// The value actually handed to the diarizer. Lives here, not as a `??` at the call site, so a
    /// regression to `false` FAILS A TEST instead of shipping green: the call site is in the app
    /// target, which the unit suite cannot reach, and the ground-truth AMI guard runs in a separate
    /// CI job. `false` collapses every speaker into one cluster (AMI ES2004a: 1 speaker, not 4).
    public var resolvedDiarizationExcludeOverlap: Bool { diarizationExcludeOverlap ?? true }

    /// Keep the uncompressed source WAVs after AAC archiving. Diagnostic: archives are lossy and
    /// speaker embeddings are far more sensitive to that than speech intelligibility is.
    public var preserveSourceWAV: Bool?
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
        systemAudioSource: .screenCaptureKit,
        vadSpeechThreshold: nil,
        diarizationClusteringThreshold: nil,
        diarizationMaxSpeakers: nil,
        diarizationMinSpeakerShare: nil,
        diarizationExcludeOverlap: nil,
        preserveSourceWAV: nil,
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
        systemAudioSource: SystemAudioSource = .screenCaptureKit,
        vadSpeechThreshold: Double? = nil,
        diarizationClusteringThreshold: Double? = nil,
        diarizationMaxSpeakers: Int? = nil,
        diarizationMinSpeakerShare: Double? = nil,
        diarizationExcludeOverlap: Bool? = nil,
        preserveSourceWAV: Bool? = nil,
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
        self.systemAudioSource = systemAudioSource
        self.vadSpeechThreshold = vadSpeechThreshold
        self.diarizationClusteringThreshold = diarizationClusteringThreshold
        self.diarizationMaxSpeakers = diarizationMaxSpeakers
        self.diarizationMinSpeakerShare = diarizationMinSpeakerShare
        self.diarizationExcludeOverlap = diarizationExcludeOverlap
        self.preserveSourceWAV = preserveSourceWAV
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
        case systemAudioSource = "system_audio_source"
        case vadSpeechThreshold = "vad_speech_threshold"
        case diarizationClusteringThreshold = "diarization_clustering_threshold"
        case diarizationMaxSpeakers = "diarization_max_speakers"
        case diarizationMinSpeakerShare = "diarization_min_speaker_share"
        case diarizationExcludeOverlap = "diarization_exclude_overlap"
        case preserveSourceWAV = "preserve_source_wav"
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
        systemAudioSource = try c.decodeIfPresent(SystemAudioSource.self, forKey: .systemAudioSource) ?? .screenCaptureKit
        vadSpeechThreshold = try c.decodeIfPresent(Double.self, forKey: .vadSpeechThreshold)
        diarizationClusteringThreshold = try c.decodeIfPresent(Double.self, forKey: .diarizationClusteringThreshold)
        diarizationMaxSpeakers = try c.decodeIfPresent(Int.self, forKey: .diarizationMaxSpeakers)
        diarizationMinSpeakerShare = try c.decodeIfPresent(Double.self, forKey: .diarizationMinSpeakerShare)
        diarizationExcludeOverlap = try c.decodeIfPresent(Bool.self, forKey: .diarizationExcludeOverlap)
        preserveSourceWAV = try c.decodeIfPresent(Bool.self, forKey: .preserveSourceWAV)
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
        summary = try c.decodeIfPresent(SummaryConfig.self, forKey: .summary)
    }
}
