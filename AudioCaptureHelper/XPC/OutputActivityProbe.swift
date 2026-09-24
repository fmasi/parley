import CoreAudio
import Foundation
import os
import TranscriberCore

/// Reads Core Audio's process objects and answers "is any OTHER process running output?" (§4.3).
/// Lean (H review round 1): `IsRunningOutput` first, the pid only for a process that runs output,
/// and the scan stops at the first other one — see `OutputActivity.othersRunningOutput(processes:…)`,
/// which also owns the fail-OPEN rule. Read once per watchdog tick — no property listener:
/// `TrackLivenessMonitor.gateCloseTicks` counts ticks, so the gate must be sampled at exactly the
/// watchdog's 1 Hz, never on a process-list change as well. Confined to the watchdog's queue.
final class OutputActivityProbe {
    /// The unreadable-list error is logged once per episode, not once a second.
    private var unreadableLogged = false

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var v: UInt32 = 0; var size = UInt32(4); var a = address(sel)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var a = address(sel); var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return nil }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard size == 0 || AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return nil }
        // The list can shrink between the two calls: keep only what the second one wrote.
        out = Array(out.prefix(Int(size) / 4))
        return out
    }

    func othersRunningOutput() -> Bool {
        let processes = Self.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        if processes == nil {
            if !unreadableLogged {
                unreadableLogged = true
                Logger.audio.error("Output activity: process list unreadable — assuming output is running")
            }
        } else {
            unreadableLogged = false
        }
        return OutputActivity.othersRunningOutput(
            processes: processes, ownPid: getpid(),
            // `.map`, never `== 1` alone: a failed read stays nil so the process counts as running (fail-open, C3 round 1).
            isRunningOutput: { Self.u32($0, kAudioProcessPropertyIsRunningOutput).map { $0 == 1 } },
            pid: { Self.u32($0, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } })
    }
}
