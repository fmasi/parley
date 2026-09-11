import AVFoundation

/// Represents an audio input device. `id` is `nil` for the "System Default" sentinel.
public struct AudioInputDevice: Equatable, Identifiable, Sendable {
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }

    /// The sentinel ID representing "use system default input device."
    public static let systemDefaultID: String? = nil
}

public enum AudioDeviceEnumerator {

    /// Returns all available audio input devices, with "System Default" as the first entry.
    ///
    /// BLOCKS on the CoreAudio HAL, for as long as a wedged device holds it — never call on the main
    /// thread. The app reads `AudioDeviceCatalog`, which runs this in the background (#192, gotcha #68).
    public static func availableDevices() -> [AudioInputDevice] {
        var result = [AudioInputDevice(id: nil, name: "System Default")]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        for device in discovery.devices {
            // Filter out virtual aggregate devices (e.g. CADefaultDeviceAggregate)
            // created internally by CoreAudio — they're not real mics and can hang.
            if device.uniqueID.contains("Aggregate") { continue }
            result.append(AudioInputDevice(id: device.uniqueID, name: device.localizedName))
        }
        return result
    }

    /// The row shown for a selected mic the device list does not contain (yet).
    public static let placeholderName = "Previously used microphone"

    /// Like `resolveDeviceId(lastUsed:available:)`, but only trusts a FRESH scan to say the device is
    /// gone. When the scan did not finish in time (a stuck device, #192) the list is just the last known
    /// one, and dropping the id there would silently record on the wrong mic — so it is kept.
    public static func resolveDeviceId(
        lastUsed: String?,
        available: [AudioInputDevice],
        listIsFresh: Bool
    ) -> String? {
        listIsFresh ? resolveDeviceId(lastUsed: lastUsed, available: available) : lastUsed
    }

    /// `devices`, plus a placeholder row for `selected` if the list lacks it, so a picker never holds a
    /// selection it has no row for.
    public static func listing(_ devices: [AudioInputDevice], keeping selected: String?) -> [AudioInputDevice] {
        guard let selected, !devices.contains(where: { $0.id == selected }) else { return devices }
        return devices + [AudioInputDevice(id: selected, name: placeholderName)]
    }

    /// Given the last-used device ID and the currently available devices,
    /// return the device ID to pre-select. Returns `nil` (system default)
    /// if the last-used device is no longer available.
    public static func resolveDeviceId(
        lastUsed: String?,
        available: [AudioInputDevice]
    ) -> String? {
        guard let lastUsed else { return nil }
        if available.contains(where: { $0.id == lastUsed }) {
            return lastUsed
        }
        return nil // fall back to system default
    }
}
