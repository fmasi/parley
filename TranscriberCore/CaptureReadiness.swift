import Foundation

/// A permission a recording cannot do without.
public enum CapturePermission: String, CaseIterable, Sendable {
    case microphone
    case screenRecording
    /// `kTCCServiceAudioCapture` — what the Core Audio tap needs (#103, #220).
    case systemAudioRecording

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .systemAudioRecording: return "System Audio Recording"
        }
    }
}

/// Pure decisions about whether Parley is ready to record (#174, #220).
///
/// The rule this encodes: onboarding is the one place permissions get set up. After that, Parley is
/// always usable. A missing permission is REPAIRED (a window naming exactly what is missing, with a
/// one-click fix), never answered with the "Setup required" lockout, which catches the user by
/// surprise at the moment they press Record.
public enum CaptureReadiness {

    /// The permissions a recording needs with this system-audio source. The tap does NOT need Screen
    /// Recording, and Screen Recording does NOT let the tap hear anything. Holding one while missing
    /// the other is precisely how 52 minutes of remote audio were recorded as digital zeros (#220).
    public static func required(for source: SystemAudioSource) -> [CapturePermission] {
        switch source {
        case .screenCaptureKit: return [.microphone, .screenRecording]
        case .coreAudioTap: return [.microphone, .systemAudioRecording]
        }
    }

    /// The required permissions that are not granted, in `required(for:)` order.
    public static func missing(
        for source: SystemAudioSource,
        status: (CapturePermission) -> PermissionStatus
    ) -> [CapturePermission] {
        required(for: source).filter { !status($0).isGranted }
    }

    public enum LaunchDecision: Equatable, Sendable {
        /// Everything needed is in place.
        case ready
        /// First run (or a missing model): show the setup window, which gates the app.
        case onboarding
        /// Onboarding was completed once, so the app stays usable — open the repair window for these.
        case readyNeedsRepair([CapturePermission])
    }

    public static func launchDecision(
        onboardingCompleted: Bool,
        missing: [CapturePermission],
        modelReady: Bool
    ) -> LaunchDecision {
        // A missing model is not a permission problem: only the setup window can download it.
        guard modelReady else { return .onboarding }
        guard onboardingCompleted else { return missing.isEmpty ? .ready : .onboarding }
        return missing.isEmpty ? .ready : .readyNeedsRepair(missing)
    }

    /// Whether this install has been through onboarding. Installs predating the persisted flag are
    /// recognised by a granted microphone, which can only have come from going through setup.
    public static func isOnboarded(flag: Bool, microphoneGranted: Bool) -> Bool {
        flag || microphoneGranted
    }

    public enum FixAction: Equatable, Sendable {
        /// Never asked: the system prompt can still be shown.
        case requestPrompt
        /// Explicitly denied or switched off: macOS will not prompt again, only System Settings can fix it.
        case openSystemSettings
    }

    /// "System Audio Recording is off" / "Microphone and System Audio Recording are off".
    public static func offPhrase(for permissions: [CapturePermission]) -> String {
        let names = permissions.map(\.displayName)
        let list: String
        switch names.count {
        case 0, 1: list = names.first ?? ""
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
        return "\(list) \(names.count > 1 ? "are" : "is") off"
    }

    /// After the user clicks "Later" on the repair window, a persisting problem reopens it only once
    /// this has passed. The sticky menu-bar state keeps saying so in between.
    public static let repairSnooze: TimeInterval = 180

    /// Whether a new report of a still-missing permission should (re)open the repair window.
    public static func shouldPresentRepair(lastDismissedAt: Date?, now: Date) -> Bool {
        guard let lastDismissedAt else { return true }
        return now.timeIntervalSince(lastDismissedAt) >= repairSnooze
    }

    public static func fixAction(for status: PermissionStatus) -> FixAction? {
        switch status {
        case .authorized: return nil
        case .notDetermined: return .requestPrompt
        case .denied: return .openSystemSettings
        }
    }
}
