import Foundation
@testable import TranscriberCore

enum RecoveryFixtures {
    static func writeSessionJSON(dir: URL, sessionId: String, meetingStart: Date, chunkIndices: [Int]) throws {
        let chunks = chunkIndices.map { i in
            ProcessedChunk(index: i, startTime: meetingStart.addingTimeInterval(Double(i) * 60),
                audioPath: "\(sessionId)-\(i).m4a",
                segments: [.init(start: 0, end: 5, text: "chunk \(i)", speaker: "Speaker 1", source: "remote", qualityScore: 1)],
                speakerDatabase: ["Speaker 1": [Float(i), 0, 0]], localSpeakerDatabase: [:],
                echoSegmentsRemoved: 0, isDualStream: false)
        }
        let state = SessionState(sessionId: sessionId, meetingStart: meetingStart, engine: "fluidAudio",
                                 chunkDurationMinutes: 1, chunks: chunks)
        try SessionState.write(state, directory: dir)
    }
    static func writeFakeWav(at url: URL, seconds: Double) throws {
        let sr = 48_000, ch = 1, bits = 16, frames = Int(seconds * 48_000), dataBytes = frames * ch * bits / 8
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var h = Data()
        h.append("RIFF".data(using: .ascii)!); h.append(le(UInt32(36 + dataBytes))); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); h.append(le(UInt32(16))); h.append(le(UInt16(1))); h.append(le(UInt16(ch)))
        h.append(le(UInt32(sr))); h.append(le(UInt32(sr * ch * bits / 8))); h.append(le(UInt16(ch * bits / 8))); h.append(le(UInt16(bits)))
        h.append("data".data(using: .ascii)!); h.append(le(UInt32(dataBytes))); h.append(Data(count: dataBytes))
        try h.write(to: url)
    }
}
