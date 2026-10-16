import Foundation
#if canImport(IOKit)
import IOKit
#endif
#if canImport(CoreAudio)
import CoreAudio
import AudioToolbox
#endif

/// Pre-flight check for #193: the MacBook lid can be closed while the built-in mic REMAINS the
/// default input device and keeps delivering full-rate buffers of exact digital zero — no HAL
/// event fires, so nothing distinguishes it from a healthy mic until `ExactZeroRunMonitor` catches
/// it live. Warning BEFORE capture starts (rather than only live, mid-recording) catches the case
/// where the user would otherwise not find out until the meeting is over.
public enum ClamshellMicGuard {

    /// Pure decision: should the pre-flight warning be shown? Trivially unit-testable; the two
    /// inputs (`isLidClosed`, `isBuiltInMic`) come from IOKit/CoreAudio and cannot be unit-tested
    /// without real hardware — see `isLidClosed()` / `isBuiltInMicSelected(deviceId:)` below.
    public static func shouldWarn(lidClosed: Bool, isBuiltInMic: Bool) -> Bool {
        lidClosed && isBuiltInMic
    }

    /// The user-facing warning text, shared by the one call site so the wording can't drift.
    public static let warningMessage =
        "The lid is closed and the built-in microphone is selected — it may deliver silence while closed. Consider switching microphones or opening the lid."

    /// The record's name for a Core Audio transport type (`kAudioDevicePropertyTransportType`, a FourCC); `nil` = the
    /// device did not resolve or did not answer. Pure, for the `clamshellPreflight` event (#314): the event must show
    /// what the guard saw, so a banner over a Bluetooth headset can be told from a misread one.
    public static func transportName(_ transport: UInt32?) -> String {
        guard let transport else { return "unknown" }
        switch transport {
        case fourCC("bltn"): return "builtIn"
        case fourCC("blue"), fourCC("blea"): return "bluetooth"
        case fourCC("usb "): return "usb"
        case fourCC("virt"): return "virtual"
        case fourCC("grup"), fourCC("fgrp"): return "aggregate"
        case fourCC("ccwd"), fourCC("ccwl"): return "continuity"
        default: return "other"
        }
    }

    /// The `clamshellPreflight` event's detail (#314): the pre-flight's inputs and its verdict. Pure.
    /// `device`: the requested UID, `nil` = the system default. `reason`: `start`, `micSwitch` or `micFollow`.
    public static func preflightRecord(
        lidClosed: Bool, isBuiltInMic: Bool, device: String?, transport: String, reason: String
    ) -> [String: String] {
        [
            "lid": lidClosed ? "closed" : "open",
            "device": device ?? "default",
            "transport": transport,
            "builtIn": isBuiltInMic ? "true" : "false",
            "verdict": shouldWarn(lidClosed: lidClosed, isBuiltInMic: isBuiltInMic) ? "warn" : "none",
            "reason": reason,
        ]
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: - Device queries (NOT unit-testable — require real hardware / IOKit; device-test only)

    /// Whether the lid is currently closed, via the same undocumented-but-stable `IOPMrootDomain`
    /// property (`AppleClamshellState`) `pmset -g` and Activity Monitor read. There is no public
    /// IOKit API for clamshell state; this key has been stable across macOS releases for years.
    /// Fails closed (returns `false` / "lid open") on any read failure, so a lookup failure can
    /// never itself produce a false warning.
    public static func isLidClosed() -> Bool {
        #if canImport(IOKit)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        ) else { return false }
        return (cfValue.takeRetainedValue() as? Bool) ?? false
        #else
        return false
        #endif
    }

    /// Whether the given input device selection (`nil` = system default, matching
    /// `AudioInputDevice`/`AVCaptureDevice.uniqueID` elsewhere in this codebase) resolves to a
    /// built-in mic, via the Core Audio HAL transport type — the same check `SystemTapSession`
    /// already uses for output devices (`isBuiltIn`). Fails closed (returns `false`) on any lookup
    /// failure, for the same reason as `isLidClosed()`.
    public static func isBuiltInMicSelected(deviceId: String?) -> Bool {
        #if canImport(CoreAudio)
        let device: AudioObjectID?
        if let deviceId {
            device = Self.audioObjectID(forUID: deviceId)
        } else {
            device = Self.defaultInputDevice()
        }
        guard let device, device != kAudioObjectUnknown else { return false }
        return Self.isBuiltIn(device)
        #else
        return false
        #endif
    }

    /// The transport of the input the selection resolves to, by `transportName(_:)`: `unknown` when it does not
    /// resolve (the same lookups as `isBuiltInMicSelected(deviceId:)`). For the record only — never a decision.
    public static func inputTransport(deviceId: String?) -> String {
        #if canImport(CoreAudio)
        let device: AudioObjectID? = deviceId.map { Self.audioObjectID(forUID: $0) } ?? Self.defaultInputDevice()
        guard let device, device != kAudioObjectUnknown else { return transportName(nil) }
        return transportName(Self.transportType(device))
        #else
        return transportName(nil)
        #endif
    }

    #if canImport(CoreAudio)
    private static func defaultInputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    private static func audioObjectID(forUID uid: String) -> AudioObjectID? {
        var uidCF = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func isBuiltIn(_ device: AudioObjectID) -> Bool {
        transportType(device) == kAudioDeviceTransportTypeBuiltIn
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }
    #endif
}
