import Foundation
import os

/// The System Audio Recording permission (`kTCCServiceAudioCapture`) that the Core Audio tap needs
/// (#103, #220).
///
/// macOS has NO public API to read or request this permission. Without it, Core Audio still creates
/// the tap and the aggregate, `AudioDeviceStart` returns `noErr`, and the IOProc runs at full rate —
/// delivering exact digital zeros. The only trace is `coreaudiod` logging
/// `Client is not granted access to the tap.` (2026-09-23: a 52-minute call recorded with no remote
/// audio and nothing in Parley noticed.) So this wraps Apple's private TCC SPI
/// (`TCCAccessPreflight` / `TCCAccessRequest`), resolved at runtime with `dlsym` so a future macOS
/// that removes it degrades to "unverifiable" (`nil`) instead of failing to launch.
///
/// Private SPI: not App Store-safe — recorded in docs/app-store-blockers.md.
///
/// Findings that shape how this is called (TCC spike, 2026-09-23):
/// - TCC attributes the tap to the HOST APP (`eu.fmasi.parley`), not the XPC helper that creates it:
///   the prompt names the app and uses the app's `NSAudioCaptureUsageDescription`. Without that key
///   in the app's Info.plist, macOS never prompts and the status stays `notDetermined` forever.
/// - `TCCAccessPreflight` caches its answer for the life of the calling process. The long-running app
///   process kept reporting the launch-time answer after a grant AND after a revocation; the helper
///   (which touches the tap) saw both changes. Live checks therefore go through the helper over XPC.
/// - A grant takes effect in an already-running helper: rebuilding the tap is enough, no restart.
public enum SystemAudioRecordingPermission {
    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (
        CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let tcc: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// Map a `TCCAccessPreflight` result code: 0 = granted, 1 = denied, 2 = never asked. Anything else
    /// is a code this build doesn't understand, so it is reported as unverifiable (`nil`).
    public static func status(fromPreflight code: Int32) -> PermissionStatus? {
        switch code {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return nil
        }
    }

    /// The current status as seen by THIS process, or `nil` if the SPI is unavailable. Cached by TCC
    /// for the process lifetime — see the type doc before calling this from the app process.
    public static func preflight() -> PermissionStatus? {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else {
            Logger.permissions.error("TCCAccessPreflight unavailable — System Audio Recording permission cannot be verified")
            return nil
        }
        let code = unsafeBitCast(sym, to: PreflightFn.self)(service, nil)
        let status = status(fromPreflight: code)
        if status == nil {
            Logger.permissions.error("TCCAccessPreflight returned unrecognized code \(code, privacy: .public)")
        }
        return status
    }

    /// Show the system "would like to record your system audio" prompt if the user has never answered
    /// it. Must be called from the APP process: the prompt is attributed to the app.
    ///
    /// Returns `.authorized` when granted, and `nil` for EVERYTHING else: `TCCAccessRequest` reports
    /// `false` for an explicit "Don't Allow", for a prompt dismissed without answering, and for a
    /// request that raised no prompt at all, so `false` can't be read as "denied". The caller asks the
    /// helper (whose preflight is fresh) for the real status.
    public static func request() async -> PermissionStatus? {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else {
            Logger.permissions.error("TCCAccessRequest unavailable — cannot prompt for System Audio Recording")
            return nil
        }
        let request = unsafeBitCast(sym, to: RequestFn.self)
        let granted: Bool = await withCheckedContinuation { cont in
            request(service, nil) { cont.resume(returning: $0) }
        }
        return granted ? .authorized : nil
    }

    // MARK: - XPC wire format

    /// The permission status as a string for the XPC reply (`nil` = unverifiable).
    public static func wireValue(_ status: PermissionStatus?) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case nil: return "unavailable"
        }
    }

    public static func status(fromWire value: String) -> PermissionStatus? {
        switch value {
        case "authorized": return .authorized
        case "denied": return .denied
        case "notDetermined": return .notDetermined
        default: return nil
        }
    }
}
