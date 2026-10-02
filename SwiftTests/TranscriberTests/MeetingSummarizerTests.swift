import Testing
import Foundation
@testable import TranscriberCore

struct MeetingSummarizerTests {

    private struct MockProvider: SummaryProvider {
        let response: String
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            response
        }
    }

    private struct FailingProvider: SummaryProvider {
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            throw SummaryError.requestFailed("network error")
        }
    }

    private struct InvalidEndpointProvider: SummaryProvider {
        let endpoint: String
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            throw SummaryError.invalidEndpoint(endpoint)
        }
    }


    @Test func summarizeWritesMarkdownFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": [
                "audio_files": ["test.m4a"],
                "output_format": "txt",
                "language": "en",
                "diarization": true,
                "dual_stream": false
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Ship it by Friday"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("meeting-2026.json")
        try jsonData.write(to: jsonPath)

        let provider = MockProvider(response: "## Executive Summary\nA productive meeting.")
        try await MeetingSummarizer.summarize(
            transcriptPath: jsonPath,
            provider: provider,
            endpoint: "http://localhost:1234"
        )

        let summaryPath = dir.appendingPathComponent("meeting-2026-summary.md")
        #expect(FileManager.default.fileExists(atPath: summaryPath.path))
        let content = try String(contentsOf: summaryPath, encoding: .utf8)
        #expect(content.contains("Executive Summary"))
    }

    @Test func summarizeStampsSourceTranscriptFilename() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["dual_stream": false] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Ship it"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("meeting-2026.json")
        try jsonData.write(to: jsonPath)

        let provider = MockProvider(response: "### Summary\nA productive meeting.")
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider, endpoint: "http://localhost:1234")

        let summaryPath = dir.appendingPathComponent("meeting-2026-summary.md")
        let content = try String(contentsOf: summaryPath, encoding: .utf8)
        // Provenance is stamped deterministically (not left to the LLM) so an
        // agent can trace the notes back to the exact transcript file.
        #expect(content.contains("meeting-2026.json"))
        #expect(content.contains("Source transcript"))
        // Model output is preserved alongside the stamp.
        #expect(content.contains("A productive meeting."))
    }

    @Test func summarizeExtractsSegmentsAndMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": [
                "audio_files": ["test.m4a"],
                "output_format": "txt",
                "language": "en",
                "diarization": true,
                "dual_stream": false
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "First point"] as [String: Any],
                ["start": 5.0, "end": 15.0, "speaker": "Bob", "text": "Second point"] as [String: Any],
                ["start": 15.0, "end": 20.0, "speaker": "Alice", "text": "Wrap up"] as [String: Any],
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("standup.json")
        try jsonData.write(to: jsonPath)

        var receivedSegments: [SummarySegment] = []
        var receivedMetadata: SummaryMetadata?
        let provider = CapturingProvider { segments, metadata in
            receivedSegments = segments
            receivedMetadata = metadata
            return "## Summary"
        }
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider, endpoint: "http://localhost:1234")

        #expect(receivedSegments.count == 3)
        #expect(receivedSegments[0].speaker == "Alice")
        #expect(receivedSegments[1].text == "Second point")
        #expect(receivedMetadata?.speakers == ["Alice", "Bob"])
        #expect(receivedMetadata?.sessionName == "standup")
        #expect(receivedMetadata?.durationSeconds == 20.0)
    }

    @Test func summarizeThrowsOnProviderFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["audio_files": [], "output_format": "txt", "language": "en",
                         "diarization": false, "dual_stream": false] as [String: Any],
            "segments": [
                ["start": 0, "end": 1, "speaker": "A", "text": "hi"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("test.json")
        try jsonData.write(to: jsonPath)

        let provider = FailingProvider()
        await #expect(throws: SummaryError.self) {
            try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider, endpoint: "http://localhost:1234")
        }

        let summaryPath = dir.appendingPathComponent("test-summary.md")
        #expect(!FileManager.default.fileExists(atPath: summaryPath.path))
    }

    // MARK: - #134 summarizeIfConfigured outcome reporting

    // A failed summary must be reported (so the caller can notify the user) with the underlying
    // message — not swallowed silently as it was before #134.
    @Test func runSummaryReportsFailureWithMessage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["dual_stream": false] as [String: Any],
            "segments": [["start": 0.0, "end": 1.0, "speaker": "A", "text": "hi"] as [String: Any]]
        ]
        let jsonPath = dir.appendingPathComponent("test.json")
        try JSONSerialization.data(withJSONObject: transcript).write(to: jsonPath)

        let outcome = await MeetingSummarizer.runSummary(transcriptPath: jsonPath, provider: FailingProvider(), endpoint: "http://localhost:1234")

        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("network error"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("test-summary.md").path))
    }

    @Test func runSummaryReportsSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["dual_stream": false] as [String: Any],
            "segments": [["start": 0.0, "end": 1.0, "speaker": "A", "text": "hi"] as [String: Any]]
        ]
        let jsonPath = dir.appendingPathComponent("test.json")
        try JSONSerialization.data(withJSONObject: transcript).write(to: jsonPath)

        let outcome = await MeetingSummarizer.runSummary(
            transcriptPath: jsonPath, provider: MockProvider(response: "## Summary\nok"), endpoint: "http://localhost:1234")

        #expect(outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("test-summary.md").path))
    }

    // A non-SummaryError (file read/write) must not leak the transcript/session filename into the
    // user-visible message — it reports a generic, actionable message instead. The detail stays in
    // the (local) log. Here the transcript is missing, so parseTranscript's read throws a CocoaError
    // whose description embeds the filename.
    @Test func runSummaryGivesGenericMessageForFileError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Deliberately NOT created — the sensitive name must not reach the user-visible message.
        let jsonPath = dir.appendingPathComponent("Q3-Revenue-Review.json")

        let outcome = await MeetingSummarizer.runSummary(
            transcriptPath: jsonPath, provider: MockProvider(response: "ok"), endpoint: "http://localhost:1234")

        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!message.contains("Q3-Revenue-Review"))
    }

    // Integration: an enabled config flows through createProvider(from:) into runSummary and a
    // failure is reported as .failed (not swallowed). Guards against a createProvider regression
    // that the provider-injected runSummary tests wouldn't catch.
    @Test func summarizeIfConfiguredReportsFailureWhenProviderFails() async {
        var config = Config.default
        config.summary = SummaryConfig(enabled: true, endpoint: "http://127.0.0.1:1234", model: "m")
        // Nonexistent transcript → parseTranscript throws → runSummary returns .failed (no network).
        // Explicit fake Keychain (#48): summarizeIfConfigured now looks up the API key before
        // building the provider, and this must never touch the real macOS Keychain in a test.
        let outcome = await MeetingSummarizer.summarizeIfConfigured(
            transcriptPath: URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).json"),
            config: config, keychain: FakeKeychainStore())
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test func summarizeIfConfiguredSkipsWhenNotConfigured() async {
        var config = Config.default
        config.summary = nil
        let outcome = await MeetingSummarizer.summarizeIfConfigured(
            transcriptPath: URL(fileURLWithPath: "/tmp/unused.json"), config: config, keychain: FakeKeychainStore())
        #expect(outcome == .skipped)
    }

    @Test func summarizeIfConfiguredSkipsWhenDisabled() async {
        var config = Config.default
        config.summary = SummaryConfig(enabled: false, endpoint: "http://127.0.0.1:1234", model: "m")
        let outcome = await MeetingSummarizer.summarizeIfConfigured(
            transcriptPath: URL(fileURLWithPath: "/tmp/unused.json"), config: config, keychain: FakeKeychainStore())
        #expect(outcome == .skipped)
    }

    // The endpoint URL can carry a token in some proxies (e.g. Cloudflare AI Gateway); the
    // user-visible failure message (shown as a notification, possibly during a screen-share) must
    // NOT echo it.
    @Test func runSummaryReportsInvalidEndpointWithSanitisedMessage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["dual_stream": false] as [String: Any],
            "segments": [["start": 0.0, "end": 1.0, "speaker": "A", "text": "hi"] as [String: Any]]
        ]
        let jsonPath = dir.appendingPathComponent("test.json")
        try JSONSerialization.data(withJSONObject: transcript).write(to: jsonPath)

        let provider = InvalidEndpointProvider(endpoint: "https://gateway.example/v1/secret-token-123/openai")
        let outcome = await MeetingSummarizer.runSummary(transcriptPath: jsonPath, provider: provider, endpoint: "http://localhost:1234")

        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!message.contains("secret-token-123"))
    }

    @Test func summarizeIfConfiguredSkipsWhenEndpointEmpty() async {
        var config = Config.default
        config.summary = SummaryConfig(enabled: true, endpoint: "", model: "m")
        let outcome = await MeetingSummarizer.summarizeIfConfigured(
            transcriptPath: URL(fileURLWithPath: "/tmp/unused.json"), config: config, keychain: FakeKeychainStore())
        #expect(outcome == .skipped)
    }

    // MARK: - SummarySegment / SummaryMetadata v0.7.x fields

    @Test func summarySegmentDefaultSource() {
        let seg = SummarySegment(start: 0, end: 1, speaker: "Alice", text: "hello")
        #expect(seg.source == "")
    }

    @Test func summaryMetadataDefaultDualStreamFields() {
        let meta = SummaryMetadata(sessionName: "test", date: Date(), durationSeconds: 60, speakers: ["A"])
        #expect(meta.dualStream == false)
        #expect(meta.echoSegmentsFlagged == 0)
    }

    @Test func summaryMetadataRecordsDualStreamFields() {
        let meta = SummaryMetadata(
            sessionName: "test", date: Date(), durationSeconds: 120, speakers: ["A", "B"],
            dualStream: true, echoSegmentsFlagged: 5
        )
        #expect(meta.dualStream == true)
        #expect(meta.echoSegmentsFlagged == 5)
    }

    @Test func summarizePopulatesDualStreamFromJSON() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": [
                "dual_stream": true,
                "echo_segments_removed": 7
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Hi", "source": "local"] as [String: Any],
                ["start": 5.0, "end": 10.0, "speaker": "Bob", "text": "Hello", "source": "remote"] as [String: Any],
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("dual.json")
        try jsonData.write(to: jsonPath)

        var capturedMeta: SummaryMetadata?
        var capturedSegs: [SummarySegment] = []
        let provider = CapturingProvider { segments, metadata in
            capturedSegs = segments
            capturedMeta = metadata
            return "## Summary"
        }
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider, endpoint: "http://localhost:1234")

        #expect(capturedMeta?.dualStream == true)
        #expect(capturedMeta?.echoSegmentsFlagged == 7)
        #expect(capturedSegs[0].source == "local")
        #expect(capturedSegs[1].source == "remote")
    }

    // MARK: - Recording-start date sourcing (#49)

    @Test func summaryDatedToRecordedAtMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A recording from well in the past, summarized "now".
        let recordedAt = Date(timeIntervalSince1970: 1_600_000_000)  // 2020-09-13
        let iso = ISO8601DateFormatter().string(from: recordedAt)

        let transcript: [String: Any] = [
            "metadata": ["dual_stream": false, "recorded_at": iso] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Hi"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("meeting.json")
        try jsonData.write(to: jsonPath)

        var captured: SummaryMetadata?
        let provider = CapturingProvider { _, metadata in
            captured = metadata
            return "## Summary"
        }
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider, endpoint: "http://localhost:1234")

        // The summary is dated by when the meeting was recorded, not when it was summarized.
        #expect(abs((captured?.date ?? Date()).timeIntervalSince(recordedAt)) < 1)
    }

    @Test func summaryFallsBackToFileDateWhenNoRecordedAt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["dual_stream": false] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Hi"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("meeting.json")
        try jsonData.write(to: jsonPath)

        // No recorded_at → resolve from the file's own creation/modification date, which is ~now.
        let resolved = MeetingSummarizer.resolveRecordingDate(
            metadata: ["dual_stream": false], transcriptPath: jsonPath
        )
        #expect(abs(resolved.timeIntervalSinceNow) < 60)
    }

    @Test func resolveRecordingDatePrefersMetadataOverFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsonPath = dir.appendingPathComponent("x.json")
        try Data("{}".utf8).write(to: jsonPath)

        let recordedAt = Date(timeIntervalSince1970: 1_500_000_000)
        let iso = ISO8601DateFormatter().string(from: recordedAt)
        let resolved = MeetingSummarizer.resolveRecordingDate(
            metadata: ["recorded_at": iso], transcriptPath: jsonPath
        )
        #expect(abs(resolved.timeIntervalSince(recordedAt)) < 1)
    }

    @Test func truncatedSummaryGetsABannerFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("m.json")
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "A"]]]).write(to: transcript)
        try await MeetingSummarizer.summarize(transcriptPath: transcript, provider: TruncatingProvider(), endpoint: "http://localhost")
        let md = try String(contentsOf: dir.appendingPathComponent("m-summary.md"), encoding: .utf8)
        #expect(md.hasPrefix("> ⚠️ This summary may be incomplete"))
        #expect(md.contains("# Summary\ncut"))
    }

    @Test func flaggedSegmentsAreExcludedFromTheSummaryInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flags-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [
            ["start": 0.0, "end": 1.0, "text": "keep", "speaker": "A"],
            ["start": 1.0, "end": 2.0, "text": "drop", "speaker": "B", "echo": true],
            ["start": 2.0, "end": 3.0, "text": "drop", "speaker": "Unknown", "filtered": true],
        ]]).write(to: url)
        let (segments, _) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(segments.map(\.text) == ["keep"])
    }

    /// #231: the reader takes the count from `echo_segments_flagged`, and from the old
    /// `echo_segments_removed` in a transcript written before the rename.
    @Test func readsTheEchoCountFromTheNewKeyAndFallsBackToTheOldOne() throws {
        func count(_ metadata: [String: Any]) throws -> Int {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": [] as [Any]]).write(to: url)
            return try MeetingSummarizer.parseTranscriptForTesting(at: url).1.echoSegmentsFlagged
        }
        #expect(try count(["echo_segments_flagged": 36]) == 36)
        #expect(try count(["echo_segments_removed": 7]) == 7, "a transcript written before the rename")
        #expect(try count(["echo_segments_flagged": 36, "echo_segments_removed": 7]) == 36, "the new key wins")
        #expect(try count([:]) == 0)
    }

    @Test func parsesCaptureCoverageFromMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["capture": ["remote": ["status": "neverDelivered", "delivered_seconds": 0.0, "expected_seconds": 2736.0]]],
            "segments": [] as [Any],
        ]).write(to: url)
        let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(meta.remoteCapture == CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 2736))
        #expect(meta.localCapture == nil)
    }

    /// R1 review round 1 item 2: the capture banner is written by Parley, not left to the model.
    @Test func theCaptureBannerLeadsTheSummaryEvenWhenTheModelIgnoresTheRule() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("m.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["capture": ["remote": ["status": "neverDelivered", "delivered_seconds": 0.0, "expected_seconds": 2736.0]]],
            "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "A"]],
        ]).write(to: transcript)
        try await MeetingSummarizer.summarize(transcriptPath: transcript, provider: MockProvider(response: "# Summary\nAll fine."), endpoint: "http://localhost")
        let md = try String(contentsOf: dir.appendingPathComponent("m-summary.md"), encoding: .utf8)
        #expect(md.hasPrefix("> ⚠️"))
        #expect(md.contains("Remote audio: not captured (0 s delivered of 2736 s expected)"))
        #expect(md.contains("# Summary\nAll fine."))
    }

    @Test func parsesPermissionAnomaliesGapsAndMissingCoverage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "capture": [
                    "remote": ["status": "compromised", "delivered_seconds": 2736.0, "expected_seconds": 2736.0, "exact_zero_seconds": 2736.0,
                               "content_anomaly_count": 1],
                    "gaps": [["seconds": 120.0, "reason": "sleep"], ["seconds": 70.0, "reason": "app relaunch"]],
                ] as [String: Any],
                // The session-wide count is NOT the side's: round 4 reads the per-side one.
                "capture_provenance": ["system_permission_denied_confirmed": true, "system_audio_unrecovered": true, "quality_anomaly_count": 7],
            ],
            "segments": [] as [Any],
        ]).write(to: url)
        let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(meta.remoteCapture == CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736,
                                                      exactZeroSeconds: 2736, permissionDenied: true, anomalyCount: 1))
        #expect(meta.gapCount == 2 && meta.gapSeconds == 190)
        #expect(!meta.coverageNotRecorded)

        try JSONSerialization.data(withJSONObject: ["metadata": ["processing_issues": [] as [Any]], "segments": [] as [Any]]).write(to: url)
        #expect(try MeetingSummarizer.parseTranscriptForTesting(at: url).1.coverageNotRecorded)
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [] as [Any]]).write(to: url)
        #expect(try !MeetingSummarizer.parseTranscriptForTesting(at: url).1.coverageNotRecorded, "an untracked transcript says nothing")
    }

    /// assemble → write → parse → header: the wording the model sees comes from what was stamped.
    @Test func captureWordingSurvivesTheFullRoundTrip() throws {
        var remote = TrackAccounting(); remote.expectedSeconds = 2736; remote.deliveredSeconds = 2736; remote.exactZeroSeconds = 2736
        let provenance = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                           recovered: false, anomalyCount: 1, qualityAnomalyCount: 1, systemAudioUnrecovered: true,
                                           remoteCoverage: remote, remoteStatus: "compromised", systemPermissionDeniedConfirmed: true)
        let json = TranscriptAssembler.assemble(
            segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil, diarization: false, dualStream: true,
            provenance: provenance,
            captureGaps: [CaptureGap(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 120), reason: "sleep")],
            processingIssues: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptAssembler.write(json, to: url)
        let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        let line = try #require(SummaryPromptBuilder.captureLine(meta))
        #expect(line.contains("Remote audio: not captured — system audio permission was not granted; 2736 s of digital silence were recorded instead"))
        #expect(line.contains("Recording gaps: 1 (total 2 min 0 s)"))
    }

    /// Round 3 item 6: only the CONFIRMED-denial field says "permission denied"; the older
    /// `system_audio_unrecovered` (also set by a failed restart) does not.
    @Test func permissionDeniedComesOnlyFromTheConfirmedField() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func parse(_ provenance: [String: Any]) throws -> CaptureSideNote? {
            try JSONSerialization.data(withJSONObject: [
                "metadata": ["capture": ["remote": ["status": "compromised", "delivered_seconds": 60.0, "expected_seconds": 60.0, "exact_zero_seconds": 60.0]],
                             "capture_provenance": provenance],
                "segments": [] as [Any],
            ]).write(to: url)
            return try MeetingSummarizer.parseTranscriptForTesting(at: url).1.remoteCapture
        }
        #expect(try parse(["system_audio_unrecovered": true])?.permissionDenied == nil)
        #expect(try parse(["system_audio_unrecovered": true, "system_permission_denied_confirmed": false])?.permissionDenied == false)
        #expect(try parse(["system_permission_denied_confirmed": true])?.permissionDenied == true)
    }
}

private struct TruncatingProvider: SummaryProvider {
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String { "# Summary\ncut" }
    func summarizeDetailed(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> SummaryResponse {
        SummaryResponse(markdown: "# Summary\ncut", truncated: true)
    }
}

private final class CapturingProvider: SummaryProvider, @unchecked Sendable {
    private let handler: ([SummarySegment], SummaryMetadata) -> String
    init(handler: @escaping ([SummarySegment], SummaryMetadata) -> String) {
        self.handler = handler
    }
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        handler(segments, metadata)
    }
}

/// C-I6 (R2 council): the disclosure was stamped only after a summary was written, so a request
/// that timed out AFTER the transcript left the machine kept `transcript_transmitted: false`.
struct MeetingSummarizerDisclosureTests {
    private func transcript() throws -> (dir: URL, path: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("disclosure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("meeting.json")
        try TranscriptAssembler.write(TranscriptAssembler.assemble(
            segments: [LabeledSegment(start: 0, end: 2, speaker: "Alice", text: "Ship it Friday", source: "")], audioPaths: [],
            outputFormat: "json", language: "en", numSpeakers: nil, diarization: false, dualStream: false), to: path)
        return (dir, path)
    }

    private func disclosure(_ path: URL) throws -> [String: Any] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        return try #require((json["metadata"] as? [String: Any])?["disclosure"] as? [String: Any])
    }

    private final class Probe: SummaryProvider, @unchecked Sendable {
        let path: URL
        let failure: (any Error)?
        var seen: [String: Any]?
        init(path: URL, failure: (any Error)? = nil) { self.path = path; self.failure = failure }
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
            seen = (json?["metadata"] as? [String: Any])?["disclosure"] as? [String: Any]
            if let failure { throw failure }
            return "### Summary\nDone."
        }
    }

    /// The record says "sent" before the request goes, not after an answer comes back.
    @Test func theAttemptIsStampedBeforeTheRequestLeaves() async throws {
        let (dir, path) = try transcript(); defer { try? FileManager.default.removeItem(at: dir) }
        let probe = Probe(path: path)
        try await MeetingSummarizer.summarize(transcriptPath: path, provider: probe, endpoint: "https://api.example.com/v1")
        #expect(probe.seen?["transcript_transmitted"] as? Bool == true)
        #expect(probe.seen?["transcript_transmitted_to"] as? [String] == ["remote (api.example.com)"])
        #expect(probe.seen?["summary_generated"] as? Bool == false)
        #expect(probe.seen?["summary_endpoint"] == nil, "nothing has generated a summary yet")
        let final = try disclosure(path)
        #expect(final["summary_generated"] as? Bool == true && final["transcript_transmitted"] as? Bool == true)
        #expect(final["summary_endpoint"] as? String == "remote (api.example.com)")
    }

    /// A timeout after sending (the documented -1001 case) must never leave `false`.
    @Test func aFailureAfterSendingLeavesTheTransmissionOnRecord() async throws {
        let (dir, path) = try transcript(); defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await MeetingSummarizer.runSummary(transcriptPath: path, provider: Probe(path: path, failure: URLError(.timedOut)),
                                                         endpoint: "https://api.example.com/v1")
        guard case .failed = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        let d = try disclosure(path)
        #expect(d["transcript_transmitted"] as? Bool == true)
        #expect(d["transcript_transmitted_to"] as? [String] == ["remote (api.example.com)"])
        #expect(d["summary_generated"] as? Bool == false)
        #expect(d["summary_endpoint"] == nil, "no summary was generated")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-summary.md").path))
    }

    /// A later summary on this Mac never clears an earlier transmission from the record — and the two
    /// facts are recorded apart (R2b item 6): where the transcript was SENT, and which endpoint
    /// GENERATED the current summary.
    @Test func aLaterLocalSummaryNeverClearsAnEarlierTransmission() async throws {
        let (dir, path) = try transcript(); defer { try? FileManager.default.removeItem(at: dir) }
        try await MeetingSummarizer.summarize(transcriptPath: path, provider: Probe(path: path), endpoint: "https://api.example.com/v1")
        _ = await MeetingSummarizer.runSummary(transcriptPath: path, provider: Probe(path: path, failure: URLError(.timedOut)),
                                               endpoint: "http://127.0.0.1:1234")
        try await MeetingSummarizer.summarize(transcriptPath: path, provider: Probe(path: path), endpoint: "http://127.0.0.1:1234")
        let d = try disclosure(path)
        #expect(d["transcript_transmitted"] as? Bool == true, "it was sent once; that stays on record")
        #expect(d["transcript_transmitted_to"] as? [String] == ["remote (api.example.com)"], "where it was sent")
        #expect(d["summary_generated"] as? Bool == true)
        #expect(d["summary_endpoint"] as? String == "local (127.0.0.1:1234)", "the endpoint that generated the summary on disk")
        try await MeetingSummarizer.summarize(transcriptPath: path, provider: Probe(path: path), endpoint: "https://llm.example.org/v1")
        #expect(try disclosure(path)["transcript_transmitted_to"] as? [String] == ["remote (api.example.com)", "remote (llm.example.org)"],
                "every host, once each, in order")
    }

    /// Local only: attempted, never transmitted, and the endpoint is named.
    @Test func aLocalAttemptIsRecordedAsNotTransmitted() async throws {
        let (dir, path) = try transcript(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = await MeetingSummarizer.runSummary(transcriptPath: path, provider: Probe(path: path, failure: URLError(.timedOut)),
                                               endpoint: "http://127.0.0.1:1234")
        let d = try disclosure(path)
        #expect(d["transcript_transmitted"] as? Bool == false && d["summary_generated"] as? Bool == false)
        #expect(d["transcript_transmitted_to"] as? [String] == [])
        #expect(d["summary_endpoint"] == nil)
    }
}

/// R2b item 5: a segment with no usable time was fed to the model at 00:00:00 (and could make the
/// meeting 0 s long). It is left out of the summary input, and the summary says so.
struct MeetingSummarizerTimelessSegmentTests {
    @Test func aSegmentWithoutATimeIsLeftOutAndSaidSo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeless-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json: [String: Any] = ["metadata": ["dual_stream": false] as [String: Any], "segments": [
            ["start": 1.0, "end": 60.0, "speaker": "Alice", "text": "timed"],
            ["start": NSNull(), "end": NSNull(), "speaker": "Alice", "text": "lost in time", "time_unknown": true],
        ]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let (segments, metadata) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(segments.map(\.text) == ["timed"])
        #expect(metadata.untimedSegmentCount == 1)
        #expect(metadata.durationSeconds == 60, "the last segment has no time: the duration is the latest real end")
        let line = "Transcript: 1 segment has no recorded time and was left out of this summary"
        #expect(SummaryPromptBuilder.captureLine(metadata) == line)
        #expect(SummaryPromptBuilder.captureBanner(metadata)?.contains("> \(line)") == true)
    }
}

/// Round 3 item 5: the lower-bound mark is read off the transcript.
struct MeetingSummarizerLowerBoundTests {
    @Test func theLowerBoundMarkIsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lower-bound-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let remote: [String: Any] = ["status": "compromised", "expected_seconds": 600.0, "delivered_seconds": 600.0,
                                     "exact_zero_seconds": 300.0, "exact_zero_seconds_is_lower_bound": true]
        let json: [String: Any] = ["metadata": ["capture": ["remote": remote]], "segments": [["start": 0.0, "end": 1.0, "speaker": "A", "text": "hi"]]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let (_, metadata) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(metadata.remoteCapture?.exactZeroIsLowerBound == true)
    }
}

/// Round 4 item 6: every rewrite of a finalized transcript is durable — the marker must never vouch
/// for a transcript a power loss can take back.
struct TranscriptRewritesAreDurableTests {
    @Test func renamesAndDisclosuresAreFullySynced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("durable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.json")
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any],
            "segments": [["start": 0.0, "end": 1.0, "speaker": "Remote Speaker 1", "text": "hi"]]]).write(to: url)
        DurableFile.startRecordingSyncsForTesting(under: dir)
        defer { DurableFile.stopRecordingSyncsForTesting(under: dir) }
        let before = DurableFile.syncedForTesting.count
        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Alice"], jsonPath: url))
        try MeetingSummarizer.stampDisclosure(.attempted(endpoint: "http://127.0.0.1:1"), into: url)
        #expect(DurableFile.syncedForTesting.dropFirst(before).filter { $0 == url.path }.count == 2)
    }
}

/// Round 6 item 4: a rebuilt record's capture facts come from the recovery run. The summary header
/// carries that caveat.
struct MeetingSummarizerReconstructedTests {
    @Test func aReconstructedRecordSaysSoInTheHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reconstructed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let provenance = CaptureProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil,
                                           routeChanges: 0, retries: 0, recovered: true, anomalyCount: 0).markedReconstructed()
        try TranscriptAssembler.write(TranscriptAssembler.assemble(
            segments: [LabeledSegment(start: 0, end: 1, speaker: "A", text: "hi", source: "")], audioPaths: [], outputFormat: "json",
            language: "en", numSpeakers: nil, diarization: false, dualStream: false, provenance: provenance), to: url)
        let (_, metadata) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(metadata.captureReconstructed)
        #expect(SummaryPromptBuilder.captureLine(metadata)?.contains("Capture facts were reconstructed after a crash and may be incomplete") == true)
        // Round 7 item 6: in the deterministic banner, never on the strength of a model obeying.
        #expect(SummaryPromptBuilder.captureBanner(metadata)?.contains("> Capture facts were reconstructed after a crash and may be incomplete") == true)
        #expect(SummaryPromptBuilder.captureLine(SummaryMetadata(sessionName: "s", date: Date(), durationSeconds: 1, speakers: [])) == nil,
                "no caveat for a record that was not rebuilt")
    }
}


/// #269: the summary's participant list is people only. A real summary opened with "Participants:
/// A, B, Local Unknown, and Local Speaker 2" — the last two being lines nobody could be tied to and
/// the other side's voice through the loudspeakers. Synthetic labels and text only.
struct MeetingSummarizerParticipantsTests {

    private let you = "Local Speaker 1", echo = "Local Speaker 2", them = "Remote Speaker 1"

    /// A speaker-mode call: the user, the other side, and the other side's voice found as a second
    /// speaker on the microphone — one of its lines matched and flagged, one left visible.
    private func call(echoSpeaker: String = "Local Speaker 2") -> [[String: Any]] {
        [
            ["start": 0.0, "end": 4.0, "speaker": them, "source": "remote", "text": "the budget is approved"],
            ["start": 0.5, "end": 4.5, "speaker": echoSpeaker, "source": "local", "text": "the budget is approved", "echo": true],
            ["start": 5.0, "end": 8.0, "speaker": you, "source": "local", "text": "good news"],
            ["start": 9.0, "end": 12.0, "speaker": echoSpeaker, "source": "local", "text": "half of both voices"],
        ]
    }

    private func line(_ speaker: String, _ source: String, _ text: String, at start: Double = 20) -> [String: Any] {
        ["start": start, "end": start + 2, "speaker": speaker, "source": source, "text": text]
    }

    /// One `metadata.echo_clusters` entry, as `EchoDeduplicator.ClusterVerdict.metadataDictionary` writes it.
    private func cluster(_ label: String, _ verdict: String = "echo") -> [String: Any] {
        ["label": label, "verdict": verdict, "track": "local", "chunk": 0, "segments": 2, "matched_segments": 1,
         "seconds": 7.0, "matched_seconds": 4.0, "matched_remote": [them: 4.0]]
    }

    private func parse(_ segments: [[String: Any]], _ extra: [String: Any]) throws -> ([SummarySegment], SummaryMetadata) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("participants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = extra.merging(["dual_stream": true, "recorded_at": "2026-01-05T10:00:00Z"]) { mine, _ in mine }
        try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": segments]).write(to: url)
        return try MeetingSummarizer.parseTranscriptForTesting(at: url)
    }

    private func participantsLine(_ segments: [SummarySegment], _ metadata: SummaryMetadata) throws -> String {
        let message = SummaryPromptBuilder.userMessage(metadata: metadata, segments: segments)
        return String(try #require(message.split(separator: "\n").first { $0.hasPrefix("Participants:") }))
    }

    @Test func anEchoVoiceAndUnattributedLinesAreNotParticipants() throws {
        let (segments, metadata) = try parse(call() + [line("Local Unknown", "local", "mm-hm")], ["echo_clusters": [cluster(echo)]])
        #expect(metadata.speakers == [them, you])
        #expect(try participantsLine(segments, metadata) == "Participants: Remote Speaker 1, Local Speaker 1")
        // Its visible line is kept — it mixes both people's words — under the channel's unattributed label.
        #expect(segments.map(\.speaker) == [them, you, "Local Unknown", "Local Unknown"])
        #expect(segments.map(\.text) == ["the budget is approved", "good news", "half of both voices", "mm-hm"])
        let message = SummaryPromptBuilder.userMessage(metadata: metadata, segments: segments)
        #expect(!message.contains(echo), "nothing in the prompt the model can make a participant of")
        #expect(message.contains("[00:00:09] Local Unknown (local): half of both voices"))
    }

    /// `echo_clusters` keeps the label the check compared; the lines carry the name the user gave it.
    @Test func anEchoVoiceTheUserRenamedIsNotAParticipant() throws {
        let (segments, metadata) = try parse(call(echoSpeaker: "Dana"), [
            "echo_clusters": [cluster(echo)], "speaker_names": [echo: "Dana"]])
        #expect(metadata.speakers == [them, you])
        #expect(segments.map(\.speaker) == [them, you, "Local Unknown"])
    }

    @Test func aRemoteUnattributedLineIsNotAParticipantAndKeepsItsLabel() throws {
        let (segments, metadata) = try parse(call() + [line("Remote Unknown", "remote", "sorry, go on")], ["echo_clusters": [cluster(echo)]])
        #expect(metadata.speakers == [them, you])
        #expect(segments.last?.speaker == "Remote Unknown")
        #expect(segments.last?.text == "sorry, go on")
    }

    /// The user never spoke: everything on the microphone is the other side's voice.
    @Test func whenEveryLocalLineIsTheEchoVoiceOnlyTheOtherSideAttended() throws {
        let onlyEcho = call().filter { $0["speaker"] as? String != you }
        let (segments, metadata) = try parse(onlyEcho, ["echo_clusters": [cluster(echo)]])
        #expect(metadata.speakers == [them])
        #expect(try participantsLine(segments, metadata) == "Participants: Remote Speaker 1")
        #expect(segments.map(\.speaker) == [them, "Local Unknown"])
    }

    /// The other half of the rule: with nothing judged echo the same call reaches the model exactly
    /// as it always has — a second voice on this side is a person until the record says otherwise.
    @Test func withoutAnEchoVoiceTheParticipantsAndThePromptAreUnchanged() throws {
        for metadata in [[:], ["echo_clusters": [] as [Any]], ["echo_clusters": [cluster(echo, "kept")]]] as [[String: Any]] {
            let (segments, parsed) = try parse(call(), metadata)
            #expect(parsed.speakers == [them, you, echo])
            #expect(segments.map(\.speaker) == [them, you, echo])
            let asBefore = SummaryPromptBuilder.userMessage(
                metadata: SummaryMetadata(sessionName: parsed.sessionName, date: parsed.date, durationSeconds: 12,
                                          speakers: [them, you, echo], dualStream: true),
                segments: [
                    SummarySegment(start: 0, end: 4, speaker: them, text: "the budget is approved", source: "remote"),
                    SummarySegment(start: 5, end: 8, speaker: you, text: "good news", source: "local"),
                    SummarySegment(start: 9, end: 12, speaker: echo, text: "half of both voices", source: "local"),
                ])
            #expect(SummaryPromptBuilder.userMessage(metadata: parsed, segments: segments) == asBefore)
        }
    }

    /// "Unknown" is an absence of attribution on any transcript, echo or not: its lines stay, and
    /// it is not somebody who attended.
    @Test func unattributedLinesAreNeverParticipants() throws {
        let lines = [line("Alice", "", "ship it", at: 0), line("Unknown", "", "mm-hm", at: 3), line("Local Unknown", "local", "right", at: 6)]
        let (segments, metadata) = try parse(lines, [:])
        #expect(metadata.speakers == ["Alice"])
        #expect(segments.map(\.speaker) == ["Alice", "Unknown", "Local Unknown"])
    }

    /// A name says who somebody is. When the user gave the echo voice the name of someone else in
    /// the transcript, the lines under that name cannot be told apart: all of them stay that person's.
    @Test func aNameTheEchoVoiceSharesWithAPersonStaysAParticipant() throws {
        let renamed = call(echoSpeaker: "Robin").map { $0.merging(["speaker": $0["speaker"] as? String == you ? "Robin" : $0["speaker"]!]) { $1 } }
        let (segments, metadata) = try parse(renamed, [
            "echo_clusters": [cluster(echo)], "speaker_names": [echo: "Robin", you: "Robin"]])
        #expect(metadata.speakers == [them, "Robin"])
        #expect(segments.map(\.speaker) == [them, "Robin", "Robin"])
    }

    /// The likely rename: the user recognises the echo voice and gives it the other person's name.
    @Test func anEchoVoiceNamedAfterTheOtherSideLeavesThatPersonAParticipant() throws {
        let renamed = call(echoSpeaker: "Robin").map { $0.merging(["speaker": $0["speaker"] as? String == them ? "Robin" : $0["speaker"]!]) { $1 } }
        let (segments, metadata) = try parse(renamed, [
            "echo_clusters": [cluster(echo)], "speaker_names": [echo: "Robin", them: "Robin"]])
        #expect(metadata.speakers == ["Robin", you])
        #expect(segments.map(\.speaker) == ["Robin", you, "Robin"])
    }

    /// An echo voice is a voice on the microphone: a line on the other channel is never its line.
    @Test func onlyLinesOnTheEchoVoicesOwnChannelLoseTheirLabel() throws {
        let (segments, metadata) = try parse(call() + [line(echo, "remote", "the other channel")], ["echo_clusters": [cluster(echo)]])
        #expect(segments.map(\.speaker) == [them, you, "Local Unknown", echo])
        #expect(metadata.speakers == [them, you, echo])
    }
}
