// RED-FIRST-EXEMPT: characterization tests of merged cross-stream behaviour (streams C, F, D, E, H, R); each test was proven able to fail by temporarily breaking the production line it pins (task XI report). The R2c changes (the two re-enabled BUG tests, the neutral muted-remote line in (e), the mid-call denial in (c′)) were run red first (task R2c report)
// RED-FIRST-EXEMPT: characterization of the Incident-B chain at HEAD (final review E-I2); the red-first proof for HF-1 lives in TapRecoveryLadderTests/TapHealerTests
import Foundation
import Testing
@testable import TranscriberCore

// Cross-stream INTEGRATION tests for the capture-reliability overhaul. Each suite runs one chain end
// to end with the REAL Core types; only what lives in an executable target (the XPC helper's glue in
// `AudioCaptureService`) is mirrored here, line for line, with its source location named.

// MARK: - Shared fixtures

/// Helper-shaped capture events, built the way `AudioCaptureService` emits them.
enum HelperShaped {
    /// Whole seconds: the helper → app drain encodes `.iso8601`, which keeps no fraction.
    static let base = Date(timeIntervalSince1970: 1_790_000_000)
    static let tapRate: Double = 48_000

    static func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    static func side(expected: Double, delivered: Double, zeros: Double = 0, callbacks: Int = 0,
                     longestGap: Double = 0, gaps: Int = 0, rebuilds: Int = 0) -> TrackAccounting {
        var t = TrackAccounting()
        t.expectedSeconds = expected
        t.deliveredSeconds = delivered
        t.exactZeroSeconds = zeros
        t.heartbeatCallbacks = callbacks
        t.longestGapSeconds = longestGap
        t.gapCount = gaps
        t.rebuilds = rebuilds
        return t
    }

    /// `AudioCaptureService.coverageFacts()` (:221-252) as recorded by `stopCapture` (:569) and
    /// `stopAndFinalize` (:857): `remote_*` + `local_*` keys from `TrackAccounting.asDetail`; on SCK
    /// (`tap == false`) the two unmeasured remote keys are omitted.
    static func captureStop(at seconds: Double, remote: TrackAccounting, local: TrackAccounting, tap: Bool = true) -> CaptureEvent {
        var remoteDetail = remote.asDetail(prefix: "remote")
        if !tap {
            remoteDetail["remote_exact_zero_seconds"] = nil
            remoteDetail["remote_heartbeat_callbacks"] = nil
        }
        return CaptureEvent(timestamp: at(seconds), origin: .helper, kind: .captureStop, severity: .info,
                            detail: remoteDetail.merging(local.asDetail(prefix: "local")) { a, _ in a })
    }

    static func event(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, at seconds: Double,
                      _ detail: [String: String] = [:], origin: CaptureEvent.Origin = .helper) -> CaptureEvent {
        CaptureEvent(timestamp: at(seconds), origin: origin, kind: kind, severity: severity, detail: detail)
    }

    /// Drives the REAL `TapPermissionGuard` over `seconds` of exact-zero tap audio at 48 kHz, answering
    /// every TCC check with `tcc`, and returns the events the helper's `apply(_:)` (:803-846) records.
    /// A `.rebuildTap` goes through a REAL `TapHealer` exactly as the helper routes it (:821), the tap
    /// rebuilds fine and frames keep flowing; `healerAlarmCalls` counts any give-up/stuck it raised.
    static func permissionGuardRun(builtWith: PermissionStatus?, tcc: PermissionStatus?, seconds: Int)
        -> (events: [CaptureEvent], rebuilds: [TapPermissionGuard.RebuildReason], healerAlarmCalls: Int) {
        var permission = TapPermissionGuard()
        var events: [CaptureEvent] = []
        var rebuilds: [TapPermissionGuard.RebuildReason] = []
        var healerAlarmCalls = 0
        let clock = TapHealerTests.ManualScheduler()
        let tap = TapHealerTests.FakeTap()
        let healer = TapHealer(scheduler: clock)
        healer.onEvent = { kind, severity, detail in events.append(CaptureEvent(timestamp: at(clock.now), origin: .helper, kind: kind, severity: severity, detail: detail)) }
        healer.onGiveUp = { _ in healerAlarmCalls += 1 }
        healer.onStuck = { healerAlarmCalls += 1 }
        healer.startSession(tap: tap)
        let zeros = [Int16](repeating: 0, count: Int(tapRate))

        func apply(_ actions: [TapPermissionGuard.Action], now: Double) {
            for action in actions {
                switch action {
                case .checkPermission(let evidence):
                    apply(permission.permissionChecked(tcc, evidence: evidence, now: now), now: now)
                case .rebuildTap(let reason):
                    rebuilds.append(reason)
                    healer.trigger(reason == .grant ? .permissionGrant : .permissionInsurance)
                    clock.advance(by: 0.25)
                    if let rung = tap.rebuilds.last { healer.rebuildResult(rung: rung.rung, token: rung.token, succeeded: true) }
                    healer.heartbeatObserved()   // the rebuilt tap's first frames (frames keep flowing)
                    apply(permission.tapBuilt(status: tcc, now: now), now: now)   // tapDidBuild (:792-801)
                case .reportDenied(let status):
                    events.append(event(.systemAudioPermissionDenied, .anomaly, at: now, [
                        "status": status == nil ? "unconfirmed" : SystemAudioRecordingPermission.wireValue(status),
                    ]))
                case .reportRestored:
                    events.append(event(.systemAudioPermissionRestored, .info, at: now))
                }
            }
        }
        apply(permission.tapBuilt(status: builtWith, now: 0), now: 0)
        for second in 1...seconds {
            let now = Double(second)
            apply(permission.samples(zeros, rate: tapRate, now: now), now: now)
            apply(permission.tick(now: now), now: now)
        }
        clock.advance(by: 120)   // anything the healer still had queued gets its chance to fire
        return (events, rebuilds, healerAlarmCalls)
    }
}

/// A provider that answers without a network and keeps what it was handed.
final class IntegrationCapturingProvider: SummaryProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: SummaryMetadata?
    var metadata: SummaryMetadata? { lock.withLock { captured } }

    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        lock.withLock { captured = metadata }
        return "### Summary\nThe meeting notes."
    }
}

// MARK: - Chain 1: coverage → record → summary

/// Helper events → helper ring → XPC drain → app ring → `makeProvenance` → session.json →
/// `TranscriptionRunner.finalize` (`TranscriptAssembler`: `metadata.capture`, `capture_provenance`) →
/// transcript JSON on disk → `MeetingSummarizer` (transcript parse → `SummaryPromptBuilder.captureLine`,
/// the deterministic banner in `-summary.md`) and the completion notice's anomaly count.
@MainActor
@Suite struct CaptureRecordIntegrationCoverageToSummaryTests {
    typealias H = HelperShaped

    struct Record {
        let provenance: CaptureProvenance
        let metadata: [String: Any]
        let summaryMetadata: SummaryMetadata
        let summaryMarkdown: String
        let completionTitle: String

        var capture: [String: Any]? { metadata["capture"] as? [String: Any] }
        var remote: [String: Any]? { capture?["remote"] as? [String: Any] }
        var local: [String: Any]? { capture?["local"] as? [String: Any] }
        var stamp: [String: Any]? { metadata["capture_provenance"] as? [String: Any] }
        var captureLine: String? { SummaryPromptBuilder.captureLine(summaryMetadata) }
        var userMessage: String { SummaryPromptBuilder.userMessage(metadata: summaryMetadata, segments: []) }
        var systemMessage: String { SummaryPromptBuilder.systemMessage(metadata: summaryMetadata) }
        var hasBanner: Bool { summaryMarkdown.hasPrefix("> ⚠️ This summary covers only what was captured:") }
    }

    static let bothSides: [ProcessedChunk.Segment] = [
        .init(start: 1, end: 4, text: "Can you all hear me?", speaker: "Local Speaker 1", source: "local"),
        .init(start: 5, end: 9, text: "Yes, loud and clear.", speaker: "Remote Speaker 1", source: "remote"),
    ]
    static let localOnly: [ProcessedChunk.Segment] = [
        .init(start: 1, end: 4, text: "Can you all hear me?", speaker: "Local Speaker 1", source: "local"),
    ]

    private func run(helper: [CaptureEvent], gaps: [CaptureGap] = [],
                     segments: [ProcessedChunk.Segment]? = nil) async throws -> Record {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Helper ring → `drainDiagnostics` (AudioCaptureService.swift:728) → app ring
        // (`AudioCaptureClient.drainHelperDiagnostics`) → `finalizeSessionDiagnostics`' provenance.
        let helperRing = LockedDiagnostics()
        helper.forEach(helperRing.record)
        var appRing = CaptureDiagnostics()
        let drained = CaptureDiagnostics.events(from: helperRing.drainData())
        #expect(drained.count == helper.count, "the XPC drain carries every helper event")
        if !drained.isEmpty { appRing.merge(drained) }
        let provenance = appRing.makeProvenance(engine: "fluid_audio", systemFormat: "48000Hz/1ch",
                                                micFormat: "48000Hz/1ch", micDevice: "MacBook Pro Microphone")

        // session.json round trip, then the real finalize.
        let chunk = ProcessedChunk(index: 0, startTime: H.base, audioPath: "weekly-sync-0.m4a", segments: segments ?? Self.bothSides,
                                   speakerDatabase: ["Remote Speaker 1": [1, 0, 0]],
                                   localSpeakerDatabase: ["Local Speaker 1": [0, 1, 0]], isDualStream: true)
        try SessionState.write(SessionState(sessionId: "weekly-sync", meetingStart: H.base, engine: "fluid_audio",
                                            chunkDurationMinutes: 10, chunks: [chunk], provenance: provenance, gaps: gaps),
                               directory: dir)
        let persisted = try #require(SessionState.read(directory: dir, sessionId: "weekly-sync"))
        let result = try await TranscriptionRunner().finalize(sessionState: persisted, outputDirectory: dir, config: .default)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        let metadata = try #require(root["metadata"] as? [String: Any])

        let provider = IntegrationCapturingProvider()
        try await MeetingSummarizer.summarize(transcriptPath: result.jsonPath, provider: provider, endpoint: "http://127.0.0.1:1234/v1")
        let summary = try String(contentsOf: dir.appendingPathComponent("weekly-sync-summary.md"), encoding: .utf8)
        let title = Self.completionTitle(transcriptAt: result.jsonPath)
        return Record(provenance: provenance, metadata: metadata, summaryMetadata: try #require(provider.metadata),
                      summaryMarkdown: summary, completionTitle: title)
    }

    /// The notice exactly as `RecordingCoordinator.presentCompletedTranscription` builds it: the three
    /// counts read back off the transcript, then the three-argument title.
    nonisolated static func completionTitle(transcriptAt url: URL) -> String {
        CaptureQualityNotice.completionTitle(anomalyCount: CaptureQualityNotice.anomalyCount(inTranscriptAt: url),
                                             problemChunkCount: CaptureQualityNotice.problemChunkCount(inTranscriptAt: url),
                                             segmentCount: CaptureQualityNotice.segmentCount(inTranscriptAt: url))
    }

    /// (a) Both sides healthy — including a benign AirPods route change the #86 restart healed — says
    /// nothing: no header line, no banner, a plain "Transcription Complete".
    @Test func bothSidesHealthyStateNothing() async throws {
        let r = try await run(helper: [
            H.event(.captureStart, .info, at: 0, ["mic": "MacBook Pro Microphone"]),
            H.event(.streamStopError, .anomaly, at: 40, ["source": "system"]),
            H.event(.restartInPlace, .warning, at: 41, ["source": "system"]),
            H.captureStop(at: 3600, remote: H.side(expected: 3600, delivered: 3598.5, zeros: 240, callbacks: 360_000),
                          local: H.side(expected: 3600, delivered: 3599.9, callbacks: 360_000)),
        ])
        #expect(r.provenance.remoteStatus == "healthy" && r.provenance.localStatus == "healthy")
        #expect(r.remote?["status"] as? String == "healthy" && r.local?["status"] as? String == "healthy")
        #expect(r.remote?["expected_seconds"] as? Double == 3600 && r.remote?["delivered_seconds"] as? Double == 3598.5)
        #expect(r.stamp?["quality_anomaly_count"] as? Int == 0 && r.stamp?["anomaly_count"] as? Int == 1)
        #expect(r.stamp?["route_changes"] as? Int == 1)
        #expect(r.metadata["dual_stream"] as? Bool == true)
        #expect(r.captureLine == nil)
        #expect(!r.userMessage.contains("Remote audio") && !r.userMessage.contains("Your microphone"))
        #expect(r.systemMessage.contains("Dual-Stream Audio Context"), "both sides captured: the echo hint stays")
        #expect(!r.hasBanner && r.summaryMarkdown.hasPrefix("### Summary"))
        #expect(r.completionTitle == "Transcription Complete")
    }

    /// (b) Incident B: the tap was expected for the whole 2736 s call and delivered nothing. The ladder
    /// gave up (`systemAudioUnrecovered`). The record and the summary say "not captured" with the
    /// spec's exact numbers (§7.3), and the echo hint is withdrawn.
    @Test func incidentBNeverDeliveredSaysNotCaptured() async throws {
        let r = try await run(helper: [
            H.event(.captureStart, .info, at: 0),
            H.event(.neverDelivered, .anomaly, at: 5, ["track": "system", "seconds": "5"]),
            H.event(.tapRecoveryRung, .warning, at: 5, ["rung": "rebuildAggregate", "token": "1", "delay": "0.0", "total": "1"]),
            H.event(.tapRecoveryGivenUp, .anomaly, at: 20, ["rebuilds": "4"]),
            H.event(.alarmRaised, .anomaly, at: 20, ["kind": "remoteNotDelivering"]),
            H.event(.systemAudioUnrecovered, .anomaly, at: 20, ["source": "system-tap", "reason": "healing ladder gave up"]),
            H.captureStop(at: 2736, remote: H.side(expected: 2736, delivered: 0, callbacks: 0, rebuilds: 4),
                          local: H.side(expected: 2736, delivered: 2736, callbacks: 273_600)),
        ], segments: Self.localOnly)
        #expect(r.provenance.remoteStatus == "neverDelivered" && r.provenance.systemAudioUnrecovered)
        #expect(r.remote?["status"] as? String == "neverDelivered")
        #expect(r.remote?["delivered_seconds"] as? Double == 0 && r.remote?["expected_seconds"] as? Double == 2736)
        #expect(r.stamp?["system_audio_unrecovered"] as? Bool == true)
        #expect(r.metadata["dual_stream"] as? Bool == true, "dual_stream is the capture-time flag, not 'did remote speak'")
        #expect(r.captureLine == "Remote audio: not captured (0 s delivered of 2736 s expected)")
        #expect(r.userMessage.contains("\nRemote audio: not captured (0 s delivered of 2736 s expected)\n"))
        #expect(!r.systemMessage.contains("Dual-Stream Audio Context"), "no remote audio to compare echo against")
        #expect(r.summaryMarkdown.hasPrefix("""
            > ⚠️ This summary covers only what was captured:
            > Remote audio: not captured (0 s delivered of 2736 s expected)


            """))
        #expect(r.completionTitle == "Transcription Complete — capture anomalies")
    }

    /// (c) #220: a full-length tap of exact zeros while TCC CONFIRMS the permission is not granted
    /// (denied, or never answered). The real permission guard produces the denial events; the record
    /// and the summary say "not granted".
    @Test(arguments: [PermissionStatus.denied, .notDetermined])
    func confirmedDenialSaysNotGranted(_ tcc: PermissionStatus) async throws {
        let guardRun = H.permissionGuardRun(builtWith: tcc, tcc: tcc, seconds: 80)
        #expect(guardRun.events.filter { $0.kind == .systemAudioPermissionDenied }.count == 2, "reported, then re-reported after 60 s")
        #expect(guardRun.events.allSatisfy { $0.detail["status"] == SystemAudioRecordingPermission.wireValue(tcc) })
        let r = try await run(helper: [H.event(.captureStart, .info, at: 0)] + guardRun.events + [
            H.captureStop(at: 3120, remote: H.side(expected: 3120, delivered: 3120, zeros: 3120, callbacks: 312_000),
                          local: H.side(expected: 3120, delivered: 3120, callbacks: 312_000)),
        ], segments: Self.localOnly)
        #expect(r.provenance.systemPermissionDeniedConfirmed && r.provenance.remoteStatus == "compromised")
        #expect(r.stamp?["system_permission_denied_confirmed"] as? Bool == true)
        #expect(r.remote?["status"] as? String == "compromised" && r.remote?["exact_zero_seconds"] as? Double == 3120)
        #expect(r.captureLine == "Remote audio: not captured — system audio permission was not granted; 3120 s of digital silence were recorded instead")
        #expect(r.hasBanner && r.summaryMarkdown.contains("> Remote audio: not captured — system audio permission was not granted"))
        #expect(!r.systemMessage.contains("Dual-Stream Audio Context"))
        #expect(r.completionTitle == "Transcription Complete — capture anomalies")
    }

    /// (d) The same full-length exact zeros, but TCC cannot answer (the private SPI is gone): the guard
    /// reports "unconfirmed" and the summary says "uncertain" — never "not granted", never healthy.
    @Test func unconfirmedPermissionSaysUncertain() async throws {
        let guardRun = H.permissionGuardRun(builtWith: nil, tcc: nil, seconds: 40)
        #expect(guardRun.events.map(\.kind) == [.systemAudioPermissionDenied] && guardRun.events.first?.detail["status"] == "unconfirmed")
        #expect(guardRun.rebuilds.isEmpty, "an unverifiable permission never triggers a rebuild")
        let r = try await run(helper: [H.event(.captureStart, .info, at: 0)] + guardRun.events + [
            H.captureStop(at: 3120, remote: H.side(expected: 3120, delivered: 3120, zeros: 3120, callbacks: 312_000),
                          local: H.side(expected: 3120, delivered: 3120, callbacks: 312_000)),
        ], segments: Self.localOnly)
        #expect(!r.provenance.systemPermissionDeniedConfirmed && r.provenance.remoteStatus == "compromised")
        #expect(r.stamp?["system_permission_denied_confirmed"] as? Bool == false)
        #expect(r.captureLine == "Remote audio: uncertain — 3120 s were exact digital silence and Parley could not confirm the permission; the other side may have been muted, or not captured")
        #expect(r.hasBanner && !r.summaryMarkdown.contains("not granted"))
    }

    /// (e) The owner's no-false-positive case: headphones, the remote side muted, frames flowing, every
    /// sample exact zero, and TCC confirms the permission is GRANTED. The guard spends its one insurance
    /// rebuild through the real healer and then stays quiet. Nothing may say anything is wrong: the
    /// summary header gets one neutral, informational line (A-I2 ruling) — no banner, no failure word.
    @Test func grantedMutedRemoteRaisesNothing() async throws {
        let guardRun = H.permissionGuardRun(builtWith: .authorized, tcc: .authorized, seconds: 40)
        #expect(guardRun.rebuilds == [.insurance], "one insurance rebuild per episode, never a loop")
        #expect(guardRun.healerAlarmCalls == 0, "the insurance rebuild healed; no give-up, no stuck rung")
        #expect(!guardRun.events.contains { $0.severity == .anomaly }, "only the rung's own warning is recorded")
        let r = try await run(helper: [H.event(.captureStart, .info, at: 0)] + guardRun.events + [
            H.captureStop(at: 600, remote: H.side(expected: 600, delivered: 600, zeros: 600, callbacks: 60_000, rebuilds: 1),
                          local: H.side(expected: 600, delivered: 600, callbacks: 60_000)),
        ])
        #expect(r.provenance.remoteStatus == "healthy" && !r.provenance.systemPermissionDeniedConfirmed)
        #expect(r.remote?["status"] as? String == "healthy" && r.remote?["exact_zero_seconds"] as? Double == 600)
        #expect(r.stamp?["quality_anomaly_count"] as? Int == 0 && r.stamp?["system_audio_unrecovered"] as? Bool == false)
        #expect(r.captureLine == "Remote audio: only digital silence was received (the other side may have been muted)")
        #expect(!r.userMessage.contains("not captured") && !r.userMessage.contains("uncertain") && !r.userMessage.contains("compromised"))
        #expect(!r.hasBanner && r.summaryMarkdown.hasPrefix("### Summary"))
        #expect(r.completionTitle == "Transcription Complete")
    }

    /// (c′) #220's real shape (C-I2): the permission was revoked mid-call — 1740 s of a 3120 s remote
    /// side are exact zeros after it, the first 1380 s really captured. The record says "partly
    /// captured … while system audio permission was not granted", never "not captured" for the whole.
    @Test func aMidCallDenialSaysPartlyCaptured() async throws {
        let guardRun = H.permissionGuardRun(builtWith: .authorized, tcc: .denied, seconds: 80)
        #expect(guardRun.events.contains { $0.kind == .systemAudioPermissionDenied && $0.detail["status"] == "denied" })
        let r = try await run(helper: [H.event(.captureStart, .info, at: 0)] + guardRun.events + [
            H.captureStop(at: 3120, remote: H.side(expected: 3120, delivered: 3120, zeros: 1740, callbacks: 312_000),
                          local: H.side(expected: 3120, delivered: 3120, callbacks: 312_000)),
        ])
        #expect(r.provenance.systemPermissionDeniedConfirmed && r.provenance.remoteStatus == "compromised")
        let line = "Remote audio: partly captured — 1740 s of 3120 s was digital silence; system audio permission was not granted for part of the call"
        #expect(r.captureLine == line)
        #expect(r.hasBanner && r.summaryMarkdown.contains("> \(line)"))
        #expect(!r.userMessage.contains("Remote audio: not captured"))
        #expect(r.systemMessage.contains("Dual-Stream Audio Context"), "part of the remote side is real audio")
        #expect(r.completionTitle == "Transcription Complete — capture anomalies")
    }

    /// (f) The mic went to exact digital zero 5 minutes into a 60-minute call (lid closed, #193): the
    /// record says how much of it was silence — never "only digital silence", since those first 5
    /// minutes DID record the user.
    @Test func micSilentAfterFiveMinutesSaysPartialSilence() async throws {
        let r = try await run(helper: [
            H.event(.captureStart, .info, at: 0),
            H.event(.exactZeroMic, .anomaly, at: 312, ["seconds": "12"]),   // AudioOutputHandler.swift:610
            H.event(.alarmRaised, .anomaly, at: 312, ["kind": "micDigitalSilence"]),
            H.captureStop(at: 3600, remote: H.side(expected: 3600, delivered: 3600, zeros: 60, callbacks: 360_000),
                          local: H.side(expected: 3600, delivered: 3600, zeros: 3300, callbacks: 360_000)),
        ])
        #expect(r.provenance.localStatus == "compromised" && r.provenance.remoteStatus == "healthy")
        #expect(r.local?["content_anomaly_count"] as? Int == 1 && r.remote?["content_anomaly_count"] as? Int == 0)
        #expect(r.captureLine == "Your microphone: captured, but 3300 s of 3600 s was digital silence (1 capture anomaly recorded)")
        #expect(r.hasBanner && r.summaryMarkdown.contains("> Your microphone: captured, but 3300 s of 3600 s was digital silence"))
        #expect(r.systemMessage.contains("Dual-Stream Audio Context"), "the remote side is intact")
    }

    /// (f, second shape) The mic STOPPED delivering 5 minutes in (no heartbeat): a coverage deficit, so
    /// "partly captured" with the real numbers.
    @Test func micStoppedAfterFiveMinutesSaysPartlyCaptured() async throws {
        let r = try await run(helper: [
            H.event(.captureStart, .info, at: 0),
            H.event(.livenessGap, .anomaly, at: 303, ["track": "mic", "seconds": "3"]),
            H.captureStop(at: 3600, remote: H.side(expected: 3600, delivered: 3600, callbacks: 360_000),
                          local: H.side(expected: 3600, delivered: 300, callbacks: 30_000, longestGap: 3300, gaps: 1)),
        ])
        #expect(r.provenance.localStatus == "compromised")
        #expect(r.captureLine == "Your microphone: partly captured (300 s delivered of 3600 s expected)")
        #expect(r.hasBanner)
    }

    /// (g) The app relaunched mid-call: two helper sessions (coverage summed across both `captureStop`s)
    /// and a 185.4 s `CaptureGap` in session.json. Both sides are otherwise healthy, so the gap is the
    /// only thing said — and it is said in the banner.
    @Test func recordedCaptureGapSaysGaps() async throws {
        let gap = CaptureGap(start: H.at(600), end: H.at(785.4), reason: "app relaunch")
        let r = try await run(helper: [
            H.event(.captureStart, .info, at: 0),
            H.captureStop(at: 600, remote: H.side(expected: 600, delivered: 598, callbacks: 60_000),
                          local: H.side(expected: 600, delivered: 600, callbacks: 60_000)),
            H.event(.captureStart, .info, at: 786),
            H.captureStop(at: 1986, remote: H.side(expected: 1200, delivered: 1199, callbacks: 120_000),
                          local: H.side(expected: 1200, delivered: 1200, callbacks: 120_000)),
        ], gaps: [gap])
        #expect(r.provenance.remoteCoverage?.expectedSeconds == 1800 && r.provenance.remoteCoverage?.deliveredSeconds == 1797)
        #expect(r.provenance.localCoverage?.expectedSeconds == 1800)
        let gaps = try #require(r.capture?["gaps"] as? [[String: Any]])
        #expect(gaps.count == 1 && gaps.first?["reason"] as? String == "app relaunch")
        #expect(abs((gaps.first?["seconds"] as? Double ?? 0) - 185.4) < 0.001, "the precise length survives session.json")
        #expect(r.summaryMetadata.gapCount == 1)
        #expect(r.captureLine == "Recording gaps: 1 (total 3 min 5 s)")
        #expect(r.summaryMarkdown.hasPrefix("""
            > ⚠️ This summary covers only what was captured:
            > Recording gaps: 1 (total 3 min 5 s)


            """))
    }

    /// An SCK (legacy) session: the helper deliberately OMITS `remote_exact_zero_seconds` and
    /// `remote_heartbeat_callbacks` ("say nothing rather than 0", AudioCaptureService.swift:246-250). The
    /// record must keep them unmeasured, not turn them into a measured 0.
    @Test func sckSessionKeepsUnmeasuredRemoteKeysAbsent() async throws {
        let r = try await run(helper: [
            H.event(.captureStart, .info, at: 0),
            H.captureStop(at: 600, remote: H.side(expected: 600, delivered: 600), local: H.side(expected: 600, delivered: 600, callbacks: 60_000),
                          tap: false),
        ])
        #expect(r.remote?["exact_zero_seconds"] == nil, "SCK never measured exact zeros")
        #expect(r.remote?["heartbeat_callbacks"] == nil, "SCK never counted tap callbacks")
        #expect(r.stamp?["system_exact_zero_seconds"] == nil)
        let stampedRemote = r.stamp?["remote_coverage"] as? [String: Any]
        #expect(stampedRemote != nil && stampedRemote?["exact_zero_seconds"] == nil && stampedRemote?["heartbeat_callbacks"] == nil,
                "capture_provenance.remote_coverage omits them too")
        #expect(r.summaryMetadata.remoteCapture?.exactZeroSeconds == nil)
        #expect(r.remote?["delivered_seconds"] as? Double == 600 && r.remote?["status"] as? String == "healthy", "what WAS measured stays")
        #expect(r.local?["exact_zero_seconds"] as? Double == 0 && r.local?["heartbeat_callbacks"] as? Int == 60_000,
                "the mic measured both: a measured 0 stays a 0")
        #expect(r.captureLine == nil)
    }
}

// MARK: - Chain 2: eviction + crash-merge → provenance

/// A small ring, many events and a retry; then `LiveDiagnosticsLog.merged(into:)`. `retries` and
/// `events_dropped` stay exact, and each side's status still comes from the out-of-ring tallies even
/// though every piece of evidence has left the ring.
@Suite struct CaptureRecordIntegrationEvictionTests {
    /// Real `Date()`-shaped timestamps: sub-millisecond, so the disk round trip is exercised.
    static let t0: TimeInterval = 811_968_756.9166

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("xi-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func event(_ i: Int, _ kind: CaptureEventKind, _ severity: CaptureEvent.Severity,
                       _ detail: [String: String] = [:], origin: CaptureEvent.Origin = .helper) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSinceReferenceDate: Self.t0 + Double(i) * 0.2503),
                     origin: origin, kind: kind, severity: severity, detail: detail)
    }

    private func stop(_ i: Int) -> CaptureEvent {
        let remote = HelperShaped.side(expected: 1800, delivered: 1792, zeros: 12, callbacks: 180_000)
        let local = HelperShaped.side(expected: 1800, delivered: 1800, callbacks: 180_000)
        return CaptureEvent(timestamp: Date(timeIntervalSinceReferenceDate: Self.t0 + Double(i) * 0.2503), origin: .helper,
                            kind: .captureStop, severity: .info,
                            detail: remote.asDetail(prefix: "remote").merging(local.asDetail(prefix: "local")) { a, _ in a })
    }

    /// The session's story: a rate drift on the remote side, a retry, a flood of warnings, the stop's
    /// coverage, and more warnings after it. 24 events through a 6-event ring.
    private func session() -> [CaptureEvent] {
        var events = [
            event(0, .captureStart, .info),
            event(1, .rateDrift, .anomaly, ["source": "system-tap", "ratio": "0.919"]),
            event(2, .retry, .warning, ["attempt": "1"], origin: .app),
        ]
        for i in 3..<15 { events.append(event(i, .tapRecoveryRung, .warning, ["rung": "rebuildAggregate", "token": "\(i)"])) }
        events.append(stop(15))
        for i in 16..<24 { events.append(event(i, .restartInPlace, .warning, ["source": "mic", "n": "\(i)"])) }
        return events
    }

    private func assemble(_ p: CaptureProvenance) -> [String: Any] {
        TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "json", language: "en", numSpeakers: nil,
                                     diarization: false, dualStream: true, provenance: p)["metadata"] as? [String: Any] ?? [:]
    }

    @Test func evictionThenLiveLogMergeKeepsRetriesDropsAndStatusExact() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "weekly-sync")
        var ring = CaptureDiagnostics(maxEvents: 6)
        let events = session()
        for e in events { ring.record(e); log.append(e) }   // every event to both, as the app records them

        #expect(ring.events.count == 6 && ring.droppedCount == events.count - 6)
        #expect(!ring.events.contains { [.rateDrift, .retry, .captureStop].contains($0.kind) }, "all the evidence has left the ring")
        #expect(log.events().count == events.count - 1,
                "info events are not written to the live log — except the stop, which carries coverage (L11)")

        let merged = log.merged(into: ring)
        let again = log.merged(into: merged)   // a second finalize over the same log
        for m in [merged, again] {
            let p = m.makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil)
            #expect(p.retries == 1, "the evicted retry, re-presented from disk, is still one retry")
            #expect(p.eventsDropped == events.count - 6, "re-evicting the same events at merge is not a new drop")
            #expect(p.remoteStatus == "compromised" && p.remoteContentAnomalyCount == 1, "the evicted rate drift still compromises the remote side, once")
            #expect(p.localStatus == "healthy" && p.localContentAnomalyCount == 0)
            #expect(p.remoteCoverage?.expectedSeconds == 1800 && p.remoteCoverage?.deliveredSeconds == 1792, "coverage from the out-of-ring tally, not doubled")
            #expect(p.systemExactZeroSeconds == 12)

            let metadata = assemble(p)
            let stamp = metadata["capture_provenance"] as? [String: Any]
            #expect(stamp?["retries"] as? Int == 1 && stamp?["events_dropped"] as? Int == events.count - 6)
            let remote = (metadata["capture"] as? [String: Any])?["remote"] as? [String: Any]
            #expect(remote?["status"] as? String == "compromised" && remote?["content_anomaly_count"] as? Int == 1)
        }
    }

    /// The app crashed mid-meeting: its ring died with it. The relaunched app's fresh (small) ring holds
    /// only what came after; the live log holds every pre-crash anomaly and warning. The merge counts
    /// each pre-crash retry and anomaly exactly once and admits exactly what the ring cannot hold.
    @Test func crashMergeCountsPreCrashEvidenceOnce() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "weekly-sync")
        var dead = CaptureDiagnostics(maxEvents: 6)   // process 1's ring: it dies with the crash, only the log survives
        let before = session().filter { $0.kind != .captureStop }   // the crash came before any stop
        for e in before { dead.record(e); log.append(e) }

        var relaunched = CaptureDiagnostics(maxEvents: 6)
        let after = [
            event(40, .launchRecovery, .warning, ["flow": "A"], origin: .app),
            event(41, .retry, .warning, ["attempt": "2"], origin: .app),
            event(42, .captureStart, .info),
            stop(43),
        ]
        for e in after { relaunched.record(e); log.append(e) }
        #expect(relaunched.droppedCount == 0 && relaunched.retryCount == 1)

        let merged = log.merged(into: relaunched)
        let p = merged.makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil)
        let written = before.filter { $0.severity != .info }.count   // what process 1 left on disk
        #expect(p.retries == 2, "one retry before the crash, one after")
        #expect(p.recovered)
        #expect(p.eventsDropped == written + after.count - 6, "everything the merged ring cannot hold, counted once")
        #expect(p.remoteStatus == "compromised" && p.remoteContentAnomalyCount == 1, "the pre-crash rate drift, evicted during the merge itself, still counts")
        #expect(p.localStatus == "healthy")
        #expect(log.merged(into: merged).makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil) == p,
                "merging the same log again changes nothing")
    }

    /// The same eviction, seen by the two provenance fields the user-facing notice reads. They were
    /// computed by scanning the ring (`qualityAnomalyCount`, `systemAudioUnrecovered`), so once the
    /// evidence had left the ring the stamp contradicted its own `remote_status`; they are now counted
    /// out of ring, once per event, like the side tallies.
    @Test func evictedQualityEvidenceStillReachesTheCompletionNotice() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "weekly-sync")
        var ring = CaptureDiagnostics(maxEvents: 6)
        var events = session()
        events.insert(event(2, .systemAudioUnrecovered, .anomaly, ["source": "system-tap", "reason": "healing ladder gave up"]), at: 3)
        for e in events { ring.record(e); log.append(e) }
        let p = log.merged(into: ring).makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteStatus == "compromised")
        #expect(p.systemAudioUnrecovered, "the ladder gave up on the remote side; eviction does not undo that")
        #expect(p.qualityAnomalyCount == 2, "a rate drift and an unrecovered remote stream were recorded — once each")
        #expect(p.anomalyCount >= p.qualityAnomalyCount, "the superset never drops below the subset")

        let url = d.appendingPathComponent("weekly-sync.json")
        try TranscriptAssembler.write(["metadata": assemble(p), "segments": [["start": 0.0, "end": 2.0, "speaker": "Remote Speaker 1", "text": "hello"]]], to: url)
        #expect(CaptureRecordIntegrationCoverageToSummaryTests.completionTitle(transcriptAt: url) == "Transcription Complete — capture anomalies")
    }
}

// MARK: - Chain 3: alarm evidence (helper registry → snapshot wire → app registry)

/// The helper's registry, the `CaptureStatusSnapshot` JSON wire, and the app's registry. `AppState`
/// holds no registry yet (`activeAlarms` is task L2, not merged), so the app side here is the
/// `CaptureAlarmRegistry` instance `AppState` will own.
@Suite struct CaptureRecordIntegrationAlarmEvidenceTests {
    static let helperA = "1790000000000-0"
    static let helperB = "1790000060000-0"
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// Helper side: build the snapshot, encode it; app side: decode it and apply it.
    private func deliver(_ helper: CaptureAlarmRegistry, id: String, sequence: UInt64, to app: inout CaptureAlarmRegistry) throws {
        let wire = CaptureStatusSnapshot(helperSessionId: id, sequence: sequence, isCapturing: true, alarms: helper.sorted, tracks: [
            TrackHealthSnapshot(track: .system, expected: true, heartbeatAgeSeconds: 0.2, generation: 1),
            TrackHealthSnapshot(track: .mic, expected: true, heartbeatAgeSeconds: 0.1, generation: 1),
        ]).encoded()
        app.apply(try #require(CaptureStatusSnapshot.decode(wire)))
    }

    @Test func permissionAlarmOutlivesNewHelperFirstFramesAndClearsOnRealAudio() throws {
        // Helper A: the tap runs without the permission, and a grant rebuild threw.
        var a = CaptureAlarmRegistry()
        a.raise(.remotePermissionDenied, message: "Parley isn’t allowed to record system audio…", now: t0)
        a.raise(.remoteRecoveryFailed, message: "Parley could not restart system-audio capture…", now: t0.addingTimeInterval(4))
        var app = CaptureAlarmRegistry()
        try deliver(a, id: Self.helperA, sequence: 1, to: &app)
        #expect(Set(app.alarms.keys) == [.remotePermissionDenied, .remoteRecoveryFailed])

        // Helper A crashes; helper B starts with an empty registry. Its tap delivers first frames —
        // on time, and (with the permission still missing) all zeros.
        let b = CaptureAlarmRegistry()
        app.noteFirstFrames(track: .system, helperSessionId: Self.helperB)
        #expect(app.helperSessionId?.description == Self.helperB)
        #expect(app.alarms[.remoteRecoveryFailed] == nil, "first frames disprove a delivery alarm")
        #expect(app.alarms[.remotePermissionDenied] != nil, "first frames cannot disprove a permission alarm: a denied tap delivers zeros on time")
        #expect(app.staleKinds == [.remotePermissionDenied])

        // B's pulls (connect, then the 5 s poll) carry no alarm: the stale one stays, with its raisedAt.
        try deliver(b, id: Self.helperB, sequence: 1, to: &app)
        try deliver(b, id: Self.helperB, sequence: 2, to: &app)
        #expect(app.alarms[.remotePermissionDenied]?.raisedAt == t0)
        // Real audio on the OTHER track proves nothing about the remote side.
        app.noteRealAudio(track: .mic, helperSessionId: Self.helperB)
        #expect(app.alarms[.remotePermissionDenied] != nil)

        // Real (non-zero) remote audio from B: the permission problem is gone.
        app.noteRealAudio(track: .system, helperSessionId: Self.helperB)
        #expect(app.isEmpty && app.staleKinds.isEmpty)
    }

    @Test func aStaleHelpersLateSnapshotAndEvidenceAreRejected() throws {
        var a = CaptureAlarmRegistry()
        a.raise(.remotePermissionDenied, message: "denied", now: t0)
        var app = CaptureAlarmRegistry()
        try deliver(a, id: Self.helperA, sequence: 1, to: &app)

        // B takes over and reports its own alarm.
        var b = CaptureAlarmRegistry()
        b.raise(.micDigitalSilence, message: "mic silent", now: t0.addingTimeInterval(70))
        try deliver(b, id: Self.helperB, sequence: 1, to: &app)
        let settled = app

        // A's late push arrives after B took over — a newer sequence, an all-clear, then a new alarm.
        try deliver(CaptureAlarmRegistry(), id: Self.helperA, sequence: 9, to: &app)
        #expect(app == settled, "an all-clear from the replaced helper clears nothing")
        var aLate = CaptureAlarmRegistry()
        aLate.raise(.remoteNotDelivering, message: "late", now: t0.addingTimeInterval(80))
        try deliver(aLate, id: Self.helperA, sequence: 10, to: &app)
        #expect(app == settled, "a late alarm from the replaced helper raises nothing")
        // …and A's late real-audio evidence cannot clear the alarm it left behind either.
        app.noteRealAudio(track: .system, helperSessionId: Self.helperA)
        #expect(app == settled && app.helperSessionId?.description == Self.helperB)

        // Within B: a pull reply overtaken by a newer push is ignored too.
        try deliver(CaptureAlarmRegistry(), id: Self.helperB, sequence: 1, to: &app)
        #expect(app.alarms[.micDigitalSilence] != nil, "an older same-helper snapshot cannot clear a newer alarm")
    }
}

// MARK: - Chain 4: healing ladder → alarms

/// `TrackLivenessMonitor` (1 Hz, gate open) → `TapHealer` + `TapRecoveryLadder` on virtual time →
/// the helper's alarm registry and diagnostic ring. The glue between them lives in the helper
/// executable, so it is mirrored here from `AudioCaptureService`: `handleLiveness` /
/// `handleTapLiveness` (:303-380), `raiseAlarm` / `clearAlarm` (:263-279), `wireTapHealer` (:1018-1049)
/// and the tap's `onGenerationChanged` re-arm (:989).
@Suite struct CaptureRecordIntegrationHealingTests {
    final class Rig {
        let clock = TapHealerTests.ManualScheduler()
        let healer: TapHealer
        let tap = TapHealerTests.FakeTap()
        var monitor = TrackLivenessMonitor(track: CaptureTrack.system.rawValue)
        var alarms = CaptureAlarmRegistry()
        var diagnostics = CaptureDiagnostics()
        /// Whether the tap's IOProc is being called; flips off at the stall, on at a successful rebuild.
        var delivering = true
        /// A successful rebuild brings the IOProc back (`delivering = true`); false: rebuilds succeed and
        /// nothing ever arrives (Incident B).
        var rebuildRestoresDelivery = true
        /// The output-activity gate (`LivenessWatchdogDriver.lastGateOpen`): the monitor's tick reads it, and
        /// so does the healer at a rung's heartbeat deadline (`wireTapHealer`, final review H-I1).
        var gateOpen = true
        var lastHeartbeat: UInt64 = 0
        /// `rebuild(rung:token:)` outcome: true = rebuilt, false = threw, nil = never returns (stuck).
        var rebuildOutcome: (TapRecoveryLadder.Rung, Int) -> Bool? = { _, _ in false }
        var answered = 0
        /// `stopCapture`: `isUserStopping` (raiseAlarm is a no-op) and the watchdog stops.
        var stopped = false
        var giveUps: [Bool] = []
        var stuck = 0, recovered = 0, rungSucceeded = 0
        var newlyRaised: [AlarmKind] = []

        init() {
            healer = TapHealer(scheduler: clock)
            // wireTapHealer (:1018-1049)
            healer.onEvent = { [unowned self] kind, severity, detail in self.record(kind, severity, detail) }
            healer.onGiveUp = { [unowned self] rebuildFailed in
                self.giveUps.append(rebuildFailed)
                // The helper's own decision (`TapHealer.giveUpAlarms`), on the gate it reads (HF-9).
                let kinds = TapHealer.giveUpAlarms(rebuildFailed: rebuildFailed, gateOpen: self.gateOpen)
                if kinds.contains(.remoteNotDelivering),
                   self.raise(.remoteNotDelivering, "The other side of the call isn’t reaching Parley although audio is playing.") {
                    self.record(.systemAudioUnrecovered, .anomaly, ["source": "system-tap", "reason": "healing ladder gave up"])
                }
                if kinds.contains(.remoteRecoveryFailed) { self.raise(.remoteRecoveryFailed, "Parley could not restart system-audio capture.") }
            }
            healer.onRecovered = { [unowned self] in self.recovered += 1; self.clear(.remoteNotDelivering) }
            healer.onStuck = { [unowned self] in self.stuck += 1; self.raise(.remoteRecoveryFailed, "Parley could not restart system-audio capture.") }
            healer.onRungSucceeded = { [unowned self] in self.rungSucceeded += 1; self.clear(.remoteRecoveryFailed) }
            healer.gateOpen = { [unowned self] in self.gateOpen }
            healer.startSession(tap: tap)
            monitor.arm(nowNanos: 0)
        }

        var nowNanos: UInt64 { UInt64((clock.now * 1e9).rounded()) }

        func record(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, _ detail: [String: String] = [:]) {
            diagnostics.record(CaptureEvent(timestamp: HelperShaped.at(clock.now), origin: .helper, kind: kind, severity: severity, detail: detail))
        }

        @discardableResult
        func raise(_ kind: AlarmKind, _ message: String) -> Bool {
            guard !stopped, alarms.raise(kind, message: message, now: HelperShaped.at(clock.now)) else { return false }
            newlyRaised.append(kind)
            record(.alarmRaised, .anomaly, ["kind": kind.rawValue])
            return true
        }

        func clear(_ kind: AlarmKind) {
            guard alarms.clear(kind) != nil else { return }
            record(.alarmCleared, .info, ["kind": kind.rawValue])
        }

        /// The 1 Hz watchdog tick → `handleLiveness` → `handleTapLiveness`.
        func tick() {
            guard !stopped else { return }
            let verdict = monitor.check(nowNanos: nowNanos, lastHeartbeatNanos: lastHeartbeat, gateOpen: gateOpen)
            switch verdict {
            case .firstFrames:
                record(.firstFrames, .info, ["track": "system"])
                healer.heartbeatObserved()
                clear(.remoteNotDelivering)
                clear(.remoteRecoveryFailed)
            case .neverDelivered(let s):
                record(.neverDelivered, .anomaly, ["track": "system", "seconds": "\(Int(s))"])
                healer.trigger(.neverDelivered)
            case .stalled(let s):
                record(.livenessGap, .anomaly, ["track": "system", "seconds": "\(Int(s))"])
                healer.trigger(.stalled)
            case .cleared(.heartbeat):
                record(.livenessRecovered, .info, ["track": "system", "reason": "heartbeat"])
                healer.heartbeatObserved()
            case .cleared(.gateClosed):
                record(.livenessRecovered, .info, ["track": "system", "reason": "gateClosed"])
                healer.gateClosed()
                clear(.remoteNotDelivering)
            case .healthy:
                break
            }
        }

        /// Virtual time in 0.25 s steps: the IOProc stamps its heartbeat, the tap answers the rungs it
        /// was handed, and the watchdog ticks on whole seconds.
        func run(until end: Double, stallAt: Double? = nil) {
            while clock.now < end {
                clock.advance(by: 0.25)
                if let stallAt, clock.now >= stallAt, clock.now < stallAt + 0.25 { delivering = false }
                if delivering { lastHeartbeat = nowNanos }
                while answered < tap.rebuilds.count {
                    let rung = tap.rebuilds[answered]
                    answered += 1
                    guard let ok = rebuildOutcome(rung.rung, rung.token) else { continue }
                    healer.rebuildResult(rung: rung.rung, token: rung.token, succeeded: ok)
                    if ok {
                        monitor.arm(nowNanos: nowNanos)   // SystemTapSession.onGenerationChanged
                        if rebuildRestoresDelivery { delivering = true }
                    }
                }
                if clock.now.truncatingRemainder(dividingBy: 1) == 0 { tick() }
            }
        }

        func count(_ kind: CaptureEventKind) -> Int { diagnostics.events.filter { $0.kind == kind }.count }
    }

    /// Incident A: the tap stalls 10 s in with the call app's output running. Every rung throws; the
    /// fast ladder gives up ONCE, raising `remoteNotDelivering` + `remoteRecoveryFailed` and recording
    /// `systemAudioUnrecovered`. The slow retries that keep failing afterwards never re-raise or
    /// re-record anything.
    @Test func stallWithTheGateOpenClimbsTheLadderAndAlarmsOnce() {
        let r = Rig()
        r.run(until: 40, stallAt: 10)
        #expect(r.count(.livenessGap) == 1, "one stall episode")
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate, .rebuildAggregate, .rebuildTap, .rebuildTap])
        #expect(r.giveUps == [true], "the fast ladder gives up exactly once, knowing a rebuild threw")
        #expect(r.newlyRaised == [.remoteNotDelivering, .remoteRecoveryFailed])
        #expect(r.count(.systemAudioUnrecovered) == 1)

        r.run(until: 240)   // three slow retries, each throwing
        #expect(r.tap.rebuilds.count == 7)
        #expect(r.giveUps.count == 4, "each failed slow retry reports its give-up to the helper…")
        #expect(r.newlyRaised == [.remoteNotDelivering, .remoteRecoveryFailed], "…which raises nothing new")
        #expect(r.alarms.alarms[.remoteRecoveryFailed]?.episode == 1 && r.alarms.alarms[.remoteNotDelivering]?.episode == 1)
        #expect(r.count(.systemAudioUnrecovered) == 1, "one unrecovered remote stream, not one per retry")
        #expect(r.stuck == 0 && r.recovered == 0)
        let p = r.diagnostics.makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.systemAudioUnrecovered && p.qualityAnomalyCount > 0)
    }

    /// The first rung rebuilds the aggregate, the IOProc is called again within the heartbeat deadline:
    /// healed before the ladder gave up, so no alarm is raised and nothing is recorded as unrecovered.
    @Test func aHealBeforeGiveUpRaisesNoAlarm() {
        let r = Rig()
        r.rebuildOutcome = { _, _ in true }
        r.run(until: 200, stallAt: 10)
        #expect(r.tap.rebuilds.count == 1 && r.rungSucceeded == 1)
        #expect(r.recovered == 1 && r.count(.firstFrames) == 2, "the rebuilt generation's first frames end the silence")
        #expect(r.giveUps.isEmpty && r.stuck == 0)
        #expect(r.newlyRaised.isEmpty && r.alarms.isEmpty)
        #expect(r.count(.systemAudioUnrecovered) == 0 && r.count(.tapRecoveryGivenUp) == 0)
        let p = r.diagnostics.makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(!p.systemAudioUnrecovered)
    }

    /// Incident B end to end (final review E-I2): the tap never delivers from t = 0 while the call plays.
    /// Every rebuild "succeeds" and nothing ever arrives. The monitor says never-delivered at 5 s, the
    /// ladder climbs its four rungs and gives up ONCE — `remoteNotDelivering` only, no rebuild threw — and
    /// the slow retry after it raises nothing new. The record says not captured, and unrecovered.
    @Test func neverDeliveredFromStartClimbsTheLadderAndAlarmsOnce() {
        let r = Rig()
        r.delivering = false
        r.rebuildRestoresDelivery = false
        r.rebuildOutcome = { _, _ in true }
        r.run(until: 30)
        let at = HelperShaped.at
        // Judged 5 s after the start. The second verdict is the re-armed monitor's on the LAST rung's
        // generation (rebuilt at 16 s), which the exhausted ladder ignores: recorded, never re-raised.
        let neverDelivered = r.diagnostics.events.filter { $0.kind == .neverDelivered }.map(\.timestamp)
        #expect(neverDelivered == [at(5), at(21)])
        #expect(r.diagnostics.events.filter { $0.kind == .tapRecoveryRung }.map { $0.detail["rung"] }
                == ["rebuildAggregate", "rebuildAggregate", "rebuildTap", "rebuildTap"])
        let givenUp = r.diagnostics.events.filter { $0.kind == .tapRecoveryGivenUp }.map(\.timestamp)
        #expect(givenUp.count == 1 && givenUp[0] <= at(25))
        #expect(r.newlyRaised == [.remoteNotDelivering])
        #expect(r.alarms.alarms[.remoteNotDelivering]?.episode == 1)
        #expect(r.giveUps == [false], "no rebuild threw: not delivering, never 'could not restart'")
        #expect(r.count(.systemAudioUnrecovered) == 1)

        r.run(until: 100)
        #expect(r.count(.tapRecoveryRung) == 5, "the 60 s slow retry")
        #expect(r.giveUps == [false, false] && r.newlyRaised.count == 1, "which gives up again and raises nothing new")
        #expect(r.count(.neverDelivered) == 3 && r.count(.systemAudioUnrecovered) == 1)

        // The record, as `incidentBNeverDeliveredSaysNotCaptured` builds it: the helper's ring and its
        // `captureStop` through the XPC drain into the app's ring, then the provenance.
        let helperRing = LockedDiagnostics()
        ([HelperShaped.event(.captureStart, .info, at: 0)] + r.diagnostics.events + [
            HelperShaped.captureStop(at: 100, remote: HelperShaped.side(expected: 100, delivered: 0, rebuilds: 5),
                                     local: HelperShaped.side(expected: 100, delivered: 100, callbacks: 10_000)),
        ]).forEach(helperRing.record)
        var appRing = CaptureDiagnostics()
        appRing.merge(CaptureDiagnostics.events(from: helperRing.drainData()))
        let p = appRing.makeProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteStatus == "neverDelivered" && p.systemAudioUnrecovered)
    }

    /// Final review H-I1, mirrored through the chain: recording started before the call, and the grant
    /// rebuilds the tap while nothing plays. Nothing is expected, so the rung's deadline climbs nothing and
    /// nothing is raised; when the call starts, the rebuilt tap's first frames are heard.
    @Test func aGrantRungWithTheGateClosedRaisesNothing() {
        let r = Rig()
        r.delivering = false
        r.gateOpen = false
        r.rebuildOutcome = { _, _ in true }
        r.healer.trigger(.permissionGrant)
        r.run(until: 30)
        #expect(r.newlyRaised.isEmpty && r.giveUps.isEmpty)
        #expect(r.tap.rebuilds.count == 1, "the grant's one rebuild; the closed gate climbed nothing")
        r.gateOpen = true
        r.delivering = true
        r.run(until: 40)
        #expect(r.newlyRaised.isEmpty && r.giveUps.isEmpty)
        #expect(r.count(.firstFrames) == 1)
        #expect(r.recovered == 0, "nothing was healing")
    }

    /// Final review HF-9: a coreaudiod restart at pre-call idle whose rebuilds all throw (coreaudiod still
    /// coming up). "Could not restart" is raised, and it clears when the 60 s slow retry rebuilds; "isn't
    /// reaching Parley although audio is playing" is never raised — nothing at idle (no heartbeat, no gate
    /// verdict) would clear it. With audio playing, the same failure still raises both.
    @Test func anIdleGiveUpAfterThrowingRebuildsNeverClaimsAudioIsPlaying() {
        let r = Rig()
        r.delivering = false
        r.gateOpen = false
        r.rebuildOutcome = { _, _ in false }
        r.healer.trigger(.serviceRestarted)
        r.run(until: 30)
        #expect(r.giveUps == [true])
        #expect(r.newlyRaised == [.remoteRecoveryFailed])
        #expect(r.count(.systemAudioUnrecovered) == 0, "nothing expected was lost")
        r.rebuildOutcome = { _, _ in true }   // coreaudiod is back: the slow retry rebuilds
        r.run(until: 100)
        #expect(r.rungSucceeded == 1 && r.alarms.isEmpty, "no row left up at idle")

        let playing = Rig()
        playing.delivering = false
        playing.rebuildOutcome = { _, _ in false }
        playing.healer.trigger(.serviceRestarted)
        playing.run(until: 30)
        #expect(playing.giveUps == [true])
        #expect(playing.newlyRaised == [.remoteNotDelivering, .remoteRecoveryFailed])
        #expect(playing.count(.systemAudioUnrecovered) == 1)
    }

    /// Stop while a rung is in flight (it never returns — a HAL call blocked on a paused context):
    /// `endSession()` must leave nothing behind. No stuck watchdog, no next rung, no slow retry, and a
    /// late verdict or a late rebuild result from the stopped session does nothing.
    @Test func stopMidHealFiresNothingAfterwards() {
        let r = Rig()
        r.rebuildOutcome = { _, token in token == 1 ? false : nil }   // rung 2 hangs
        r.run(until: 14, stallAt: 10)
        #expect(r.tap.rebuilds.count == 2 && r.giveUps.isEmpty && r.stuck == 0, "stopped mid-heal: rung 2 in flight")
        let eventsAtStop = r.diagnostics.events.count

        r.stopped = true           // stopCapture: isUserStopping, livenessWatchdog.stop()
        r.healer.endSession()      // stopCapture (:571)
        r.run(until: 400)
        r.healer.trigger(.stalled)                                        // a verdict already in flight
        r.healer.rebuildResult(rung: .rebuildAggregate, token: 2, succeeded: false)   // rung 2 finally returns
        r.clock.advance(by: 120)

        #expect(r.tap.rebuilds.count == 2, "no rung after stop")
        #expect(r.giveUps.isEmpty && r.stuck == 0 && r.recovered == 0 && r.rungSucceeded == 0, "no callback after stop")
        #expect(r.diagnostics.events.count == eventsAtStop, "no event after stop")
        #expect(r.alarms.isEmpty && r.clock.pending == 0)
    }
}
