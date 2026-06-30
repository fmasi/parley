// system-tap-spike — issue #103 phase 1 device validation (read-only).
//
// Stands up a Core Audio *global output* process tap (AudioHardwareCreateProcessTap +
// CATapDescription + a private aggregate device), pulls the captured system-output audio
// via an IOProc, writes it to a mono 16-bit WAV, and prints live RMS in dBFS once a second.
//
// The one empirical question this answers: does an output-device tap capture Continuity
// (iPhone "answer on Mac") telephony + WhatsApp call audio that ScreenCaptureKit returns at
// the noise floor (−57 dB) for? Place a real call and watch the per-second RMS rise.
//
// macOS 14.4+ (Parley floor is 15+). Requires the System Audio Recording TCC grant — run the
// signed .app build (see build.sh / README.md), not a bare `swift run`.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - CoreAudio property helpers

private func fourCC(_ s: OSStatus) -> String {
    // Render an OSStatus as its 4-char code when printable (e.g. 'oush'), else decimal.
    let n = UInt32(bitPattern: s)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "?")' (\(s))"
    }
    return "\(s)"
}

private func defaultOutputDevice() -> AudioObjectID {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    guard st == noErr else { fail("read default output device: \(fourCC(st))") }
    return deviceID
}

private func deviceUID(_ deviceID: AudioObjectID) -> String {
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
    }
    guard st == noErr else { fail("read device UID: \(fourCC(st))") }
    return uid as String
}

private func deviceName(_ deviceID: AudioObjectID) -> String {
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? (name as String) : "?"
}

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

// MARK: - Orphaned aggregate cleanup (private aggregates from a prior crash)

private let aggregateUIDPrefix = "eu.fmasi.parley.spike."

private func sweepOrphanedAggregates() {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return }
    var devices = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return }

    for dev in devices {
        var uid: CFString = "" as CFString
        var usize = UInt32(MemoryLayout<CFString>.size)
        var uaddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(dev, &uaddr, 0, nil, &usize, $0)
        }
        guard st == noErr, (uid as String).hasPrefix(aggregateUIDPrefix) else { continue }
        let dst = AudioHardwareDestroyAggregateDevice(dev)
        print("swept orphaned aggregate \(uid as String): \(dst == noErr ? "ok" : fourCC(dst))")
    }
}

// MARK: - Live RMS stats (written from the realtime IOProc, drained from the timer)

final class Stats {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private var peak: Float = 0
    private(set) var totalFrames: Int = 0
    // Session maxima across all 1-second drain windows, for a clean per-scenario summary.
    private(set) var maxRmsDB: Double = -120
    private(set) var maxPeakDB: Double = -120

    func add(sumSq: Double, count: Int, peak p: Float, frames: Int) {
        lock.lock()
        sumSquares += sumSq
        sampleCount += count
        if p > peak { peak = p }
        totalFrames += frames
        lock.unlock()
    }

    /// Returns (rmsDB, peakDB) for the interval and resets the accumulators.
    func drain() -> (rms: Double, peak: Double) {
        lock.lock()
        let n = sampleCount
        let ss = sumSquares
        let pk = peak
        sumSquares = 0; sampleCount = 0; peak = 0
        lock.unlock()
        let rms = n > 0 ? (ss / Double(n)).squareRoot() : 0
        func db(_ x: Double) -> Double { x > 0 ? max(-120, 20 * log10(x)) : -120 }
        let rmsDB = db(rms), peakDB = db(Double(pk))
        if rmsDB > maxRmsDB { maxRmsDB = rmsDB }
        if peakDB > maxPeakDB { maxPeakDB = peakDB }
        return (rmsDB, peakDB)
    }
}

// MARK: - Minimal mono Int16 WAV writer (deferred header, repaired on close)

final class WavWriter {
    private let handle: FileHandle
    private let rate: UInt32
    private var dataBytes: UInt32 = 0
    let path: String

    init(path: String, sampleRate: UInt32) {
        self.path = path
        self.rate = sampleRate
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            fail("open WAV for writing: \(path)")
        }
        handle = h
        writeHeader()
    }

    func append(_ samples: [Int16]) {
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        handle.write(bytes)
        dataBytes += UInt32(bytes.count)
    }

    func close() {
        handle.seek(toFileOffset: 0)
        writeHeader()
        handle.closeFile()
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }

    private func writeHeader() {
        let channels: UInt16 = 1
        let blockAlign = channels * 2
        let byteRate = rate * UInt32(blockAlign)
        var h = Data()
        h += "RIFF".data(using: .ascii)!; h += le32(36 + dataBytes)
        h += "WAVE".data(using: .ascii)!
        h += "fmt ".data(using: .ascii)!; h += le32(16)
        h += le16(1); h += le16(channels)
        h += le32(rate); h += le32(byteRate)
        h += le16(blockAlign); h += le16(16)
        h += "data".data(using: .ascii)!; h += le32(dataBytes)
        handle.write(h)
    }
}

// MARK: - Main

let args = CommandLine.arguments
let outPath = args.count > 1
    ? args[1]
    : (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/parley-tap-spike.wav")

print("== Parley system-tap-spike (#103 phase 1) ==")
sweepOrphanedAggregates()

let outputDevice = defaultOutputDevice()
let outUID = deviceUID(outputDevice)
print("default output device: \(deviceName(outputDevice)) [\(outUID)]")

// 1. Global output tap, excluding nothing (this process renders no audio).
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.name = "Parley Spike Tap"
tapDesc.isPrivate = true
tapDesc.muteBehavior = .unmuted   // keep the call audible while we record it

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
    fail("AudioHardwareCreateProcessTap: \(fourCC(tapStatus)) — likely missing System Audio Recording TCC grant (run the signed .app build, see README)")
}
print("created process tap \(tapID), uuid \(tapDesc.uuid.uuidString)")

// 2. Private aggregate device wrapping the default output + the tap.
let aggUID = aggregateUIDPrefix + tapDesc.uuid.uuidString
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "Parley Spike Aggregate",
    kAudioAggregateDeviceUIDKey as String: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceIsStackedKey as String: false,
    kAudioAggregateDeviceTapAutoStartKey as String: true,
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: outUID]
    ],
    kAudioAggregateDeviceTapListKey as String: [
        [
            kAudioSubTapDriftCompensationKey as String: true,
            kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
        ]
    ],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    fail("AudioHardwareCreateAggregateDevice: \(fourCC(aggStatus))")
}
print("created aggregate device \(aggID) [\(aggUID)]")

// 3. Read the tap's stream format (output device rate, usually float32 stereo).
var asbd = AudioStreamBasicDescription()
var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var faddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
guard AudioObjectGetPropertyData(tapID, &faddr, 0, nil, &fsize, &asbd) == noErr else {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    fail("read kAudioTapPropertyFormat")
}
let tapRate = UInt32(asbd.mSampleRate)
let tapChannels = Int(asbd.mChannelsPerFrame)
let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
print("tap format: \(asbd.mSampleRate) Hz, \(tapChannels) ch, \(asbd.mBitsPerChannel)-bit, float=\(isFloat)")
guard isFloat, asbd.mBitsPerChannel == 32 else {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    fail("expected float32 tap format; got bits=\(asbd.mBitsPerChannel) float=\(isFloat)")
}

let wav = WavWriter(path: outPath, sampleRate: tapRate)
let stats = Stats()
print("writing mono \(tapRate) Hz WAV → \(outPath)")

// 4. IOProc: average channels → mono, accumulate RMS, append to WAV.
var procID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) {
    _, inInputData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard abl.count > 0 else { return }

    // Determine frame count from the first buffer (mono buffer = one channel's frames).
    let bytesPerFrame = MemoryLayout<Float32>.size
    let interleaved = abl.count == 1 && tapChannels > 1
    let frames: Int
    if interleaved {
        frames = Int(abl[0].mDataByteSize) / (bytesPerFrame * tapChannels)
    } else {
        frames = Int(abl[0].mDataByteSize) / bytesPerFrame
    }
    guard frames > 0 else { return }

    var mono = [Int16](repeating: 0, count: frames)
    var sumSq: Double = 0
    var peak: Float = 0

    if interleaved {
        guard let base = abl[0].mData?.bindMemory(to: Float32.self, capacity: frames * tapChannels) else { return }
        for f in 0..<frames {
            var acc: Float = 0
            for c in 0..<tapChannels { acc += base[f * tapChannels + c] }
            let v = acc / Float(tapChannels)
            sumSq += Double(v) * Double(v)
            if abs(v) > peak { peak = abs(v) }
            mono[f] = Int16(max(-1, min(1, v)) * 32767)
        }
    } else {
        // Non-interleaved: one buffer per channel, each `frames` long.
        let chans = min(tapChannels, abl.count)
        var ptrs: [UnsafePointer<Float32>] = []
        ptrs.reserveCapacity(chans)
        for c in 0..<chans {
            guard let p = abl[c].mData?.bindMemory(to: Float32.self, capacity: frames) else { return }
            ptrs.append(UnsafePointer(p))
        }
        guard !ptrs.isEmpty else { return }
        for f in 0..<frames {
            var acc: Float = 0
            for p in ptrs { acc += p[f] }
            let v = acc / Float(ptrs.count)
            sumSq += Double(v) * Double(v)
            if abs(v) > peak { peak = abs(v) }
            mono[f] = Int16(max(-1, min(1, v)) * 32767)
        }
    }

    stats.add(sumSq: sumSq, count: frames, peak: peak, frames: frames)
    wav.append(mono)
}
guard ioStatus == noErr, let proc = procID else {
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    fail("AudioDeviceCreateIOProcIDWithBlock: \(fourCC(ioStatus))")
}

let startStatus = AudioDeviceStart(aggID, proc)
guard startStatus == noErr else {
    AudioDeviceDestroyIOProcID(aggID, proc)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    fail("AudioDeviceStart: \(fourCC(startStatus))")
}

// 5. Teardown — idempotent, runs on SIGINT or after the optional duration.
var tornDown = false
let teardown = {
    if tornDown { return }
    tornDown = true
    AudioDeviceStop(aggID, proc)
    AudioDeviceDestroyIOProcID(aggID, proc)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    wav.close()
    let secs = Double(stats.totalFrames) / Double(tapRate)
    print(String(format: "\nstopped. wrote %.1f s to %@", secs, wav.path))
    print(String(format: "session max — rms %.1f dBFS, peak %.1f dBFS  (floor ≈ −120)",
                 stats.maxRmsDB, stats.maxPeakDB))
}

let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler { teardown(); exit(0) }
sigSrc.resume()
signal(SIGINT, SIG_IGN)   // hand SIGINT to the dispatch source instead of the default handler

print("\nrecording — start your test now.")
print("  • baseline silence should read roughly −90 to −120 dBFS")
print("  • a captured call/meeting should jump well above the floor (tens of dB higher)")
print("place an iPhone-relay call, then a WhatsApp call; watch the RMS column. Ctrl-C to stop.\n")
print("elapsed     rms dBFS   peak dBFS")   // note: %s + Swift String in String(format:) crashes

var elapsed = 0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    elapsed += 1
    let (rms, peak) = stats.drain()
    print(String(format: "%6ds    %10.1f  %10.1f", elapsed, rms, peak))
}
timer.resume()

dispatchMain()
