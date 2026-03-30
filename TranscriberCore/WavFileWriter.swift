import Foundation

public final class WavFileWriter {
    private let fileHandle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var sampleRate: UInt32 = 0

    public init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writeHeader(sampleRate: 16000, dataSize: 0)
    }

    public func setSampleRate(_ rate: UInt32) {
        sampleRate = rate
    }

    public func append(_ samples: UnsafeBufferPointer<Float32>) {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        let bytes = pcm.withUnsafeBytes { Data($0) }
        fileHandle.write(bytes)
        dataByteCount += UInt32(bytes.count)
    }

    public func finalize() {
        let rate = sampleRate > 0 ? sampleRate : 16000
        fileHandle.seek(toFileOffset: 0)
        writeHeader(sampleRate: rate, dataSize: dataByteCount)
        fileHandle.seekToEndOfFile()
        fileHandle.closeFile()
    }

    private func writeHeader(sampleRate: UInt32, dataSize: UInt32) {
        let byteRate = sampleRate * 2
        var h = Data()
        h += "RIFF".data(using: .ascii)!;  h += le32(36 + dataSize)
        h += "WAVE".data(using: .ascii)!
        h += "fmt ".data(using: .ascii)!;  h += le32(16)
        h += le16(1);  h += le16(1)
        h += le32(sampleRate);  h += le32(byteRate)
        h += le16(2);  h += le16(16)
        h += "data".data(using: .ascii)!;  h += le32(dataSize)
        fileHandle.write(h)
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
}
