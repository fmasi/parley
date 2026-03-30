import AVFoundation

/// Represents an audio input device. `id` is `nil` for the "System Default" sentinel.
public struct AudioInputDevice: Equatable, Identifiable {
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
    public static func availableDevices() -> [AudioInputDevice] {
        var result = [AudioInputDevice(id: nil, name: "System Default")]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        for device in discovery.devices {
            result.append(AudioInputDevice(id: device.uniqueID, name: device.localizedName))
        }
        return result
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
