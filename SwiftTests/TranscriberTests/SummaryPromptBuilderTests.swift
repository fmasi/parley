import Testing
import Foundation
@testable import TranscriberCore

struct SummaryPromptBuilderTests {

    // MARK: - systemMessage

    @Test func systemMessageWithoutDualStreamIsJustTheSystemPrompt() {
        #expect(SummaryPromptBuilder.systemMessage(dualStream: false) == SummaryPromptBuilder.systemPrompt)
    }

    @Test func systemMessageWithDualStreamAppendsTheHint() {
        let msg = SummaryPromptBuilder.systemMessage(dualStream: true)
        #expect(msg == SummaryPromptBuilder.systemPrompt + SummaryPromptBuilder.dualStreamHint)
        #expect(msg.contains("Dual-Stream Audio Context"))
    }

    // formatDate is locale/timezone-dependent so exact matching is fragile; a non-empty smoke
    // test still catches a complete breakage (e.g. a wrong formatter style returning "").
    @Test func formatDateProducesNonEmptyOutput() {
        #expect(!SummaryPromptBuilder.formatDate(Date(timeIntervalSince1970: 0)).isEmpty)
    }

    // MARK: - formatDuration (both branches: h == 0 and h > 0)

    @Test func formatDurationCoversSubMinuteAndHours() {
        #expect(SummaryPromptBuilder.formatDuration(0) == "0m")      // zero
        #expect(SummaryPromptBuilder.formatDuration(30) == "0m")     // sub-minute rounds to 0m
        #expect(SummaryPromptBuilder.formatDuration(90) == "1m")     // h == 0 branch
        #expect(SummaryPromptBuilder.formatDuration(3720) == "1h 2m") // h > 0 branch
    }

    // MARK: - userMessage

    @Test func userMessageBuildsMetadataHeaderThenTranscript() {
        let metadata = SummaryMetadata(
            sessionName: "standup",
            date: Date(timeIntervalSince1970: 0),
            durationSeconds: 3720,   // 1h 2m
            speakers: ["Alice", "Bob"]
        )
        let segments = [SummarySegment(start: 0, end: 5, speaker: "Alice", text: "hello")]

        let msg = SummaryPromptBuilder.userMessage(metadata: metadata, segments: segments)

        #expect(msg.contains("Meeting: standup"))
        #expect(msg.contains("Date: "))   // value is locale/timezone-dependent; assert the label
        #expect(msg.contains("Duration: 1h 2m"))
        #expect(msg.contains("Participants: Alice, Bob"))
        #expect(msg.contains("--- TRANSCRIPT ---"))
        #expect(msg.contains("Alice: hello"))
        // The metadata header must precede the transcript body.
        let headerIdx = msg.range(of: "Meeting: standup")!.lowerBound
        let transcriptIdx = msg.range(of: "--- TRANSCRIPT ---")!.lowerBound
        #expect(headerIdx < transcriptIdx)
    }

    @Test func userMessageTagsSourceOnlyWhenDualStream() {
        let segments = [SummarySegment(start: 0, end: 5, speaker: "Alice", text: "hi", source: "local")]

        let dual = SummaryPromptBuilder.userMessage(
            metadata: SummaryMetadata(sessionName: "c", date: Date(timeIntervalSince1970: 0),
                                      durationSeconds: 60, speakers: ["Alice"], dualStream: true),
            segments: segments
        )
        let single = SummaryPromptBuilder.userMessage(
            metadata: SummaryMetadata(sessionName: "c", date: Date(timeIntervalSince1970: 0),
                                      durationSeconds: 60, speakers: ["Alice"], dualStream: false),
            segments: segments
        )

        #expect(dual.contains("Alice (local): hi"))    // includeSource when dual-stream
        #expect(single.contains("Alice: hi"))
        #expect(!single.contains("(local)"))
    }

    @Test func headerNamesAnUncapturedRemoteSide() {
        let m = SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["Frederic"],
                                dualStream: true, echoSegmentsRemoved: 0,
                                remoteCapture: CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 2736))
        let msg = SummaryPromptBuilder.userMessage(metadata: m, segments: [])
        #expect(msg.contains("Remote audio: not captured (0 s delivered of 2736 s expected)"))
        #expect(SummaryPromptBuilder.captureLine(SummaryMetadata(sessionName: "s", date: Date(), durationSeconds: 1, speakers: [])) == nil)
        #expect(SummaryPromptBuilder.systemPrompt.contains("state that in the Summary section"))
    }

    // MARK: - Capture wording (R1 review round 1)

    private func meta(remote: CaptureSideNote? = nil, local: CaptureSideNote? = nil, gapCount: Int = 0, gapSeconds: Double = 0,
                      coverageNotRecorded: Bool = false) -> SummaryMetadata {
        SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["A"],
                        dualStream: true, remoteCapture: remote, localCapture: local,
                        coverageNotRecorded: coverageNotRecorded, gapCount: gapCount, gapSeconds: gapSeconds)
    }

    @Test func aShortfallIsPartlyCaptured() {
        let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 1000, expectedSeconds: 2736))
        #expect(SummaryPromptBuilder.captureLine(m) == "Remote audio: partly captured (1000 s delivered of 2736 s expected)")
    }

    /// #220: the tap delivered every second, all exact zeros, and the denial was confirmed.
    @Test func confirmedDenialWithFullDeliveryIsNotCaptured() {
        let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736,
                                             exactZeroSeconds: 2736, permissionDenied: true))
        #expect(SummaryPromptBuilder.captureLine(m)
                == "Remote audio: not captured — system audio permission was not granted; 2736 s of digital silence were recorded instead")
    }

    /// Never claim a fault it can't confirm, never claim health either.
    @Test func unconfirmedSilenceIsUncertain() {
        for denied in [false, nil] as [Bool?] {
            let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736,
                                                 exactZeroSeconds: 2736, permissionDenied: denied))
            #expect(SummaryPromptBuilder.captureLine(m)
                    == "Remote audio: uncertain — 2736 s were exact digital silence and Parley could not confirm the permission; the other side may have been muted, or not captured")
        }
    }

    @Test func otherContentAnomaliesAreCapturedButCompromised() {
        let counted = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736,
                                                   exactZeroSeconds: 0, anomalyCount: 2))
        #expect(SummaryPromptBuilder.captureLine(counted) == "Remote audio: captured, but compromised (2 capture anomalies recorded)")
        let uncounted = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736))
        #expect(SummaryPromptBuilder.captureLine(uncounted) == "Remote audio: captured, but compromised (anomaly count not recorded)")
    }

    @Test func remoteIdleSaysNothingWasPlaying() {
        let m = meta(remote: CaptureSideNote(status: "idle", deliveredSeconds: 0, expectedSeconds: 0))
        #expect(SummaryPromptBuilder.captureLine(m) == "Remote audio: nothing was playing on this Mac (no remote side)")
        #expect(SummaryPromptBuilder.captureBanner(m) == nil, "an idle side is not a missing side")
    }

    @Test func theLocalLineJoinsAfterTheRemoteOne() {
        let m = meta(remote: CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 60),
                     local: CaptureSideNote(status: "compromised", deliveredSeconds: 20, expectedSeconds: 60))
        #expect(SummaryPromptBuilder.captureLine(m)
                == "Remote audio: not captured (0 s delivered of 60 s expected)\nYour microphone: partly captured (20 s delivered of 60 s expected)")
    }

    /// The owner's muted-remote case: every second delivered, all digital zero, permission fine.
    @Test func aHealthyMutedRemoteGetsNoLine() {
        let m = meta(remote: CaptureSideNote(status: "healthy", deliveredSeconds: 2736, expectedSeconds: 2736,
                                             exactZeroSeconds: 2736, permissionDenied: false))
        #expect(SummaryPromptBuilder.captureLine(m) == nil)
        #expect(SummaryPromptBuilder.captureBanner(m) == nil)
    }

    @Test func anUnknownOrMissingStatusFailsClosed() {
        for status in ["", "fromTheFuture"] {
            let m = meta(remote: CaptureSideNote(status: status, deliveredSeconds: 10, expectedSeconds: 20))
            #expect(SummaryPromptBuilder.captureLine(m) == "Remote audio: capture status unknown (10 s of 20 s)")
        }
    }

    /// A corrupted transcript must not crash summarizing (`Int(1e300)` traps).
    @Test func hugeSecondsDoNotTrap() {
        let m = meta(remote: CaptureSideNote(status: "neverDelivered", deliveredSeconds: 1e300, expectedSeconds: .infinity))
        #expect(SummaryPromptBuilder.captureLine(m) == "Remote audio: not captured (? s delivered of ? s expected)")
    }

    @Test func coverageNotRecordedIsSaidButNotBannered() {
        let m = meta(coverageNotRecorded: true)
        #expect(SummaryPromptBuilder.captureLine(m) == "Capture coverage was not recorded")
        #expect(SummaryPromptBuilder.captureBanner(m) == nil)
    }

    @Test func gapsGetAHeaderLineAndTheBanner() {
        let m = meta(gapCount: 2, gapSeconds: 190)
        #expect(SummaryPromptBuilder.captureLine(m) == "Recording gaps: 2 (total 3 min 10 s)")
        #expect(SummaryPromptBuilder.captureBanner(m)?.contains("Recording gaps: 2 (total 3 min 10 s)") == true)
    }

    @Test func theDualStreamHintIsDroppedWhenTheRemoteSideIsAbsent() {
        let absent = meta(remote: CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 60))
        #expect(!SummaryPromptBuilder.systemMessage(metadata: absent).contains("Dual-Stream Audio Context"))
        let idle = meta(remote: CaptureSideNote(status: "idle", deliveredSeconds: 0, expectedSeconds: 0))
        #expect(!SummaryPromptBuilder.systemMessage(metadata: idle).contains("Dual-Stream Audio Context"))
        let healthy = meta(remote: CaptureSideNote(status: "healthy", deliveredSeconds: 60, expectedSeconds: 60))
        #expect(SummaryPromptBuilder.systemMessage(metadata: healthy).contains("Dual-Stream Audio Context"))
    }

    /// Round 3 item 6: every-second digital silence after a failed restart (no confirmed denial)
    /// must never be called a permission denial.
    @Test func aFailedRestartAloneNeverSaysPermissionDenied() {
        let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736,
                                             exactZeroSeconds: 2736, permissionDenied: false))
        let line = SummaryPromptBuilder.captureLine(m) ?? ""
        #expect(!line.contains("permission was not granted") && line.contains("uncertain"))
    }

    @Test func theRuleNamesEveryIncompleteCase() {
        #expect(SummaryPromptBuilder.systemPrompt.contains(
            "not captured, partly captured, uncertain, compromised, recorded only digital silence, or partly digital silence"))
    }

    // MARK: - Round 4 wording

    @Test func anAllSilentMicrophoneIsSaidPlainly() {
        let m = meta(local: CaptureSideNote(status: "compromised", deliveredSeconds: 600, expectedSeconds: 600, exactZeroSeconds: 600, anomalyCount: 1))
        #expect(SummaryPromptBuilder.captureLine(m) == "Your microphone: recorded only digital silence (600 s)")
    }

    /// "partly captured" must not hide that much of what WAS delivered was digital silence.
    @Test func aShortfallWithSilenceSaysHowMuch() {
        let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 1000, expectedSeconds: 2736, exactZeroSeconds: 400))
        #expect(SummaryPromptBuilder.captureLine(m)
                == "Remote audio: partly captured (1000 s delivered of 2736 s expected); 400 s of it was digital silence")
    }

    /// A corrupted transcript's segment times must not crash summarizing (`Int(1e300)` traps).
    @Test func hugeSegmentTimesDoNotTrap() {
        let m = SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 1e300, speakers: ["A"])
        let msg = SummaryPromptBuilder.userMessage(metadata: m, segments: [
            SummarySegment(start: 1e300, end: .infinity, speaker: "A", text: "hi"),
            SummarySegment(start: -5, end: 1, speaker: "A", text: "neg"),
        ])
        #expect(msg.contains("[--:--:--] A: hi") && msg.contains("[--:--:--] A: neg"))
        #expect(msg.contains("Duration: ?"))
    }

    // MARK: - Round 6 wording

    /// N2: a mic that died 5 minutes into a 60-minute call did record the user for 5 minutes.
    @Test func aMicThatDiedPartWayIsNotOnlySilence() {
        let m = meta(local: CaptureSideNote(status: "compromised", deliveredSeconds: 3600, expectedSeconds: 3600, exactZeroSeconds: 3300))
        #expect(SummaryPromptBuilder.captureLine(m) == "Your microphone: captured, but 3300 s of 3600 s was digital silence")
        let allButHalfASecond = meta(local: CaptureSideNote(status: "compromised", deliveredSeconds: 600, expectedSeconds: 600, exactZeroSeconds: 599.5))
        #expect(SummaryPromptBuilder.captureLine(allButHalfASecond) == "Your microphone: recorded only digital silence (600 s)")
    }

    /// Item 4: a partly captured remote side whose permission was confirmed not granted says so.
    @Test func aPartialCaptureWithAConfirmedDenialNamesThePermission() {
        let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 1000, expectedSeconds: 2736, exactZeroSeconds: 400,
                                             permissionDenied: true))
        #expect(SummaryPromptBuilder.captureLine(m)
                == "Remote audio: partly captured (1000 s delivered of 2736 s expected); 400 s of it was digital silence; system audio permission was not granted for part of the call")
    }

    // MARK: - Round 7

    /// The partial-silence line keeps the side's anomaly count when it has one.
    @Test func partialSilenceKeepsTheAnomalyCount() {
        let m = meta(local: CaptureSideNote(status: "compromised", deliveredSeconds: 3600, expectedSeconds: 3600, exactZeroSeconds: 3300, anomalyCount: 2))
        #expect(SummaryPromptBuilder.captureLine(m) == "Your microphone: captured, but 3300 s of 3600 s was digital silence (2 capture anomalies recorded)")
    }

    /// A compromised remote side with a confirmed denial names the permission even without a
    /// shortfall or silence.
    @Test func aCompromisedRemoteWithAConfirmedDenialNamesThePermission() {
        let m = meta(remote: CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736, exactZeroSeconds: 0,
                                             permissionDenied: true, anomalyCount: 1))
        #expect(SummaryPromptBuilder.captureLine(m)
                == "Remote audio: captured, but compromised (1 capture anomaly recorded); system audio permission was not granted for part of the call")
    }

    /// Corrupt counts (more zeros than delivered audio) are clamped before the wording is chosen.
    @Test func moreZerosThanDeliveredIsClamped() {
        let m = meta(local: CaptureSideNote(status: "compromised", deliveredSeconds: 600, expectedSeconds: 600, exactZeroSeconds: 900))
        #expect(SummaryPromptBuilder.captureLine(m) == "Your microphone: recorded only digital silence (600 s)")
    }
}
