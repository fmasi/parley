import Testing
import Foundation
@testable import TranscriberCore

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

    // MARK: - Recording toggle label

    @Test func toggleLabelForIdle() {
        let state = AppState()
        #expect(state.recordingToggleLabel == "Start Recording")
    }

    @Test func toggleLabelForRecording() {
        let state = AppState()
        state.phase = .recording(since: Date())
        #expect(state.recordingToggleLabel == "Stop Recording")
    }

    @Test func toggleLabelForTranscribing() {
        let state = AppState()
        state.phase = .transcribing(progress: "Working...")
        #expect(state.recordingToggleLabel == "Transcribing...")
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
}
