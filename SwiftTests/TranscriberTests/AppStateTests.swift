import Testing
import Foundation
@testable import TranscriberCore

@MainActor
struct AppStateTests {

    // MARK: - Initial state

    @Test func initialStateIsIdle() {
        let state = AppState()
        #expect(state.isIdle == true)
        #expect(state.isRecording == false)
        #expect(state.isTranscribing == false)
        #expect(state.lastTranscriptPath == nil)
        #expect(state.lastJsonPath == nil)
        #expect(state.errorMessage == nil)
    }

    // MARK: - Phase transitions

    @Test func recordingPhase() {
        let state = AppState()
        let now = Date()
        state.phase = .recording(since: now)

        #expect(state.isIdle == false)
        #expect(state.isRecording == true)
        #expect(state.isTranscribing == false)
    }

    @Test func transcribingPhase() {
        let state = AppState()
        state.phase = .transcribing(progress: "Processing...")

        #expect(state.isIdle == false)
        #expect(state.isRecording == false)
        #expect(state.isTranscribing == true)
    }

    @Test func backToIdle() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.phase = .idle

        #expect(state.isIdle == true)
        #expect(state.isRecording == false)
    }

    // MARK: - Menu bar icon

    @Test func menuBarIconForIdle() {
        let state = AppState()
        #expect(state.menuBarIcon == "mic")
    }

    @Test func menuBarIconForRecording() {
        let state = AppState()
        state.phase = .recording(since: Date())
        #expect(state.menuBarIcon == "microphone.and.signal.meter.fill")
    }

    @Test func menuBarIconForTranscribing() {
        let state = AppState()
        state.phase = .transcribing(progress: "")
        #expect(state.menuBarIcon == "hourglass")
    }

    @Test func menuBarIconForError() {
        let state = AppState()
        state.errorMessage = "Something failed"
        #expect(state.menuBarIcon == "exclamationmark.triangle")
    }

    @Test func menuBarIconForErrorOverridesPhase() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.errorMessage = "Something failed"
        #expect(state.menuBarIcon == "exclamationmark.triangle")
    }

    // MARK: - Phase equality

    @Test func idlePhasesAreEqual() {
        #expect(AppState.Phase.idle == AppState.Phase.idle)
    }

    @Test func recordingPhasesWithSameDateAreEqual() {
        let date = Date()
        #expect(AppState.Phase.recording(since: date) == AppState.Phase.recording(since: date))
    }

    @Test func recordingPhasesWithDifferentDatesAreNotEqual() {
        let a = AppState.Phase.recording(since: Date())
        let b = AppState.Phase.recording(since: Date().addingTimeInterval(1))
        #expect(a != b)
    }

    @Test func transcribingPhasesWithSameProgressAreEqual() {
        #expect(AppState.Phase.transcribing(progress: "50%") == AppState.Phase.transcribing(progress: "50%"))
    }

    @Test func differentPhasesAreNotEqual() {
        #expect(AppState.Phase.idle != AppState.Phase.recording(since: Date()))
        #expect(AppState.Phase.idle != AppState.Phase.transcribing(progress: ""))
    }

    // MARK: - Mutable properties

    @Test func errorMessageCanBeSetAndCleared() {
        let state = AppState()
        state.errorMessage = "Something failed"
        #expect(state.errorMessage == "Something failed")
        state.errorMessage = nil
        #expect(state.errorMessage == nil)
    }

    @Test func pathPropertiesCanBeSet() {
        let state = AppState()
        state.lastTranscriptPath = "/tmp/transcript.txt"
        state.lastJsonPath = "/tmp/transcript.json"
        #expect(state.lastTranscriptPath == "/tmp/transcript.txt")
        #expect(state.lastJsonPath == "/tmp/transcript.json")
    }

    // MARK: - Interruption warning

    @Test func interruptionWarningChangesIcon() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.interruptionWarning = "Recording briefly interrupted"
        #expect(state.menuBarIcon == "exclamationmark.bubble")
    }

    @Test func clearingWarningRestoresRecordingIcon() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.interruptionWarning = "test"
        state.interruptionWarning = nil
        #expect(state.menuBarIcon == "microphone.and.signal.meter.fill")
    }

    // MARK: - Interruption warning edge cases

    @Test func interruptionWarningDoesNotAffectIdleIcon() {
        let state = AppState()
        state.interruptionWarning = "Recording briefly interrupted"
        // idle phase: interruptionWarning branch is only reached inside .recording
        #expect(state.menuBarIcon == "mic")
    }

    @Test func interruptionWarningDoesNotAffectTranscribingIcon() {
        let state = AppState()
        state.phase = .transcribing(progress: "Processing...")
        state.interruptionWarning = "Recording briefly interrupted"
        // transcribing phase: interruptionWarning branch is only reached inside .recording
        #expect(state.menuBarIcon == "hourglass")
    }

    @Test func errorTakesPriorityOverInterruption() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.interruptionWarning = "Recording briefly interrupted"
        state.errorMessage = "Fatal error"
        // errorMessage check happens before the phase switch, so error wins
        #expect(state.menuBarIcon == "exclamationmark.triangle")
    }

    @Test func interruptionWarningPreservedAcrossPhaseChange() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.interruptionWarning = "Recording briefly interrupted"
        state.phase = .idle
        // phase change does not clear interruptionWarning
        #expect(state.interruptionWarning == "Recording briefly interrupted")
    }

    // MARK: - Truncated error message

    @Test func truncatedErrorMessageIsNilWhenNoError() {
        let state = AppState()
        #expect(state.truncatedErrorMessage == nil)
    }

    @Test func truncatedErrorMessageReturnsShortMessagesUnchanged() {
        let state = AppState()
        state.errorMessage = "Connection refused"
        #expect(state.truncatedErrorMessage == "Connection refused")
    }

    @Test func truncatedErrorMessageTruncatesAt80Chars() {
        let state = AppState()
        state.errorMessage = String(repeating: "a", count: 100)
        let truncated = state.truncatedErrorMessage!
        #expect(truncated.count == 83) // 80 + "..."
        #expect(truncated.hasSuffix("..."))
    }

    @Test func truncatedErrorMessageExactly80CharsNotTruncated() {
        let state = AppState()
        state.errorMessage = String(repeating: "b", count: 80)
        #expect(state.truncatedErrorMessage == String(repeating: "b", count: 80))
    }

    // MARK: - Critical error

    @Test func criticalErrorChangesIconToFilledTriangle() {
        let state = AppState()
        state.criticalError = "Recording failed"
        #expect(state.menuBarIcon == "exclamationmark.triangle.fill")
    }

    @Test func criticalErrorTakesPriorityOverRegularError() {
        let state = AppState()
        state.errorMessage = "Regular error"
        state.criticalError = "Critical error"
        #expect(state.menuBarIcon == "exclamationmark.triangle.fill")
    }

    @Test func criticalErrorTakesPriorityOverRecordingPhase() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.criticalError = "Recording failed"
        #expect(state.menuBarIcon == "exclamationmark.triangle.fill")
    }

    @Test func clearingCriticalErrorRestoresNormalIcon() {
        let state = AppState()
        state.criticalError = "Recording failed"
        state.criticalError = nil
        #expect(state.menuBarIcon == "mic")
    }

    @Test func criticalErrorIsNilInitially() {
        let state = AppState()
        #expect(state.criticalError == nil)
    }

    // MARK: - Alarms (§6)

    /// Ordered helper ids ("<ms>-<resets>") and increasing sequences: anything else is ignored by the registry.
    private func snapshot(_ id: String, _ sequence: UInt64, _ kinds: [AlarmKind]) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, sequence: sequence, isCapturing: true,
                              alarms: kinds.map { ActiveAlarm(kind: $0, raisedAt: Date(), lastNotifiedAt: nil, message: $0.rawValue, episode: 1) }, tracks: [])
    }

    @Test func helperSnapshotPopulatesActiveAlarmsAndTheStickyRemoteFlag() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.remotePermissionDenied]))
        #expect(state.activeAlarms[.remotePermissionDenied] != nil)
        #expect(state.remoteAudioNotCaptured)
        #expect(state.hasMenuAlerts)
        #expect(state.menuBarIcon == "exclamationmark.bubble")
    }

    @Test func aNewerSnapshotWithoutTheKindClearsIt() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.remotePermissionDenied]))
        state.applyHelperSnapshot(snapshot("1000-0", 2, []))
        #expect(!state.remoteAudioNotCaptured && state.activeAlarms.isEmpty)
    }

    /// The single-slot banner can be dismissed or overwritten by any later notice; the alarm cannot.
    @Test func benignNoticeNeverTouchesAnAlarm() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.rotationFailed, message: "rotation failed")
        #expect(!state.noteQualityAnomaly(kind: CaptureEventKind.livenessGap.rawValue, message: "mic gap"))
        state.interruptionWarning = nil   // user dismissed the banner
        #expect(state.activeAlarms[.rotationFailed] != nil)
        #expect(state.hasMenuAlerts)
    }

    @Test func onlyPermissionKindsAskForRepair() {
        let state = AppState()
        state.phase = .recording(since: Date())
        #expect(state.noteQualityAnomaly(kind: CaptureEventKind.systemAudioPermissionDenied.rawValue, message: "denied"))
        #expect(state.interruptionWarning == "denied")
        #expect(!state.noteQualityAnomaly(kind: CaptureEventKind.systemAudioPermissionRestored.rawValue, message: "back"))
        #expect(state.interruptionWarning == "back")
    }

    @Test func recordingEndClearsPerRecordingAlarmsButNotCrashProtection() {
        let state = AppState()
        state.raiseAppAlarm(.crashProtectionOff, message: "off")
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.diskLow, message: "low")
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.micDigitalSilence]))
        state.phase = .idle
        #expect(state.activeAlarms[.diskLow] == nil && state.activeAlarms[.micDigitalSilence] == nil)
        #expect(state.activeAlarms[.crashProtectionOff] != nil)
        #expect(state.crashProtectionOff && state.hasMenuAlerts)
        #expect(state.menuBarIcon == "exclamationmark.triangle")
    }

    @Test func acknowledgeClearsOnlyAcknowledgeableKinds() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.recordingResumedWithGap, message: "gap")
        state.raiseAppAlarm(.diskLow, message: "low")
        state.acknowledge(.recordingResumedWithGap)
        state.acknowledge(.diskLow)
        #expect(state.activeAlarms[.recordingResumedWithGap] == nil)
        #expect(state.activeAlarms[.diskLow] != nil)
    }

    /// L review 91 (H2 round 2 item 12): the user's acknowledgement of a HELPER-owned past event goes through the
    /// registry's `acknowledge`, so the helper's next snapshot of the same episode never brings the row back.
    @Test func anAcknowledgedHelperAlarmStaysAcknowledgedAcrossItsSnapshots() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.micFollowFailed]))
        #expect(state.activeAlarms[.micFollowFailed] != nil)
        state.acknowledge(.micFollowFailed)
        state.applyHelperSnapshot(snapshot("1000-0", 2, [.micFollowFailed]))
        #expect(state.activeAlarms[.micFollowFailed] == nil, "the same episode, already acknowledged")
    }

    /// §6.2 (F2 ruling): a restarted helper's empty snapshot keeps the old alarms until ITS evidence
    /// disproves each one — first frames for a delivery kind, real audio for a content kind.
    @Test func aNewHelperKeepsAlarmsUntilItsEvidenceOnThatTrack() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.remoteRecoveryFailed, .micDigitalSilence]))
        state.applyHelperSnapshot(snapshot("2000-0", 1, []))
        #expect(state.remoteAudioNotCaptured)
        state.noteFirstFrames(track: .system, helperSessionId: "2000-0")
        #expect(!state.remoteAudioNotCaptured && state.activeAlarms[.micDigitalSilence] != nil)
        state.noteFirstFrames(track: .mic, helperSessionId: "2000-0")
        #expect(state.activeAlarms[.micDigitalSilence] != nil, "first frames cannot disprove digital silence")
        state.noteRealAudio(track: .mic, helperSessionId: "2000-0")
        #expect(state.activeAlarms[.micDigitalSilence] == nil)
    }

    @Test func aStaleDiskWriteFailureClearsOnTheNewHelpersFirstWrite() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.diskWriteFailure]))
        state.applyHelperSnapshot(snapshot("2000-0", 1, []))
        #expect(state.activeAlarms[.diskWriteFailure] != nil)
        state.noteWriteSucceeded(helperSessionId: "2000-0")
        #expect(state.activeAlarms[.diskWriteFailure] == nil)
    }

    /// A helper newer than this app: its unknown kinds are not silently dropped (F2 round 1 decode).
    @Test func unknownHelperKindsRaiseAGenericAlarmUntilTheyAreGone() throws {
        let state = AppState()
        state.phase = .recording(since: Date())
        let json = #"{"helperSessionId":"1000-0","sequence":1,"isCapturing":true,"tracks":[],"alarms":[{"kind":"somethingNew","raisedAt":"2026-09-24T10:00:00.000Z","message":"m","episode":1}]}"#
        let decoded = try #require(CaptureStatusSnapshot.decode(Data(json.utf8)))
        #expect(decoded.unknownAlarmKinds == ["somethingNew"])
        state.applyHelperSnapshot(decoded)
        #expect(state.activeAlarms[.unknownHelperAlarm]?.message.contains("somethingNew") == true)
        #expect(state.hasMenuAlerts)
        state.applyHelperSnapshot(snapshot("1000-0", 2, []))
        #expect(state.activeAlarms[.unknownHelperAlarm] == nil)
    }

    /// Fix round 1 item 4: a snapshot the registry rejects (an older sequence) must not touch the
    /// unknown-kind alarm either.
    @Test func aRejectedSnapshotNeverChangesTheUnknownKindAlarm() throws {
        let state = AppState()
        state.phase = .recording(since: Date())
        let json = #"{"helperSessionId":"1000-0","sequence":2,"isCapturing":true,"tracks":[],"alarms":[{"kind":"somethingNew","raisedAt":"2026-09-24T10:00:00.000Z","message":"m","episode":1}]}"#
        #expect(state.applyHelperSnapshot(try #require(CaptureStatusSnapshot.decode(Data(json.utf8)))))
        #expect(!state.applyHelperSnapshot(snapshot("1000-0", 1, [])), "an older sequence is rejected")
        #expect(state.activeAlarms[.unknownHelperAlarm] != nil)
    }

    @Test func noAlertsWhenNothingIsWrong() {
        #expect(!AppState().hasMenuAlerts)
    }

    @Test func aBannerAloneStillCountsAsAnAlert() {
        let state = AppState()
        state.interruptionWarning = "device changed"
        #expect(state.hasMenuAlerts)
    }
}
