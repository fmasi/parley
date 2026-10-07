import Foundation
import os

// MARK: - Event model

/// The kind of a capture event. Anomaly kinds (stream errors, format changes, XPC
/// interruptions, retries, recovery) are what gate the on-disk diagnostic flush (#95).
public enum CaptureEventKind: String, Codable, Sendable {
    case captureStart
    case captureStop
    case systemFormatDetected
    case micFormatDetected
    case formatChanged
    case streamStopError
    case restartInPlace
    case restartFailed
    case micSwitch
    case xpcInterruption
    case xpcInvalidation
    case retry
    case launchRecovery
    /// launchd idle-exited the helper while nothing was being captured (L-N1). Recorded into the
    /// app ring while idle — the next `resetSession()` wipes it, so it lives in the unified log and
    /// the live log, never in a later session's `.diag.jsonl`. Severity `.info`.
    case helperIdleExit
    /// A track that was EXPECTED to deliver (mic: always; tap: another process running output)
    /// produced no heartbeat within the first-frame threshold after capture start, a rebuild or a
    /// wake — Incident B's exact shape (46 min, 0 callbacks). Severity `.anomaly`.
    case neverDelivered
    /// A reported `neverDelivered`/`livenessGap` episode ended: the heartbeat is back. `.info`.
    case livenessRecovered
    /// First heartbeat of a generation (start / rebuild / wake). `.info`; drives the honest "Resumed".
    case firstFrames
    /// A sticky alarm was raised / cleared (§6). `alarmRaised` is `.anomaly` for the ring but NOT
    /// quality-compromising: the condition that raised it already is.
    case alarmRaised
    case alarmCleared
    /// An aggregate-device listener fired (`goin`→0, `stpd`, `diff`, `agrp`); detail `selector`. `.warning`.
    case aggregateIOStopped
    /// The healing ladder ran a rung; detail `rung`, `delay`, `total`. `.warning`.
    case tapRecoveryRung
    /// The ladder's fast budget is spent; the slow retry owns it now. `.anomaly`.
    case tapRecoveryGivenUp
    /// A rung has not returned within the stuck deadline (a HAL call blocking on a paused context). `.anomaly`.
    case recoveryStuck
    /// coreaudiod restarted (`srst`): every audio object id is dead. `.warning`.
    case serviceRestarted
    /// Per-track coverage counters at a rotation / at stop (§7.1). `.info`.
    case trackCoverage
    /// Time during which nothing was recorded although the recording was running (relaunch, sleep). `.anomaly`.
    case captureGap
    /// A chunk rotation threw. `.anomaly`.
    case rotationFailed
    /// The recording folder did not answer a bounded look (L review 158): that step's file checks were skipped — a
    /// rotation named its next chunk from the counter. `.anomaly`.
    case folderNotAnswering
    /// `session.json` could not be written after a chunk. `.anomaly` (the audio is intact).
    case sessionWriteFailed
    /// Free space fell below one chunk at a rotation. `.warning`.
    case diskLow
    /// A helper call hit its deadline. `.anomaly`.
    case xpcTimeout
    /// A drain of the helper's ring failed (its XPC call errored, L review 203): the helper's events, if any, are still
    /// with it — the record says so. `.anomaly`.
    case helperDrainFailed
    /// `NSWorkspace.willSleep` / `didWake` while recording. `.info`; the interval becomes a `captureGap`.
    case systemSleep
    case systemWake
    /// The MID-RECORDING system (remote) stream could not be restarted within budget — the remote side
    /// stopped being captured even though the mic kept recording (#86). Severity `.anomaly`.
    case systemAudioUnrecovered
    /// The output device changed sample rate underneath the tap (Bluetooth A2DP -> HFP is NOT a
    /// device change, so no output-switch listener fires). The IOProc keeps delivering against a
    /// stale format: fewer frames arrive than the declared rate implies, the writer pads silence to
    /// hold the wall clock, and the remote audio comes out 2x-fast with gaps — correct duration,
    /// corrupt content. The stream is still RUNNING, so this is not a stop error. Severity `.anomaly`.
    case rateDrift

    /// Too much of a written track is silence we FABRICATED rather than captured. The timeline padder
    /// inserts silence so samples land at their true wall-clock position; when a device under-delivers,
    /// that same mechanism quietly makes up the shortfall and turns a detectably-short file into an
    /// undetectably-corrupt one of exactly the right length. Padding only ever responds to delivery
    /// deficit — never to quiet audio, which still arrives as buffers of zeros — so a high ratio means
    /// frames genuinely went missing, whatever the cause. This is the mechanism-independent backstop
    /// for the whole silent-divergence class (#58). Severity `.anomaly`.
    case excessivePadding

    /// A sustained run of system buffers rejected by the sticky format gate — the system track has
    /// stopped being written while the stream still appears to run. Distinct from the transient
    /// `formatChanged` so the two can be told apart when judging whether a recording is compromised.
    case sustainedFormatDrop

    /// The configured system-audio source could not be honoured and capture fell back to
    /// ScreenCaptureKit. A user who explicitly chose the Core Audio tap usually did so BECAUSE SCK
    /// records silence for their Continuity/VoIP calls — so a silent downgrade produces a
    /// structurally valid recording whose remote track is empty. Severity `.anomaly`.
    case captureSourceFallback

    /// The mic delivered a sustained run of samples that are EXACTLY zero — not merely quiet (#193).
    /// A real microphone always has a noise floor, so exact-zero is a sharp, false-positive-free
    /// signal that the input is being hardware-muted (the canonical case: a MacBook's built-in mic
    /// with the lid closed, which stays the default input device and keeps delivering full-rate
    /// buffers of digital silence — no padding, no `neverDelivered`, nothing else fires).
    /// Severity `.anomaly`.
    case exactZeroMic

    /// A track that was delivering stopped delivering for longer than the liveness watchdog's gap
    /// threshold, caught by a 1 Hz off-audio-queue timer rather than waiting for the next buffer
    /// that may never arrive (#196). Distinct from `neverDelivered` (a track that NEVER started
    /// after a start, rebuild or wake) — this one had delivered, then stopped. Severity `.anomaly`.
    case livenessGap

    /// `AVAudioConverter` (or the tap's format conversion) failed on a buffer. Previously only
    /// logged — a format the converter cannot handle fails on EVERY buffer with no user-visible
    /// signal (#196). Reported once per session per source, not per buffer. Severity `.anomaly`.
    case converterFailure

    /// A timeline gap exceeded the 60 s pad cap and was clamped — the mic/system alignment for the
    /// rest of the chunk is desynced by the untruncated remainder (#196). Previously logged only.
    /// Severity `.anomaly`. Deliberately NOT in `qualityCompromising`: this is a
    /// symptom, not independently a bad recording — its consequence (a frame-count mismatch at
    /// finalize) is what `finalizeFrameCountMismatch` catches and IS in that set.
    case padCapExceeded

    /// The shared mic/system timeline delta was implausible (non-finite, negative, or absurdly
    /// large — a cross-source PTS clock-epoch mismatch) and alignment was skipped for that buffer
    /// (#196). Previously logged only. Severity `.anomaly`. Deliberately NOT in `qualityCompromising`
    /// for the same reason as `padCapExceeded` above — `finalizeFrameCountMismatch` is the backstop.
    case timelineDeltaImplausible

    /// A modern throwing `FileHandle` call failed (disk full, I/O error) while writing a WAV. Before
    /// this the legacy `FileHandle` API raised an uncatchable Objective-C exception on the same
    /// fault, aborting the whole helper process mid-meeting (#196). Severity `.anomaly`.
    case writeFailure

    /// At finalize, a track's recorded frame count diverged implausibly from the session's elapsed
    /// wall-clock time — a session-wide backstop distinct from the per-chunk `excessivePadding`
    /// ratio, catching cases where padding itself was skipped (e.g. `timelineDeltaImplausible`)
    /// (#196). Severity `.anomaly`.
    case finalizeFrameCountMismatch

    /// The Core Audio tap is running WITHOUT the System Audio Recording permission (#220). macOS
    /// accepts the tap and runs its IOProc at full rate, but every sample is exact digital zero, so
    /// the recording looks structurally perfect while the remote side is gone. Raised when the helper
    /// confirms the denial (at tap start, or after a sustained exact-zero run while output is playing).
    /// Severity `.anomaly`.
    case systemAudioPermissionDenied
    /// The permission was granted mid-recording and the tap was rebuilt, so remote audio is being
    /// captured again (#220). The stretch before it stays lost. Severity `.info`.
    case systemAudioPermissionRestored

    /// One capture callback took more than `IOCycleStats.overrunThresholdNanos` (11.35 ms) from the start
    /// of its IO cycle to its end (#247). For the tap that includes the wait for the helper's shared
    /// audio queue, which the HAL counts against the device's IO budget. Detail: `track`, the stage
    /// breakdown in ms (`queue_wait_ms`, `convert_ms`, `pad_ms`, `write_ms`, `sync_ms`, `check_ms`, `total_ms`; a
    /// stage that did not run is left out) and `overruns`, the track's count so far. At most one event
    /// per track per 10 s; every overrun is counted in the stop summary (`*_io_overruns`).
    /// Severity `.anomaly`, so a session that had one keeps its `.diag.jsonl`. Deliberately NOT in
    /// `qualityCompromising` or `contentCompromising`: it measures the callback, not the recording.
    /// Frames a late callback costs show up as padding, which `excessivePadding` judges.
    case ioOverrun
}

extension CaptureEventKind {
    /// The kinds that mean THE RECORDING'S CONTENT may be wrong — as opposed to something happening
    /// and being handled.
    ///
    /// `anomalyCount` cannot answer that question: `.streamStopError` is recorded as an anomaly for
    /// what its own call site calls "a benign audio-route change (e.g. AirPods HFP↔A2DP)", and since
    /// opening the mic is what triggers that flip, it fires on essentially EVERY recording made on
    /// the default source with Bluetooth headphones — then the #86 restart recovers it completely.
    /// Labelling those recordings "capture anomalies" would make the warning meaningless within a
    /// week, which is worse than not warning at all: the point of the label is that it is rare.
    ///
    /// So the user-facing quality signal counts only the kinds that survive recovery.
    public static let qualityCompromising: Set<CaptureEventKind> = [
        .excessivePadding,
        .rateDrift,
        .sustainedFormatDrop,
        .systemAudioUnrecovered,
        .restartFailed,
        .captureSourceFallback,
        // A track full of exact-zero samples holds nothing usable, same as `neverDelivered`.
        .exactZeroMic,
        // A liveness gap means a stretch of the recording is missing or was recovered late.
        .livenessGap,
        // Every buffer the converter rejects is audio that never reached the WAV.
        .converterFailure,
        .writeFailure,
        .finalizeFrameCountMismatch,
        // A permission-denied tap records nothing but exact zeros for as long as the denial lasts.
        .systemAudioPermissionDenied,
        .neverDelivered, .tapRecoveryGivenUp, .recoveryStuck, .captureGap, .rotationFailed,
    ]

    /// The kinds that mean a side's CONTENT is wrong (§7.1) — what turns a track's status into
    /// `compromised`. Healed liveness episodes (`livenessGap`, `neverDelivered`) and recovery events
    /// stay evidence: they are already counted in the coverage deficit if they cost audio.
    public static let contentCompromising: Set<CaptureEventKind> = [
        .rateDrift, .exactZeroMic, .systemAudioPermissionDenied, .converterFailure, .writeFailure, .sustainedFormatDrop,
    ]
}

/// One structured capture event for the anomaly-gated diagnostic log.
public struct CaptureEvent: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case app, helper }
    public enum Severity: String, Codable, Sendable { case info, warning, anomaly }

    public let timestamp: Date
    public let origin: Origin
    public let kind: CaptureEventKind
    public let severity: Severity
    public let detail: [String: String]

    public init(
        timestamp: Date,
        origin: Origin,
        kind: CaptureEventKind,
        severity: Severity,
        detail: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.origin = origin
        self.kind = kind
        self.severity = severity
        self.detail = detail
    }

    /// Identifies "the same event" seen from two sources: the in-memory ring and the on-disk live
    /// log at finalize (`LiveDiagnosticsLog.merged(into:)`), or a ring re-presenting its own
    /// already-evicted events to itself at merge (E2 fix round 1). Millisecond-rounded because a
    /// disk round-trip through `LiveDiagnosticsLog`'s formatter drops sub-millisecond precision
    /// while the in-memory `Date` keeps full `Double` precision — rounding both sides the same way
    /// makes the key match regardless of which side introduced the float noise.
    static func dedupKey(_ e: CaptureEvent) -> String {
        let ms = (e.timestamp.timeIntervalSinceReferenceDate * 1000).rounded()
        return "\(ms)|\(e.origin.rawValue)|\(e.kind.rawValue)|\(e.detail.sorted { $0.key < $1.key })"
    }
}

// MARK: - Provenance stamp

/// Compact provenance stamp embedded in every transcript (clean run or not) — ~200 bytes.
public struct CaptureProvenance: Codable, Equatable, Sendable {
    public let engine: String
    public let systemFormat: String?
    public let micFormat: String?
    public let micDevice: String?
    public let routeChanges: Int
    public let retries: Int
    public let recovered: Bool
    public let anomalyCount: Int
    /// Subset of `anomalyCount` that indicates compromised CONTENT rather than a handled event.
    /// The user-facing "capture anomalies" label reads this, so that a routine Bluetooth route
    /// change — which is recorded as an anomaly and fully recovered — does not brand every
    /// recording as suspect.
    public let qualityAnomalyCount: Int
    /// True when the MID-RECORDING system (remote) stream could not be restarted within budget during
    /// the session — the remote side stopped being captured even though the mic kept recording (#86).
    public let systemAudioUnrecovered: Bool
    /// Measured on the Core Audio tap track: seconds of audio it delivered, and how many of those were
    /// exact digital zero (#220). A fact, not a judgement: a permission-denied tap is 100% zeros while
    /// every other field looks healthy. nil when the session didn't use the tap (or predates this).
    public let systemDeliveredSeconds: Int?
    public let systemExactZeroSeconds: Int?
    /// Per-track coverage (§7.1), summed across every helper session's `captureStop`. `nil` when
    /// no `captureStop` carried that side's counters (predates this, or the side was never used).
    public let localCoverage: TrackAccounting?
    public let remoteCoverage: TrackAccounting?
    /// `TrackAccounting.Status.rawValue` for each side, computed once at `makeProvenance` time from
    /// the coverage plus that side's content anomalies. `nil` exactly when the matching coverage is.
    public let localStatus: String?
    public let remoteStatus: String?
    /// How many ring events were evicted before this stamp was built (#101/L14) — the ring's own
    /// admission that it does not hold the session's whole story. Always emitted (default 0).
    public let eventsDropped: Int
    /// True only when the helper CONFIRMED the System Audio Recording permission was not granted
    /// (denied or not determined: a `systemAudioPermissionDenied` whose status is
    /// `denied`/`notDetermined`, not `unconfirmed`) and it was not restored afterwards. `systemAudioUnrecovered` cannot answer
    /// this: a failed stream restart sets it too, and "permission denied" is a claim to confirm.
    public let systemPermissionDeniedConfirmed: Bool
    /// Each side's CONTENT-compromising anomaly count (`contentAnomalyCount(track:)`), stamped into
    /// that side's coverage as `content_anomaly_count`. nil exactly when the side's coverage is
    /// (and in provenance written before this field).
    public let localContentAnomalyCount: Int?
    public let remoteContentAnomalyCount: Int?
    /// The transcript was rebuilt by a recovery run (its original was unreadable), and these capture
    /// facts come from that run's diagnostics, not the recording's: they may be incomplete (round 4
    /// item 7).
    public var reconstructed = false

    static let reconstructedNote = "Capture facts come from the recovery run that rebuilt this transcript, not from the recording itself; they may be incomplete."

    /// This stamp, marked as coming from a recovery run's rebuild.
    public func markedReconstructed() -> CaptureProvenance {
        var copy = self
        copy.reconstructed = true
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case systemFormat = "system_format"
        case micFormat = "mic_format"
        case micDevice = "mic_device"
        case routeChanges = "route_changes"
        case retries
        case recovered
        case anomalyCount = "anomaly_count"
        case qualityAnomalyCount = "quality_anomaly_count"
        case systemAudioUnrecovered = "system_audio_unrecovered"
        case systemDeliveredSeconds = "system_delivered_seconds"
        case systemExactZeroSeconds = "system_exact_zero_seconds"
        case localCoverage = "local_coverage"
        case remoteCoverage = "remote_coverage"
        case localStatus = "local_status"
        case remoteStatus = "remote_status"
        case eventsDropped = "events_dropped"
        case systemPermissionDeniedConfirmed = "system_permission_denied_confirmed"
        case localContentAnomalyCount = "local_content_anomaly_count"
        case remoteContentAnomalyCount = "remote_content_anomaly_count"
        case reconstructed
    }

    public init(
        engine: String,
        systemFormat: String?,
        micFormat: String?,
        micDevice: String?,
        routeChanges: Int,
        retries: Int,
        recovered: Bool,
        anomalyCount: Int,
        qualityAnomalyCount: Int = 0,
        systemAudioUnrecovered: Bool = false,
        systemDeliveredSeconds: Int? = nil,
        systemExactZeroSeconds: Int? = nil,
        localCoverage: TrackAccounting? = nil,
        remoteCoverage: TrackAccounting? = nil,
        localStatus: String? = nil,
        remoteStatus: String? = nil,
        eventsDropped: Int = 0,
        systemPermissionDeniedConfirmed: Bool = false,
        localContentAnomalyCount: Int? = nil,
        remoteContentAnomalyCount: Int? = nil
    ) {
        self.engine = engine
        self.systemFormat = systemFormat
        self.micFormat = micFormat
        self.micDevice = micDevice
        self.routeChanges = routeChanges
        self.retries = retries
        self.recovered = recovered
        self.anomalyCount = anomalyCount
        self.qualityAnomalyCount = qualityAnomalyCount
        self.systemAudioUnrecovered = systemAudioUnrecovered
        self.systemDeliveredSeconds = systemDeliveredSeconds
        self.systemExactZeroSeconds = systemExactZeroSeconds
        self.localCoverage = localCoverage
        self.remoteCoverage = remoteCoverage
        self.localStatus = localStatus
        self.remoteStatus = remoteStatus
        self.eventsDropped = eventsDropped
        self.systemPermissionDeniedConfirmed = systemPermissionDeniedConfirmed
        self.localContentAnomalyCount = localContentAnomalyCount
        self.remoteContentAnomalyCount = remoteContentAnomalyCount
    }

    /// Decode tolerantly: fields added after a release must NOT make an older `session.json`
    /// undecodable.
    ///
    /// `SessionState` persists this, and `ChunkSession.read()` decodes with `try?` — so a single
    /// throwing field turns the whole session into "corrupt" and DROPS it. During crash recovery that
    /// is an in-progress recording lost, which is the exact category of harm this PR exists to close.
    /// Every field that did not ship in the first version is therefore `decodeIfPresent` with a
    /// default, and any field added later must follow the same rule.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(String.self, forKey: .engine)
        systemFormat = try c.decodeIfPresent(String.self, forKey: .systemFormat)
        micFormat = try c.decodeIfPresent(String.self, forKey: .micFormat)
        micDevice = try c.decodeIfPresent(String.self, forKey: .micDevice)
        routeChanges = try c.decode(Int.self, forKey: .routeChanges)
        retries = try c.decode(Int.self, forKey: .retries)
        recovered = try c.decode(Bool.self, forKey: .recovered)
        anomalyCount = try c.decode(Int.self, forKey: .anomalyCount)
        qualityAnomalyCount = try c.decodeIfPresent(Int.self, forKey: .qualityAnomalyCount) ?? 0
        // Also added after the original shape — same hazard, previously latent.
        systemAudioUnrecovered = try c.decodeIfPresent(Bool.self, forKey: .systemAudioUnrecovered) ?? false
        systemDeliveredSeconds = try c.decodeIfPresent(Int.self, forKey: .systemDeliveredSeconds)
        systemExactZeroSeconds = try c.decodeIfPresent(Int.self, forKey: .systemExactZeroSeconds)
        localCoverage = try c.decodeIfPresent(TrackAccounting.self, forKey: .localCoverage)
        remoteCoverage = try c.decodeIfPresent(TrackAccounting.self, forKey: .remoteCoverage)
        localStatus = try c.decodeIfPresent(String.self, forKey: .localStatus)
        remoteStatus = try c.decodeIfPresent(String.self, forKey: .remoteStatus)
        eventsDropped = try c.decodeIfPresent(Int.self, forKey: .eventsDropped) ?? 0
        systemPermissionDeniedConfirmed = try c.decodeIfPresent(Bool.self, forKey: .systemPermissionDeniedConfirmed) ?? false
        localContentAnomalyCount = try c.decodeIfPresent(Int.self, forKey: .localContentAnomalyCount)
        remoteContentAnomalyCount = try c.decodeIfPresent(Int.self, forKey: .remoteContentAnomalyCount)
        reconstructed = try c.decodeIfPresent(Bool.self, forKey: .reconstructed) ?? false
    }

    /// Build the snake_case dictionary embedded in transcript metadata under `capture_provenance`.
    public func asMetadataDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "engine": engine,
            "route_changes": routeChanges,
            "retries": retries,
            "recovered": recovered,
            "anomaly_count": anomalyCount,
            "quality_anomaly_count": qualityAnomalyCount,
            "system_audio_unrecovered": systemAudioUnrecovered,
            "events_dropped": eventsDropped,
            "system_permission_denied_confirmed": systemPermissionDeniedConfirmed,
        ]
        if reconstructed {
            d["reconstructed"] = true
            d["reconstructed_note"] = Self.reconstructedNote
        }
        if let systemFormat { d["system_format"] = systemFormat }
        if let micFormat { d["mic_format"] = micFormat }
        if let micDevice { d["mic_device"] = micDevice }
        if let systemDeliveredSeconds { d["system_delivered_seconds"] = systemDeliveredSeconds }
        if let systemExactZeroSeconds { d["system_exact_zero_seconds"] = systemExactZeroSeconds }
        // Fail closed (fix round 1 item 3): a missing or unparseable status string must never read
        // as "healthy" by default — recompute a real verdict from the coverage that's actually here.
        // `contentAnomalies: 0` is the best available at this layer (the stamp doesn't carry the raw
        // count), which only matters when the stored status disagreed on a live content anomaly with
        // no coverage deficit; the coverage-only verdict is still never a silent "healthy" default.
        if let remoteCoverage {
            let status = remoteStatus.flatMap(TrackAccounting.Status.init(rawValue:))
                ?? remoteCoverage.status(isTap: true, contentAnomalies: remoteContentAnomalyCount ?? 0)
            var side = remoteCoverage.asMetadataDictionary(status: status)
            if let remoteContentAnomalyCount { side["content_anomaly_count"] = remoteContentAnomalyCount }
            d["remote_coverage"] = side
        }
        if let localCoverage {
            let status = localStatus.flatMap(TrackAccounting.Status.init(rawValue:))
                ?? localCoverage.status(isTap: false, contentAnomalies: localContentAnomalyCount ?? 0)
            var side = localCoverage.asMetadataDictionary(status: status)
            if let localContentAnomalyCount { side["content_anomaly_count"] = localContentAnomalyCount }
            d["local_coverage"] = side
        }
        return d
    }
}

// MARK: - Bounded ring

/// A bounded, in-memory ring of capture events. Costs nothing on a clean run (only a
/// provenance stamp is persisted); on an anomaly the ring is flushed to `<session>.diag.jsonl`.
/// Eviction drops the oldest events once either the event-count or byte cap is exceeded (#95).
public struct CaptureDiagnostics: Sendable {
    public private(set) var events: [CaptureEvent] = []
    public private(set) var droppedCount: Int = 0
    public let maxEvents: Int
    public let maxBytes: Int

    private var byteCosts: [Int] = []
    private var totalBytes: Int = 0

    public init(maxEvents: Int = 5000, maxBytes: Int = 1_000_000) {
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encode(_ event: CaptureEvent) -> Data {
        (try? makeEncoder().encode(event)) ?? Data()
    }

    /// Counters that live OUTSIDE the evicting ring (#101, L4/L14): unlike derived properties that
    /// scan `events`, these must survive both eviction (an evicted retry still happened) and
    /// `clear()` (an in-session restart does not erase the session's own story) — only
    /// `resetSession()`, the new-session reset, zeroes them.
    public private(set) var retryCount = 0
    public private(set) var launchRecoveries = 0
    /// Per-side content-anomaly tallies and per-helper coverage (§7.1, fix round 1) — fed by
    /// `count()`, same out-of-ring lifetime as the counters above. Without this, a track's
    /// `compromised`/`neverDelivered` verdict would flip back to `healthy` the moment its own
    /// evidence (the `rateDrift`, the `captureStop`) aged out of the bounded ring.
    private var contentAnomalyTallies: [String: Int] = [:]
    /// Coverage per HELPER SESSION, then per prefix (#229), summed at `makeProvenance`. A helper's stand-in (its last
    /// status pull, for a helper that wrote no `captureStop`) is REPLACED by that helper's real stop whenever it arrives
    /// — a later finalize included — never added to it. `""` holds the stops that name no helper session.
    private var coverageTallies: [String: HelperCoverage] = [:]
    /// The helper sessions in the order first seen: the sum is made in that order, as it always was.
    private var coverageOrder: [String] = []
    /// The record was built without its recording folder (#229: the live log and the crashed helpers' coverage are
    /// there): what it holds is part of the session, so both sides' coverage is a lower bound and `makeProvenance`
    /// marks it `coverageIncomplete`. Set by the build; a later build that read the folder clears it.
    public var coverageIsLowerBound = false

    private struct HelperCoverage: Sendable {
        var tracks: [String: TrackAccounting]
        /// When the status pull it was made from was taken; nil = the helper's own `captureStop`.
        var standInAt: Date?
    }
    /// The latest CONFIRMED permission denial and the latest restore (out-of-ring, same lifetime as
    /// the tallies). Timestamps rather than a flag, so the answer does not depend on the order in
    /// which merges first present the events.
    private var lastConfirmedDenial: Date?
    private var lastPermissionRestore: Date?
    /// The user-facing notice's two fields (XI bug 2), same out-of-ring lifetime: scanned from the
    /// evicting ring, a compromised recording read "Transcription Complete" once its evidence aged
    /// out. Any denial (confirmed or not) counts for `systemAudioUnrecovered`.
    private var qualityAnomalyTally = 0
    /// Every anomaly and every handled route change (R2b item 8), out of ring for the same reason:
    /// `anomaly_count` is the superset of `quality_anomaly_count` and must never drop below it.
    private var anomalyTally = 0
    private var routeChangeTally = 0
    private var sawSystemAudioUnrecovered = false
    private var lastDenial: Date?

    /// Idempotency guards (fix round 1 item 1): `LiveDiagnosticsLog.merged(into:)` re-presents
    /// events the ring already evicted (read back from the live log) alongside events the ring
    /// still holds, and `merge()` rebuilds the whole ring from that combined list — so both
    /// `count()` and `evict()` see the SAME event more than once across the ring's lifetime.
    /// Without a per-event identity, every retry/anomaly/coverage tally and `droppedCount` would
    /// double on every finalize merge. Keyed by `CaptureEvent.dedupKey`, same as the live log's own
    /// disk/ring dedup. Out-of-ring: survive `clear()`, zeroed only by `resetSession()`.
    private var countedKeys: Set<String> = []
    private var droppedKeys: Set<String> = []
    /// The helper sessions that wrote a `captureStop` (out-of-ring, same lifetime as `coverageTallies`): a
    /// stop evicted from the ring still supersedes its helper session's pulled snapshot (L11 review 67).
    public private(set) var stoppedHelperSessions: Set<String> = []

    public mutating func record(_ event: CaptureEvent) {
        store(event)
        count(event)
    }

    private mutating func store(_ event: CaptureEvent) {
        let cost = Self.encode(event).count + 1  // + newline
        events.append(event)
        byteCosts.append(cost)
        totalBytes += cost
        evict()
    }

    /// Idempotent per event (fix round 1): the first time a given event is seen, tally it into every
    /// out-of-ring counter it contributes to; a repeat sighting (same key) is a no-op.
    private mutating func count(_ e: CaptureEvent) {
        guard countedKeys.insert(CaptureEvent.dedupKey(e)).inserted else { return }
        if e.kind == .retry { retryCount += 1 }
        if e.kind == .launchRecovery { launchRecoveries += 1 }
        if CaptureEventKind.qualityCompromising.contains(e.kind) { qualityAnomalyTally += 1 }
        if e.severity == .anomaly { anomalyTally += 1 }
        if e.kind == .restartInPlace { routeChangeTally += 1 }
        if e.kind == .systemAudioUnrecovered { sawSystemAudioUnrecovered = true }
        if e.kind == .systemAudioPermissionDenied { lastDenial = max(lastDenial ?? e.timestamp, e.timestamp) }
        if CaptureEventKind.contentCompromising.contains(e.kind), let track = Self.side(of: e) {
            contentAnomalyTallies[track, default: 0] += 1
        }
        if e.kind == .systemAudioPermissionDenied, Self.confirmedDenialStatuses.contains(e.detail["status"] ?? "") {
            lastConfirmedDenial = max(lastConfirmedDenial ?? e.timestamp, e.timestamp)
        }
        if e.kind == .systemAudioPermissionRestored {
            lastPermissionRestore = max(lastPermissionRestore ?? e.timestamp, e.timestamp)
        }
        if e.kind == .captureStop {
            if let helper = e.detail["helper_session"] { stoppedHelperSessions.insert(helper) }
            var tracks: [String: TrackAccounting] = [:]
            for prefix in ["local", "remote"] { tracks[prefix] = TrackAccounting(detail: e.detail, prefix: prefix) }
            tally(HelperCoverage(tracks: tracks, standInAt: e.detail["from"] == Self.standInSource ? e.timestamp : nil),
                  helper: e.detail["helper_session"] ?? "")
        }
    }

    /// What marks a `captureStop` as a stand-in (`detail["from"]`): made from a helper session's last status pull.
    public static let standInSource = "status pull"

    /// One `captureStop`'s coverage into its helper session's tally (#229).
    private mutating func tally(_ new: HelperCoverage, helper: String) {
        guard var held = coverageTallies[helper] else {
            coverageTallies[helper] = new
            coverageOrder.append(helper)
            return
        }
        switch (held.standInAt, new.standInAt) {
        case (nil, .some):
            return   // the helper stopped: its stand-in never counts
        case (.some, nil):
            held = new   // the real stop replaces the stand-in
        case let (old?, latest?):
            if latest >= old { held = new }   // the same counters, further on: the latest pull stands in
        case (nil, nil):
            // Stops that name no helper session (or two of one): summed, as before. The first is the tally itself:
            // summed onto an empty counter it would read as "measured + unmeasured" and be marked a lower bound.
            held.tracks.merge(new.tracks) { sum, parsed in var sum = sum; sum += parsed; return sum }
        }
        coverageTallies[helper] = held
    }

    private mutating func evict() {
        while events.count > maxEvents || (totalBytes > maxBytes && events.count > 1) {
            totalBytes -= byteCosts.removeFirst()
            let removed = events.removeFirst()
            // Idempotent per event (fix round 1): re-evicting the SAME event on a later merge (it
            // comes back from the live log, gets re-stored, then gets re-evicted) must not inflate
            // `droppedCount` a second time.
            if droppedKeys.insert(CaptureEvent.dedupKey(removed)).inserted {
                droppedCount += 1
            }
        }
    }

    /// Empty the ring (an IN-SESSION restart, e.g. after a drain to the app side). Keeps every
    /// out-of-ring counter and tally — they are this session's story, not the ring's contents.
    public mutating func clear() {
        events.removeAll()
        byteCosts.removeAll()
        totalBytes = 0
    }

    /// Reset for a NEW session (a new session id): `clear()` plus zeroing every out-of-ring counter,
    /// tally and idempotency guard.
    public mutating func resetSession() {
        clear()
        droppedCount = 0
        retryCount = 0
        launchRecoveries = 0
        contentAnomalyTallies.removeAll()
        coverageTallies.removeAll()
        coverageOrder.removeAll()
        coverageIsLowerBound = false
        stoppedHelperSessions.removeAll()
        lastConfirmedDenial = nil
        lastPermissionRestore = nil
        qualityAnomalyTally = 0
        anomalyTally = 0
        routeChangeTally = 0
        sawSystemAudioUnrecovered = false
        lastDenial = nil
        countedKeys.removeAll()
        droppedKeys.removeAll()
    }

    /// Merge events drained from another ring (e.g. the helper), keeping the result time-sorted.
    /// Re-`record`s the WHOLE combined list rather than just `other`: `count()`/`evict()` are now
    /// idempotent per event (fix round 1), so an event the ring already held or had already evicted
    /// is a safe no-op the second time, and a repeated merge of the same disk log can never
    /// double-count a retry or inflate `droppedCount` (scan B P3.6(2)).
    /// Merge a helper drain as it came off the wire. Events this build cannot decode (a kind from a
    /// newer helper) are skipped and counted into `droppedCount`, so `events_dropped` admits them
    /// (R2b item 8). Callers should prefer this to `merge(events(from:))`, which cannot count them.
    public mutating func mergeDrained(_ data: Data) {
        let (events, undecodable) = Self.decodeLossy(data)
        droppedCount += undecodable
        if !events.isEmpty { merge(events) }
    }

    public mutating func merge(_ other: [CaptureEvent]) {
        let combined = (events + other).sorted { $0.timestamp < $1.timestamp }
        clear()
        for event in combined { record(event) }
    }

    /// Whether `<session>.diag.jsonl` is written: from the out-of-ring tally, so a session whose
    /// anomalies were evicted still writes it (round 3 item 6).
    public var isAnomalous: Bool { anomalyTally > 0 }
    /// Count handled benign route changes via the in-place restart they each trigger. (The pinned
    /// 48kHz/mono system tap never emits `.formatChanged`, so counting that would always read 0 for
    /// the AirPods HFP↔A2DP scenario this exists to surface — council F5.)
    /// Out-of-ring, once per event (R2b item 8).
    public var routeChangeCount: Int { routeChangeTally }
    public var didRecover: Bool { launchRecoveries > 0 }
    /// Out-of-ring, once per event (R2b item 8): never below `qualityAnomalyCount`.
    public var anomalyCount: Int { anomalyTally }
    /// Anomalies that mean the CONTENT may be wrong, as opposed to something that happened and was
    /// handled. This is what the user-facing quality notice reads — see `qualityCompromising`.
    /// Out-of-ring and once per event: correct after eviction, `clear()` and a re-merge (XI bug 2).
    public var qualityAnomalyCount: Int { qualityAnomalyTally }
    /// True when the mid-recording system stream was declared unrecoverable during the session (#86).
    /// True when the remote side stopped being captured and did not come back. That includes a
    /// System Audio Recording denial that was never restored: the 2026-09-23 recording reported
    /// `false` here while holding no remote audio at all (#220). Out-of-ring, like the count above.
    public var systemAudioUnrecovered: Bool {
        if sawSystemAudioUnrecovered { return true }
        guard let denied = lastDenial else { return false }
        return lastPermissionRestore.map { $0 < denied } ?? true
    }

    /// The permission statuses that CONFIRM a denial: TCC answered "not granted". `unconfirmed` (the
    /// helper inferred it from sustained silence) does not.
    static let confirmedDenialStatuses: Set<String> = ["denied", "notDetermined"]

    /// True when the session's latest confirmed permission denial was not followed by a restore.
    public var systemPermissionDeniedConfirmed: Bool {
        guard let denied = lastConfirmedDenial else { return false }
        return lastPermissionRestore.map { $0 < denied } ?? true
    }

    /// Newline-delimited JSON of all events (the `.diag.jsonl` payload).
    public func jsonlData() -> Data {
        var out = Data()
        for event in events {
            out.append(Self.encode(event))
            out.append(0x0A)
        }
        return out
    }

    /// Encode the ring's events for transport across XPC (helper → app).
    public func snapshotData() -> Data {
        (try? Self.makeEncoder().encode(events)) ?? Data()
    }

    /// Decode events transported across XPC. Returns `[]` when the payload is unreadable (fail-soft).
    /// One event this build can't decode (a kind from a newer helper) is skipped and logged; it used
    /// to fail the whole drain and lose every event of the session (C-M7).
    public static func events(from data: Data) -> [CaptureEvent] {
        decodeLossy(data).events
    }

    private static func decodeLossy(_ data: Data) -> (events: [CaptureEvent], undecodable: Int) {
        guard let decoded = try? makeDecoder().decode([Lossy].self, from: data) else { return ([], 0) }
        let events = decoded.compactMap(\.event)
        if events.count < decoded.count {
            Logger.state.error("Skipped \(decoded.count - events.count, privacy: .public) capture event(s) this build cannot read")
        }
        return (events, decoded.count - events.count)
    }

    /// One array element that may not decode as a `CaptureEvent`.
    private struct Lossy: Decodable {
        let event: CaptureEvent?
        init(from decoder: Decoder) throws { event = try? CaptureEvent(from: decoder) }
    }

    /// Which side an event is about: its `track`/`source` detail, else the kind's own side.
    private static func side(of e: CaptureEvent) -> String? {
        if let t = e.detail["track"] ?? e.detail["source"] {
            if t == "mic" { return "mic" }
            if ["system", "system-tap", "tap"].contains(t) { return "system" }
        }
        switch e.kind {
        case .exactZeroMic: return "mic"
        case .systemAudioPermissionDenied, .rateDrift, .sustainedFormatDrop: return "system"
        default: return nil
        }
    }

    /// Reads the out-of-ring tally (fix round 1) — correct even after the content-anomaly events
    /// themselves have been evicted from `events`.
    public func contentAnomalyCount(track: String) -> Int {
        contentAnomalyTallies[track] ?? 0
    }

    /// Sums the out-of-ring tallies of every helper session (fix round 1, #229) — correct even after the
    /// contributing `captureStop` events themselves have been evicted from `events`.
    private func coverage(prefix: String) -> TrackAccounting? {
        var sum: TrackAccounting?
        for helper in coverageOrder {
            guard let part = coverageTallies[helper]?.tracks[prefix] else { continue }
            // The first session is the sum itself (see `tally`).
            if var running = sum { running += part; sum = running } else { sum = part }
        }
        if coverageIsLowerBound { sum?.coverageIncomplete = true }
        return sum
    }

    public func makeProvenance(
        engine: String,
        systemFormat: String?,
        micFormat: String?,
        micDevice: String?
    ) -> CaptureProvenance {
        let remote = coverage(prefix: "remote")
        let local = coverage(prefix: "local")
        return CaptureProvenance(
            engine: engine,
            systemFormat: systemFormat,
            micFormat: micFormat,
            micDevice: micDevice,
            routeChanges: routeChangeCount,
            retries: retryCount,
            recovered: didRecover,
            anomalyCount: anomalyCount,
            qualityAnomalyCount: qualityAnomalyCount,
            systemAudioUnrecovered: systemAudioUnrecovered,
            systemDeliveredSeconds: remote.map { Int($0.deliveredSeconds.rounded()) } ?? tapTrackSeconds("system_delivered_seconds"),
            // Per-track coverage when there is some — and then only what it measured (SCK measures
            // no exact zeros: nil, never 0, XI bug 1); the legacy key otherwise.
            // A lower bound can't be stated by the bare integer: it is left out, and the coverage
            // carries the value with its mark (R2b item 8).
            systemExactZeroSeconds: remote.map { r in r.exactZeroIsLowerBound ? nil : r.exactZeroSeconds.map { Int($0.rounded()) } }
                ?? tapTrackSeconds("system_exact_zero_seconds"),
            localCoverage: local,
            remoteCoverage: remote,
            localStatus: local.map { $0.status(isTap: false, contentAnomalies: contentAnomalyCount(track: "mic")).rawValue },
            remoteStatus: remote.map { $0.status(isTap: true, contentAnomalies: contentAnomalyCount(track: "system")).rawValue },
            eventsDropped: droppedCount,
            systemPermissionDeniedConfirmed: systemPermissionDeniedConfirmed,
            localContentAnomalyCount: local.map { _ in contentAnomalyCount(track: "mic") },
            remoteContentAnomalyCount: remote.map { _ in contentAnomalyCount(track: "system") }
        )
    }

    /// Summed across every helper session's `captureStop` (a crash-recovered recording has several).
    /// Legacy fallback for when no per-track coverage counters are present in the events (§7.1's
    /// `coverage(prefix:)` supersedes this once a session carries `remote_expected_seconds` etc.).
    private func tapTrackSeconds(_ key: String) -> Int? {
        let values = events.filter { $0.kind == .captureStop }.compactMap { $0.detail[key].flatMap(Int.init) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

// MARK: - Thread-safe wrapper (helper side)

/// Thread-safe wrapper around a `CaptureDiagnostics` ring for the XPC helper, where capture
/// callbacks arrive on background queues and the app drains over XPC. App-side code uses the
/// plain struct on the main actor.
public final class LockedDiagnostics: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: CaptureDiagnostics())

    public init() {}

    public func record(_ event: CaptureEvent) {
        lock.withLock { $0.record(event) }
    }

    /// Empty the ring's EVENTS (an in-session restart, same as `CaptureDiagnostics.clear()` — see
    /// its doc) so a skipped finalize (crash) can't carry the previous session's events into the
    /// next one.
    public func clear() {
        lock.withLock { $0.clear() }
    }

    /// A NEW capture session in the helper (council B-M14a): `clear()` plus every out-of-ring counter,
    /// tally and dedup key. The helper never consumes those (only the app does, after draining), but
    /// the dedup keys otherwise grow for the helper's whole lifetime.
    public func resetSession() {
        lock.withLock { $0.resetSession() }
    }

    /// Snapshot the ring for transport and clear it, atomically.
    public func drainData() -> Data {
        lock.withLock {
            let data = $0.snapshotData()
            $0.clear()
            return data
        }
    }
}
