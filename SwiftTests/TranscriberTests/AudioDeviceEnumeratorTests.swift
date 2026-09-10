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

    // MARK: - #192: a list that may be stale

    private let available = [
        AudioInputDevice(id: nil, name: "System Default"),
        AudioInputDevice(id: "usb-mic", name: "USB Mic"),
    ]

    @Test func freshScanStillDropsAnUnpluggedMic() {
        #expect(AudioDeviceEnumerator.resolveDeviceId(lastUsed: "unplugged-mic", available: available, listIsFresh: true) == nil)
        #expect(AudioDeviceEnumerator.resolveDeviceId(lastUsed: "usb-mic", available: available, listIsFresh: true) == "usb-mic")
    }

    @Test func staleListKeepsTheLastUsedMic() {
        // The scan didn't finish in time: the mic may well be there. Dropping it would silently record
        // on System Default instead.
        let staleList = [AudioInputDevice(id: nil, name: "System Default")]
        #expect(AudioDeviceEnumerator.resolveDeviceId(lastUsed: "usb-mic", available: staleList, listIsFresh: false) == "usb-mic")
        #expect(AudioDeviceEnumerator.resolveDeviceId(lastUsed: nil, available: staleList, listIsFresh: false) == nil)
    }

    @Test func listingAddsARowForAnUnlistedSelection() {
        let listed = AudioDeviceEnumerator.listing(available, keeping: "iphone-mic")
        #expect(listed.count == 3)
        #expect(listed.last == AudioInputDevice(id: "iphone-mic", name: AudioDeviceEnumerator.placeholderName))
    }

    @Test func listingLeavesAListedOrDefaultSelectionAlone() {
        #expect(AudioDeviceEnumerator.listing(available, keeping: "usb-mic") == available)
        #expect(AudioDeviceEnumerator.listing(available, keeping: nil) == available)
    }
}
