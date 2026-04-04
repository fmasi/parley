import Foundation
import os

public final class WavFileWriter {
    private let fileHandle: FileHandle
    public let path: String
    private var dataByteCount: UInt32 = 0
    private var sampleRate: UInt32 = 0
    private var channelCount: UInt16 = 1
    private var firstWriteLogged = false
    private var overflowWarned = false
    // WAV format uses 32-bit size fields; max data payload is ~4.29 GB.
    private static let maxDataBytes: UInt32 = UInt32.max - 36
    private var lastSyncTime: ContinuousClock.Instant = .now
    private static let syncInterval: Duration = .milliseconds(500)

    public init(path: String) throws {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writeHeader(sampleRate: 16000, channels: 1, dataSize: 0)
        Logger.files.debug("WAV writer created: \(path, privacy: .private)")
    }

    public func setSampleRate(_ rate: UInt32) {
        sampleRate = rate
    }

    public func setChannelCount(_ channels: UInt16) {
        channelCount = channels
    }

    public func append(_ samples: UnsafeBufferPointer<Float32>) {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        let bytes = pcm.withUnsafeBytes { Data($0) }
        guard let toWrite = clampedData(bytes) else { return }
        fileHandle.write(toWrite)
        dataByteCount += UInt32(toWrite.count)
        logFirstWrite()
        syncIfNeeded()
    }

    /// Write Int16 PCM samples directly (no conversion needed).
    public func appendInt16(_ samples: UnsafeBufferPointer<Int16>) {
        let bytes = samples.withMemoryRebound(to: UInt8.self) { Data($0) }
        guard let toWrite = clampedData(bytes) else { return }
        fileHandle.write(toWrite)
        dataByteCount += UInt32(toWrite.count)
        logFirstWrite()
        syncIfNeeded()
    }

    /// Returns data clamped to remaining WAV capacity, or nil if full.
    private func clampedData(_ bytes: Data) -> Data? {
        let remaining = Self.maxDataBytes - dataByteCount
        guard remaining > 0 else {
            if !overflowWarned {
                Logger.audio.warning("WAV 4 GB limit reached, dropping samples: \(self.path, privacy: .private)")
                overflowWarned = true
            }
            return nil
        }
        if bytes.count > remaining {
            if !overflowWarned {
                Logger.audio.warning("WAV 4 GB limit reached, truncating final write: \(self.path, privacy: .private)")
                overflowWarned = true
            }
            return bytes.prefix(Int(remaining))
        }
        return bytes
    }

    private func syncIfNeeded() {
        let now = ContinuousClock.Instant.now
        guard now - lastSyncTime >= Self.syncInterval else { return }
        fileHandle.synchronizeFile()
        lastSyncTime = now
    }

    private func logFirstWrite() {
        guard !firstWriteLogged else { return }
        firstWriteLogged = true
        let rate = sampleRate > 0 ? sampleRate : 16000
        Logger.files.info("WAV first write — sampleRate: \(rate), channels: \(self.channelCount), path: \(self.path, privacy: .private)")
    }

    public func finalize() {
        let rate = sampleRate > 0 ? sampleRate : 16000
        fileHandle.seek(toFileOffset: 0)
        writeHeader(sampleRate: rate, channels: channelCount, dataSize: dataByteCount)
        fileHandle.seekToEndOfFile()
        fileHandle.closeFile()
        Logger.files.info("WAV finalized: \(self.path, privacy: .private), size: \(self.dataByteCount) bytes")
    }

    private func writeHeader(sampleRate: UInt32, channels: UInt16, dataSize: UInt32) {
        let blockAlign = channels * 2  // 16-bit samples
        let byteRate = sampleRate * UInt32(blockAlign)
        var h = Data()
        h += "RIFF".data(using: .ascii)!;  h += le32(36 + dataSize)
        h += "WAVE".data(using: .ascii)!
        h += "fmt ".data(using: .ascii)!;  h += le32(16)
        h += le16(1);  h += le16(channels)
        h += le32(sampleRate);  h += le32(byteRate)
        h += le16(blockAlign);  h += le16(16)
        h += "data".data(using: .ascii)!;  h += le32(dataSize)
        fileHandle.write(h)
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
}
