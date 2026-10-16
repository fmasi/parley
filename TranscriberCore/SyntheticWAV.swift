import Foundation

/// A tiny real WAV for smoke tests (engine preflight). Same header layout as the test fixture
/// writer, but with a tone instead of zeros so an engine has something to decode.
public enum SyntheticWAV {
    public static func write(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws {
        let ch = 1, bits = 16
        let frames = Int(seconds * Double(sampleRate))
        let dataBytes = frames * ch * bits / 8
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var h = Data()
        h.append("RIFF".data(using: .ascii)!); h.append(le(UInt32(36 + dataBytes))); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); h.append(le(UInt32(16))); h.append(le(UInt16(1))); h.append(le(UInt16(ch)))
        h.append(le(UInt32(sampleRate))); h.append(le(UInt32(sampleRate * ch * bits / 8))); h.append(le(UInt16(ch * bits / 8))); h.append(le(UInt16(bits)))
        h.append("data".data(using: .ascii)!); h.append(le(UInt32(dataBytes)))
        var samples = Data(capacity: dataBytes)
        let amplitude = 3276.0   // −20 dBFS
        for i in 0..<frames {
            let v = Int16(amplitude * sin(2 * .pi * 440 * Double(i) / Double(sampleRate)))
            samples.append(le(v))
        }
        h.append(samples)
        try h.write(to: url)
    }
}
