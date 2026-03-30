import Testing
import Foundation
@testable import TranscriberCore

struct WavFileWriterTests {
    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("test-\(UUID().uuidString).wav").path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func readData(at path: String) -> Data {
        return FileManager.default.contents(atPath: path) ?? Data()
    }

    // MARK: - WAV header structure

    @Test func writesValidWavHeader() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        writer.finalize()

        let data = readData(at: path)
        // WAV header is 44 bytes minimum
        #expect(data.count == 44)

        // Check RIFF magic
        let riff = String(data: data[0..<4], encoding: .ascii)
        #expect(riff == "RIFF")

        // Check WAVE format
        let wave = String(data: data[8..<12], encoding: .ascii)
        #expect(wave == "WAVE")

        // Check fmt chunk
        let fmt = String(data: data[12..<16], encoding: .ascii)
        #expect(fmt == "fmt ")

        // Check data chunk
        let dataChunk = String(data: data[36..<40], encoding: .ascii)
        #expect(dataChunk == "data")
    }

    @Test func headerContainsCorrectDefaultSampleRate() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        writer.finalize()

        let data = readData(at: path)
        // Sample rate at offset 24 (4 bytes, little-endian)
        let sampleRate: UInt32 = data[24...27].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16000)
    }

    @Test func headerReflectsCustomSampleRate() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        writer.setSampleRate(48000)
        writer.finalize()

        let data = readData(at: path)
        let sampleRate: UInt32 = data[24...27].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 48000)
    }

    // MARK: - Audio format fields

    @Test func headerHasPCMFormat() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        writer.finalize()

        let data = readData(at: path)
        // Audio format at offset 20 (2 bytes LE) — 1 = PCM
        let audioFormat: UInt16 = data[20...21].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(audioFormat == 1)

        // Channels at offset 22 (2 bytes LE) — 1 = mono
        let channels: UInt16 = data[22...23].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1)

        // Bits per sample at offset 34 (2 bytes LE) — 16
        let bitsPerSample: UInt16 = data[34...35].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16)
    }

    // MARK: - Float32 → Int16 conversion

    @Test func appendConvertsFloat32ToInt16() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        // Write 4 samples: silence, max, min, mid
        let samples: [Float32] = [0.0, 1.0, -1.0, 0.5]
        samples.withUnsafeBufferPointer { writer.append($0) }
        writer.finalize()

        let data = readData(at: path)
        // Data starts at offset 44
        #expect(data.count == 44 + 8)  // 4 samples × 2 bytes each

        let pcm: [Int16] = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(pcm[0] == 0)       // silence
        #expect(pcm[1] == 32767)   // max positive
        #expect(pcm[2] == -32767)  // max negative
        #expect(pcm[3] == 16383)   // mid-range (0.5 × 32767 truncated)
    }

    @Test func appendClampsBeyondRange() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        let samples: [Float32] = [2.0, -3.0]  // beyond [-1, 1]
        samples.withUnsafeBufferPointer { writer.append($0) }
        writer.finalize()

        let data = readData(at: path)
        let pcm: [Int16] = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(pcm[0] == 32767)   // clamped to max
        #expect(pcm[1] == -32767)  // clamped to min
    }

    // MARK: - Data size in header

    @Test func headerReflectsCorrectDataSize() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        let samples: [Float32] = [0.1, 0.2, 0.3]
        samples.withUnsafeBufferPointer { writer.append($0) }
        writer.finalize()

        let data = readData(at: path)
        // Data chunk size at offset 40 (4 bytes LE)
        let dataSize: UInt32 = data[40...43].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(dataSize == 6)  // 3 samples × 2 bytes

        // RIFF chunk size at offset 4 (4 bytes LE) = 36 + dataSize
        let riffSize: UInt32 = data[4...7].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(riffSize == 42)  // 36 + 6
    }

    // MARK: - Multiple appends

    @Test func multipleAppendsAccumulate() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        let batch1: [Float32] = [0.1, 0.2]
        let batch2: [Float32] = [0.3, 0.4, 0.5]
        batch1.withUnsafeBufferPointer { writer.append($0) }
        batch2.withUnsafeBufferPointer { writer.append($0) }
        writer.finalize()

        let data = readData(at: path)
        let dataSize: UInt32 = data[40...43].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(dataSize == 10)  // 5 samples × 2 bytes
    }

    // MARK: - Byte rate

    @Test func byteRateMatchesSampleRateTimesTwo() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        writer.setSampleRate(44100)
        writer.finalize()

        let data = readData(at: path)
        // Byte rate at offset 28 (4 bytes LE) = sampleRate × blockAlign
        let byteRate: UInt32 = data[28...31].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(byteRate == 88200)  // 44100 × 2
    }

    // MARK: - Empty file

    @Test func emptyFileHasZeroDataSize() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try WavFileWriter(path: path)
        writer.finalize()

        let data = readData(at: path)
        let dataSize: UInt32 = data[40...43].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(dataSize == 0)
    }
}
