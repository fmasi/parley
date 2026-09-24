import CoreAudio
import Foundation
import os
import TranscriberCore

/// Reads Core Audio's process objects and answers "is any OTHER process running output?" (§4.3).
/// Fails OPEN on any read failure: an unreadable list, or an unreadable process (its
/// `isRunningOutput` stays nil and `OutputActivity` counts it as running). Read once per watchdog
/// tick — no property listener: `TrackLivenessMonitor.gateCloseTicks` counts ticks, so the gate
/// must be sampled at exactly the watchdog's 1 Hz, never on a process-list change as well.
final class OutputActivityProbe {
    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var v: UInt32 = 0; var size = UInt32(4); var a = address(sel)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var a = address(sel, scope); var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return nil }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard size == 0 || AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return nil }
        return out
    }

    /// nil = the process list is unreadable (caller fails open).
    func snapshot() -> [OutputActivity.ProcessOutputState]? {
        guard let procs = Self.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return nil }
        return procs.map { p in
            OutputActivity.ProcessOutputState(
                pid: Int32(bitPattern: Self.u32(p, kAudioProcessPropertyPID) ?? 0),
                // `.map`, never `== 1`: a failed read must stay nil so the process counts as running (fail-open, C3 round 1).
                isRunningOutput: Self.u32(p, kAudioProcessPropertyIsRunningOutput).map { $0 == 1 },
                outputDevices: Self.ids(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput) ?? []
            )
        }
    }

    func othersRunningOutput() -> Bool {
        guard let states = snapshot() else {
            Logger.audio.error("Output activity: process list unreadable — assuming output is running")
            return true
        }
        return OutputActivity.othersRunningOutput(states, ownPid: getpid())
    }
}
