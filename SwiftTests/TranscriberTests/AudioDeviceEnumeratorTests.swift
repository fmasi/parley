import Testing
@testable import TranscriberCore

/// Protocol-based testing — we test the logic without requiring real hardware.
struct AudioDeviceEnumeratorTests {

    @Test func systemDefaultIsAlwaysFirst() {
        let devices = AudioDeviceEnumerator.availableDevices()
        guard let first = devices.first else {
            Issue.record("Expected at least the System Default entry")
            return
        }
        #expect(first.id == AudioInputDevice.systemDefaultID)
        #expect(first.name == "System Default")
    }

    @Test func systemDefaultIDIsNil() {
        #expect(AudioInputDevice.systemDefaultID == nil)
    }

    @Test func audioInputDeviceEquatable() {
        let a = AudioInputDevice(id: "abc", name: "Mic A")
        let b = AudioInputDevice(id: "abc", name: "Mic A")
        let c = AudioInputDevice(id: "xyz", name: "Mic B")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func resolveDeviceIdReturnsNilForSystemDefault() {
        let resolved = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: nil, available: [
                AudioInputDevice(id: nil, name: "System Default"),
                AudioInputDevice(id: "usb-mic", name: "USB Mic"),
            ]
        )
        #expect(resolved == nil)
    }

    @Test func resolveDeviceIdPreselectsLastUsed() {
        let resolved = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: "usb-mic", available: [
                AudioInputDevice(id: nil, name: "System Default"),
                AudioInputDevice(id: "usb-mic", name: "USB Mic"),
            ]
        )
        #expect(resolved == "usb-mic")
    }

    @Test func resolveDeviceIdFallsBackWhenLastUsedMissing() {
        let resolved = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: "unplugged-mic", available: [
                AudioInputDevice(id: nil, name: "System Default"),
                AudioInputDevice(id: "usb-mic", name: "USB Mic"),
            ]
        )
        #expect(resolved == nil)
    }
}
