import Foundation
import Testing
@testable import TranscriberCore

/// L10 (§8.7): disk is checked before start and at every rotation; the diskLow alarm has hysteresis
/// so a rotation right at the threshold does not flap (scan C17).
@Suite struct DiskSpaceCheckTests {
    @Test func bytesPerChunkIsTwoTracksAt96KBps() {
        #expect(DiskSpaceCheck.bytesPerChunk(chunkMinutes: 10) == 10 * 60 * 2 * 96_000)
    }
    @Test func startNeedsTwoChunksPlusHeadroom() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.canStart(freeBytes: 2 * one + 200_000_000, chunkMinutes: 30))
        #expect(!DiskSpaceCheck.canStart(freeBytes: 2 * one + 199_000_000, chunkMinutes: 30))
    }
    @Test func rotationWarnsBelowOneChunk() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one - 1, chunkMinutes: 30, currentlyLow: false) == .low)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: 2 * one, chunkMinutes: 30, currentlyLow: false) == .ok)
    }
    @Test func diskLowClearsOnlyAtTwoChunks() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one + 1, chunkMinutes: 30, currentlyLow: true) == .low, "between 1 and 2 chunks: still low")
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: 2 * one, chunkMinutes: 30, currentlyLow: true) == .ok)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one + 1, chunkMinutes: 30, currentlyLow: false) == .ok, "not yet low: 1–2 chunks is fine")
    }
    @Test func theRealVolumeAnswers() {
        #expect((DiskSpaceCheck.freeBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }
    @Test func messageNamesTheNumbers() {
        let m = DiskSpaceCheck.message(freeBytes: 100_000_000, chunkMinutes: 10)
        #expect(m.contains("100 MB") && m.contains("10-minute"))
    }
}
