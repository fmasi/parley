import AVFoundation
import CoreMedia
import os

// MARK: - Public API

public struct AudioArchiveResult: Sendable {
    public let archivePath: URL
}

public enum AudioArchiverError: LocalizedError {
    case cannotReadAudio(String)
    case encodingFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotReadAudio(let msg): return "Cannot read audio: \(msg)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .verificationFailed(let msg): return "Verification failed: \(msg)"
        }
    }
}

// MARK: - AudioArchiver

/// Combines two mono WAV files (system audio + mic) into a stereo AAC .m4a archive.
/// Channel convention: L = mic (local), R = system (remote).
public enum AudioArchiver {

    /// Encode both WAVs to a stereo AAC .m4a and delete the source WAVs on success.
    public static func archive(
        systemAudio: URL,
        micAudio: URL,
        outputDirectory: URL,
        bitrateKbps: Int
    ) async throws -> AudioArchiveResult {
        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent("\(baseName).m4a")

        Logger.files.info("AudioArchiver: starting archive '\(baseName)'")

        // 1. Read both WAVs into Float32 PCM buffers.
        let (micBuffer, sampleRate) = try readMonoFloat32(url: micAudio, label: "mic")
        let (sysBuffer, _) = try readMonoFloat32(url: systemAudio, label: "system")

        // 2. Interleave into stereo [L=mic, R=system].
        let stereoBuffer = try interleave(mic: micBuffer, system: sysBuffer)

        // 3. Remove any stale output.
        try? FileManager.default.removeItem(at: outputURL)

        // 4. Encode to AAC.
        do {
            try await encodeAAC(
                stereoBuffer: stereoBuffer,
                sampleRate: sampleRate,
                outputURL: outputURL,
                bitrateKbps: bitrateKbps
            )
        } catch {
            // Keep WAVs on failure.
            Logger.files.error("AudioArchiver: encoding failed — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioArchiverError.encodingFailed(error.localizedDescription)
        }

        // 5. Verify output.
        try await verify(outputURL: outputURL)

        // 6. Delete source WAVs.
        try? FileManager.default.removeItem(at: systemAudio)
        try? FileManager.default.removeItem(at: micAudio)

        Logger.files.info("AudioArchiver: done — \(outputURL.lastPathComponent)")
        return AudioArchiveResult(archivePath: outputURL)
    }

    // MARK: - Private helpers

    /// Read a mono WAV into a [Float] array. Returns (samples, sampleRate).
    private static func readMonoFloat32(url: URL, label: String) throws -> ([Float], Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioArchiverError.cannotReadAudio("\(label): \(error.localizedDescription)")
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioArchiverError.cannotReadAudio("\(label): cannot allocate buffer")
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw AudioArchiverError.cannotReadAudio("\(label): read failed — \(error.localizedDescription)")
        }

        let count = Int(buffer.frameLength)
        guard let ptr = buffer.floatChannelData?[0] else {
            throw AudioArchiverError.cannotReadAudio("\(label): no float channel data")
        }
        let samples = Array(UnsafeBufferPointer(start: ptr, count: count))
        return (samples, file.processingFormat.sampleRate)
    }

    /// Interleave mic (L) and system (R) samples into a stereo buffer.
    /// Pads the shorter channel with silence.
    private static func interleave(mic: [Float], system: [Float]) throws -> [Float] {
        let frameCount = max(mic.count, system.count)
        var stereo = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            stereo[i * 2]     = i < mic.count    ? mic[i]    : 0  // L = mic
            stereo[i * 2 + 1] = i < system.count ? system[i] : 0  // R = system
        }
        return stereo
    }

    /// Encode interleaved stereo Float32 samples to AAC .m4a via AVAssetWriter.
    private static func encodeAAC(
        stereoBuffer: [Float],
        sampleRate: Double,
        outputURL: URL,
        bitrateKbps: Int
    ) async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw AudioArchiverError.encodingFailed("Cannot create writer: \(error.localizedDescription)")
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitrateKbps * 1000
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard writer.startWriting() else {
            throw AudioArchiverError.encodingFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: .zero)

        // Chunk size: 4096 frames per buffer.
        let chunkFrames = 4096
        let totalFrames = stereoBuffer.count / 2
        var offset = 0

        // Build the ASBD for interleaved stereo Float32 at the source sample rate.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,   // 2 channels × 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Create format description.
        var fmtDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmtDesc
        )
        guard fmtStatus == noErr, let formatDescription = fmtDesc else {
            throw AudioArchiverError.encodingFailed("Cannot create format description (OSStatus \(fmtStatus))")
        }

        while offset < totalFrames {
            guard input.isReadyForMoreMediaData else {
                // Yield to the run loop briefly.
                await Task.yield()
                continue
            }

            let framesThisChunk = min(chunkFrames, totalFrames - offset)
            let byteCount = framesThisChunk * 2 * MemoryLayout<Float>.size  // interleaved stereo

            let pts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate))

            // Copy chunk into a CMBlockBuffer.
            var blockBuffer: CMBlockBuffer?
            let allocStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard allocStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
                throw AudioArchiverError.encodingFailed("CMBlockBuffer alloc failed (\(allocStatus))")
            }

            // Fill block buffer with samples.
            let chunkStart = offset * 2
            let writeStatus = stereoBuffer.withUnsafeBufferPointer { ptr in
                CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress! + chunkStart,
                    blockBuffer: bb,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                )
            }
            guard writeStatus == kCMBlockBufferNoErr else {
                throw AudioArchiverError.encodingFailed("CMBlockBuffer write failed (\(writeStatus))")
            }

            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: formatDescription,
                sampleCount: CMItemCount(framesThisChunk),
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
            guard sampleStatus == noErr, let sb = sampleBuffer else {
                throw AudioArchiverError.encodingFailed("CMSampleBuffer create failed (\(sampleStatus))")
            }

            input.append(sb)
            offset += framesThisChunk
        }

        input.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw AudioArchiverError.encodingFailed(
                writer.error?.localizedDescription ?? "finishWriting failed"
            )
        }
    }

    /// Verify the output .m4a is non-empty and has an audio track.
    private static func verify(outputURL: URL) async throws {
        let attr = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attr?[.size] as? Int) ?? 0
        guard size > 0 else {
            throw AudioArchiverError.verificationFailed("Output file is empty")
        }

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw AudioArchiverError.verificationFailed("Output has no audio tracks")
        }
    }
}
