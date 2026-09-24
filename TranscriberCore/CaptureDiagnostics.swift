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
    /// `session.json` could not be written after a chunk. `.anomaly` (the audio is intact).
    case sessionWriteFailed
    /// Free space fell below one chunk at a rotation. `.warning`.
    case diskLow
    /// A helper call hit its deadline. `.anomaly`.
    case xpcTimeout
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
        remoteStatus: String? = nil
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
        ]
        if let systemFormat { d["system_format"] = systemFormat }
        if let micFormat { d["mic_format"] = micFormat }
        if let micDevice { d["mic_device"] = micDevice }
        if let systemDeliveredSeconds { d["system_delivered_seconds"] = systemDeliveredSeconds }
        if let systemExactZeroSeconds { d["system_exact_zero_seconds"] = systemExactZeroSeconds }
        if let remoteCoverage {
            d["remote_coverage"] = remoteCoverage.asMetadataDictionary(status: TrackAccounting.Status(rawValue: remoteStatus ?? "healthy") ?? .healthy)
        }
        if let localCoverage {
            d["local_coverage"] = localCoverage.asMetadataDictionary(status: TrackAccounting.Status(rawValue: localStatus ?? "healthy") ?? .healthy)
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

    public mutating func record(_ event: CaptureEvent) {
        let cost = Self.encode(event).count + 1  // + newline
        events.append(event)
        byteCosts.append(cost)
        totalBytes += cost
        evict()
    }

    private mutating func evict() {
        while events.count > maxEvents || (totalBytes > maxBytes && events.count > 1) {
            totalBytes -= byteCosts.removeFirst()
            events.removeFirst()
            droppedCount += 1
        }
    }

    /// Empty the ring (after a drain to the app side).
    public mutating func clear() {
        events.removeAll()
        byteCosts.removeAll()
        totalBytes = 0
        droppedCount = 0
    }

    /// Merge events drained from another ring (e.g. the helper), keeping the result time-sorted.
    public mutating func merge(_ other: [CaptureEvent]) {
        let combined = (events + other).sorted { $0.timestamp < $1.timestamp }
        clear()
        for event in combined { record(event) }
    }

    public var isAnomalous: Bool { events.contains { $0.severity == .anomaly } }
    /// Count handled benign route changes via the in-place restart they each trigger. (The pinned
    /// 48kHz/mono system tap never emits `.formatChanged`, so counting that would always read 0 for
    /// the AirPods HFP↔A2DP scenario this exists to surface — council F5.)
    public var routeChangeCount: Int { events.lazy.filter { $0.kind == .restartInPlace }.count }
    public var retryCount: Int { events.lazy.filter { $0.kind == .retry }.count }
    public var didRecover: Bool { events.contains { $0.kind == .launchRecovery } }
    public var anomalyCount: Int { events.lazy.filter { $0.severity == .anomaly }.count }
    /// Anomalies that mean the CONTENT may be wrong, as opposed to something that happened and was
    /// handled. This is what the user-facing quality notice reads — see `qualityCompromising`.
    public var qualityAnomalyCount: Int {
        events.lazy.filter { CaptureEventKind.qualityCompromising.contains($0.kind) }.count
    }
    /// True when the mid-recording system stream was declared unrecoverable during the session (#86).
    /// True when the remote side stopped being captured and did not come back. That includes a
    /// System Audio Recording denial that was never restored: the 2026-09-23 recording reported
    /// `false` here while holding no remote audio at all (#220).
    public var systemAudioUnrecovered: Bool {
        if events.contains(where: { $0.kind == .systemAudioUnrecovered }) { return true }
        guard let denied = events.lastIndex(where: { $0.kind == .systemAudioPermissionDenied }) else {
            return false
        }
        let restored = events.lastIndex(where: { $0.kind == .systemAudioPermissionRestored })
        return restored.map { $0 < denied } ?? true
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

    /// Decode events transported across XPC. Returns `[]` on any failure (fail-soft).
    public static func events(from data: Data) -> [CaptureEvent] {
        (try? makeDecoder().decode([CaptureEvent].self, from: data)) ?? []
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

    public func contentAnomalyCount(track: String) -> Int {
        events.filter { CaptureEventKind.contentCompromising.contains($0.kind) && Self.side(of: $0) == track }.count
    }

    private func coverage(prefix: String) -> TrackAccounting? {
        let parts = events.filter { $0.kind == .captureStop }.compactMap { TrackAccounting(detail: $0.detail, prefix: prefix) }
        guard var total = parts.first else { return nil }
        for p in parts.dropFirst() { total += p }
        return total
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
            systemExactZeroSeconds: remote.map { Int($0.exactZeroSeconds.rounded()) } ?? tapTrackSeconds("system_exact_zero_seconds"),
            localCoverage: local,
            remoteCoverage: remote,
            localStatus: local.map { $0.status(isTap: false, contentAnomalies: contentAnomalyCount(track: "mic")).rawValue },
            remoteStatus: remote.map { $0.status(isTap: true, contentAnomalies: contentAnomalyCount(track: "system")).rawValue }
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

    /// Empty the ring (per-session reset at the start of capture, #101) so a skipped finalize (crash)
    /// can't carry the previous session's events into the next one.
    public func clear() {
        lock.withLock { $0.clear() }
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
