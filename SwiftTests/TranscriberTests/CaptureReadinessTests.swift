import Testing
@testable import TranscriberCore

/// #220 / #174: the permissions a recording needs depend on the configured system-audio source, and
/// once onboarding has been completed a missing permission must route to REPAIR, never back to the
/// "Setup required" lockout that catches the user by surprise at record time.
struct CaptureReadinessTests {

    // MARK: - required(for:)

    @Test func screenCaptureKitNeedsMicAndScreenRecording() {
        #expect(CaptureReadiness.required(for: .screenCaptureKit) == [.microphone, .screenRecording])
    }

    /// The tap needs System Audio Recording, NOT Screen Recording. Holding Screen Recording while the
    /// System Audio grant was missing is exactly the state that silently recorded 52 minutes of
    /// digital zeros on 2026-09-23 (#220).
    @Test func coreAudioTapNeedsMicAndSystemAudioRecording() {
        #expect(CaptureReadiness.required(for: .coreAudioTap) == [.microphone, .systemAudioRecording])
    }

    // MARK: - missing(for:status:)

    @Test func nothingMissingWhenAllRequiredAuthorized() {
        let missing = CaptureReadiness.missing(for: .coreAudioTap) { _ in .authorized }
        #expect(missing.isEmpty)
    }

    @Test func tapWithScreenRecordingButNoSystemAudioIsMissingSystemAudio() {
        let missing = CaptureReadiness.missing(for: .coreAudioTap) { permission in
            switch permission {
            case .microphone, .screenRecording: return .authorized
            case .systemAudioRecording: return .notDetermined
            }
        }
        #expect(missing == [.systemAudioRecording])
    }

    @Test func unrequiredPermissionIsNeverReportedMissing() {
        // Screen Recording is irrelevant to a tap recording, so its state must not matter.
        let missing = CaptureReadiness.missing(for: .coreAudioTap) { permission in
            permission == .screenRecording ? .denied : .authorized
        }
        #expect(missing.isEmpty)
    }

    @Test func deniedAndNotDeterminedAreBothMissing() {
        let missing = CaptureReadiness.missing(for: .screenCaptureKit) { permission in
            permission == .microphone ? .denied : .notDetermined
        }
        #expect(missing == [.microphone, .screenRecording])
    }

    // MARK: - launchDecision

    @Test func beforeOnboardingEverythingGrantedIsReady() {
        #expect(CaptureReadiness.launchDecision(onboardingCompleted: false, missing: [], modelReady: true) == .ready)
    }

    @Test func beforeOnboardingAMissingPermissionShowsOnboarding() {
        #expect(CaptureReadiness.launchDecision(
            onboardingCompleted: false, missing: [.microphone], modelReady: true) == .onboarding)
    }

    @Test func beforeOnboardingAMissingModelShowsOnboarding() {
        #expect(CaptureReadiness.launchDecision(onboardingCompleted: false, missing: [], modelReady: false) == .onboarding)
    }

    /// The core rule: after onboarding, a missing permission never locks the app — it opens repair.
    @Test func afterOnboardingAMissingPermissionRoutesToRepairNotLockout() {
        #expect(CaptureReadiness.launchDecision(
            onboardingCompleted: true, missing: [.systemAudioRecording], modelReady: true
        ) == .readyNeedsRepair([.systemAudioRecording]))
    }

    @Test func afterOnboardingAllGrantedIsReady() {
        #expect(CaptureReadiness.launchDecision(onboardingCompleted: true, missing: [], modelReady: true) == .ready)
    }

    /// A deleted model cache is not a permission problem — the setup window is still the only place
    /// that can download it.
    @Test func afterOnboardingAMissingModelStillShowsOnboarding() {
        #expect(CaptureReadiness.launchDecision(onboardingCompleted: true, missing: [], modelReady: false) == .onboarding)
    }

    // MARK: - onboarding migration

    @Test func explicitFlagMeansOnboarded() {
        #expect(CaptureReadiness.isOnboarded(flag: true, microphoneGranted: false))
    }

    /// Installs predating the flag: a granted microphone can only have come from going through setup.
    @Test func legacyInstallWithGrantedMicCountsAsOnboarded() {
        #expect(CaptureReadiness.isOnboarded(flag: false, microphoneGranted: true))
    }

    @Test func freshInstallIsNotOnboarded() {
        #expect(!CaptureReadiness.isOnboarded(flag: false, microphoneGranted: false))
    }

    // MARK: - fixAction

    @Test func notDeterminedIsFixedByRequestingThePrompt() {
        #expect(CaptureReadiness.fixAction(for: .notDetermined) == .requestPrompt)
    }

    /// macOS will not re-prompt after an explicit deny — the only fix is System Settings.
    @Test func deniedIsFixedInSystemSettings() {
        #expect(CaptureReadiness.fixAction(for: .denied) == .openSystemSettings)
    }

    @Test func authorizedNeedsNoFix() {
        #expect(CaptureReadiness.fixAction(for: .authorized) == nil)
    }
}

/// The private-SPI result codes (`TCCAccessPreflight`) mapped to Parley's permission states (#220).
struct SystemAudioRecordingPermissionTests {
    @Test func preflightZeroIsAuthorized() {
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 0) == .authorized)
    }

    @Test func preflightOneIsDenied() {
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 1) == .denied)
    }

    /// "Unknown" — never asked. The state Parley was stuck in: with no usage string in the app's
    /// Info.plist macOS never prompts, so it stays here and the tap records zeros forever.
    @Test func preflightTwoIsNotDetermined() {
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 2) == .notDetermined)
    }

    @Test func unrecognizedPreflightCodeIsUnverifiable() {
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 7) == nil)
        #expect(SystemAudioRecordingPermission.status(fromPreflight: -1) == nil)
    }

    @Test func wireValueRoundTrips() {
        for status in [PermissionStatus.authorized, .denied, .notDetermined] {
            #expect(SystemAudioRecordingPermission.status(fromWire: SystemAudioRecordingPermission.wireValue(status)) == status)
        }
        #expect(SystemAudioRecordingPermission.status(fromWire: SystemAudioRecordingPermission.wireValue(nil)) == nil)
        #expect(SystemAudioRecordingPermission.status(fromWire: "garbage") == nil)
    }
}
