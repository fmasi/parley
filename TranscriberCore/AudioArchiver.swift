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
    /// - Parameter preserveSourceWAV: keep the uncompressed source WAVs after archiving.
    ///   Diagnostic use: the archive is lossy, and speaker-embedding quality (diarization)
    ///   appears far more sensitive to that than intelligibility is.
    public static func archive(
        systemAudio: URL,
        micAudio: URL,
        outputDirectory: URL,
        bitrateKbps: Int,
        preserveSourceWAV: Bool = false
    ) async throws -> AudioArchiveResult {
        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent("\(baseName).m4a")

        Logger.files.info("AudioArchiver: starting archive '\(baseName, privacy: .sensitive)'")

        // 1. Open both WAVs (no bulk load — files are streamed in blocks).
        let micFile: AVAudioFile
        let sysFile: AVAudioFile
        do {
            micFile = try AVAudioFile(forReading: micAudio)
        } catch {
            throw AudioArchiverError.cannotReadAudio("mic: \(error.localizedDescription)")
        }
        do {
            sysFile = try AVAudioFile(forReading: systemAudio)
        } catch {
            throw AudioArchiverError.cannotReadAudio("system: \(error.localizedDescription)")
        }

        // Both streams MUST agree on rate before we encode them into one interleaved file.
        //
        // This used to take the mic's rate and never look at the system file's. `AVAudioFile.read(into:)`
        // does not enforce the "formats must match" the docs describe — with a mismatched-rate buffer it
        // neither throws nor resamples, it raw-copies frames. So a divergent pair encoded "successfully":
        // the system channel came out pitch-shifted and half-length, the .m4a was structurally perfect,
        // verification passed, and BOTH source WAVs were deleted at step 5. That is unrecoverable — the
        // lossless header-rewrite rescue (gotcha #58) needs the original WAV, and after this ran only a
        // lossy AAC of wrong-rate content remained.
        //
        // A rate mismatch means we do not understand our own inputs. On a courtroom-grade artifact the
        // only safe response is to refuse and keep both sources.
        let sampleRate = micFile.processingFormat.sampleRate
        let systemRate = sysFile.processingFormat.sampleRate
        guard sampleRate == systemRate else {
            Logger.files.error(
                "AudioArchiver: refusing to archive — mic is \(sampleRate, privacy: .public)Hz but system is \(systemRate, privacy: .public)Hz; keeping both WAVs so the recording stays recoverable"
            )
            throw AudioArchiverError.cannotReadAudio(
                "sample rate mismatch: mic \(Int(sampleRate))Hz vs system \(Int(systemRate))Hz"
            )
        }

        // 2. Remove any stale output.
        try? FileManager.default.removeItem(at: outputURL)

        // 3. Stream-encode to AAC.
        do {
            try await streamEncodeAAC(
                micFile: micFile,
                sysFile: sysFile,
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

        // 4. Verify output — including that it is as long as the longer source, since step 5 deletes
        //    the only lossless copies and a truncated encode would otherwise pass silently.
        let expectedSeconds = Double(max(micFile.length, sysFile.length)) / sampleRate
        do {
            try await verify(outputURL: outputURL, expectedSeconds: expectedSeconds)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        // 5. Delete source WAVs (unless explicitly preserved for diagnostics).
        if preserveSourceWAV {
            Logger.files.info("AudioArchiver: preserving source WAVs (preserve_source_wav)")
        } else {
            try? FileManager.default.removeItem(at: systemAudio)
            try? FileManager.default.removeItem(at: micAudio)
        }

        Logger.files.info("AudioArchiver: done — \(outputURL.lastPathComponent)")
        return AudioArchiveResult(archivePath: outputURL)
    }

    /// Encode a single mono WAV (system audio only — no mic stream) into a stereo AAC .m4a
    /// and delete the source WAV on success.
    ///
    /// WAV is only a transient crash-resiliency format; single-stream chunks must still flush to
    /// .m4a so no lossless WAV is left behind wasting space (#59). The output keeps the standard
    /// L=mic, R=system channel layout — the mic (left) channel is silent — so `AudioSourceResolver`
    /// reads it back identically to a dual-stream archive.
    public static func archiveSystemOnly(
        systemAudio: URL,
        outputDirectory: URL,
        bitrateKbps: Int,
        preserveSourceWAV: Bool = false
    ) async throws -> AudioArchiveResult {
        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent("\(baseName).m4a")

        Logger.files.info("AudioArchiver: starting system-only archive '\(baseName, privacy: .sensitive)'")

        let sysFile: AVAudioFile
        do {
            sysFile = try AVAudioFile(forReading: systemAudio)
        } catch {
            throw AudioArchiverError.cannotReadAudio("system: \(error.localizedDescription)")
        }

        let sampleRate = sysFile.processingFormat.sampleRate

        try? FileManager.default.removeItem(at: outputURL)

        do {
            try await streamEncodeAAC(
                micFile: nil,
                sysFile: sysFile,
                sampleRate: sampleRate,
                outputURL: outputURL,
                bitrateKbps: bitrateKbps
            )
        } catch {
            // Keep WAV on failure.
            Logger.files.error("AudioArchiver: system-only encoding failed — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioArchiverError.encodingFailed(error.localizedDescription)
        }

        // Same duration check as the dual-stream path — this one deletes the only lossless copy too,
        // and it is the path crash-recovery and salvage batches take, so it is MORE exposed to a
        // compromised capture, not less.
        do {
            let expectedSeconds = sampleRate > 0 ? Double(sysFile.length) / sampleRate : nil
            try await verify(outputURL: outputURL, expectedSeconds: expectedSeconds)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        if preserveSourceWAV {
            Logger.files.info("AudioArchiver: preserving source WAV (preserve_source_wav)")
        } else {
            try? FileManager.default.removeItem(at: systemAudio)
        }

        Logger.files.info("AudioArchiver: done (system-only) — \(outputURL.lastPathComponent)")
        return AudioArchiveResult(archivePath: outputURL)
    }

    /// A system + optional-mic segment to archive.
    public struct SegmentPair: Sendable {
        public let system: URL
        public let mic: URL?
        public init(system: URL, mic: URL?) {
            self.system = system
            self.mic = mic
        }
    }

    /// Archive every contributing segment, returning one audio URL per segment in input order.
    ///
    /// Each pair is isolated: a per-segment failure keeps that segment's source WAV and still
    /// returns it, so a single bad segment never drops the others or throws (#93). A system-only
    /// pair (no mic) is still flushed to .m4a via `archiveSystemOnly` — it must NOT be left as a raw
    /// .wav (#105, extending #59's single-stream flush to this crash-recovery/CLI batch path).
    public static func archiveAll(
        pairs: [SegmentPair],
        outputDirectory: URL,
        bitrateKbps: Int,
        preserveSourceWAV: Bool = false
    ) async -> [URL] {
        var results: [URL] = []
        for pair in pairs {
            do {
                let archived: AudioArchiveResult
                if let mic = pair.mic {
                    archived = try await archive(
                        systemAudio: pair.system,
                        micAudio: mic,
                        outputDirectory: outputDirectory,
                        bitrateKbps: bitrateKbps,
                        preserveSourceWAV: preserveSourceWAV
                    )
                } else {
                    archived = try await archiveSystemOnly(
                        systemAudio: pair.system,
                        outputDirectory: outputDirectory,
                        bitrateKbps: bitrateKbps,
                        preserveSourceWAV: preserveSourceWAV
                    )
                }
                results.append(archived.archivePath)
            } catch {
                Logger.files.error("archiveAll: segment '\(pair.system.lastPathComponent, privacy: .sensitive)' failed, keeping WAV: \(error.localizedDescription, privacy: .public)")
                results.append(pair.system)
            }
        }
        return results
    }

    // MARK: - Private helpers

    /// Stream both mono WAVs into a stereo AAC .m4a via AVAssetWriter.
    /// Reads fixed-size blocks, interleaves on the fly, and releases each block
    /// before reading the next. Memory usage is O(blockFrames) — ~1 MB.
    ///
    /// `micFile` is optional: when nil (system-only archive, #59) the left/mic channel is silent.
    private static func streamEncodeAAC(
        micFile: AVAudioFile?,
        sysFile: AVAudioFile,
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

        // Block size: 65536 frames (~1.4s at 48kHz, ~512KB stereo float32).
        let blockFrames: AVAudioFrameCount = 65536
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Reusable read buffers — allocated once, refilled each iteration.
        guard let micBlock = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: blockFrames),
              let sysBlock = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: blockFrames) else {
            throw AudioArchiverError.encodingFailed("Cannot allocate read buffers")
        }

        let totalFrames = max(micFile?.length ?? 0, sysFile.length)
        var frameOffset: Int64 = 0

        // Build ASBD for interleaved stereo Float32.
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

        // Reusable interleave buffer.
        var stereoBlock = [Float](repeating: 0, count: Int(blockFrames) * 2)

        while frameOffset < totalFrames {
            guard input.isReadyForMoreMediaData else {
                await Task.yield()
                continue
            }

            let framesToProcess = Int(min(Int64(blockFrames), totalFrames - frameOffset))

            // Read mic block (zeros past EOF, or always silent when there is no mic file).
            let micFrames: Int
            if let micFile, micFile.framePosition < micFile.length {
                let toRead = AVAudioFrameCount(min(
                    Int64(framesToProcess),
                    micFile.length - micFile.framePosition
                ))
                try micFile.read(into: micBlock, frameCount: toRead)
                micFrames = Int(micBlock.frameLength)
            } else {
                micFrames = 0
            }

            // Read system block (zeros past EOF).
            let sysFrames: Int
            if sysFile.framePosition < sysFile.length {
                let toRead = AVAudioFrameCount(min(
                    Int64(framesToProcess),
                    sysFile.length - sysFile.framePosition
                ))
                try sysFile.read(into: sysBlock, frameCount: toRead)
                sysFrames = Int(sysBlock.frameLength)
            } else {
                sysFrames = 0
            }

            // Interleave [L=mic, R=system], padding shorter channel with silence.
            let micPtr = micBlock.floatChannelData?[0]
            let sysPtr = sysBlock.floatChannelData?[0]
            for i in 0..<framesToProcess {
                stereoBlock[i * 2]     = i < micFrames ? micPtr![i] : 0  // L = mic
                stereoBlock[i * 2 + 1] = i < sysFrames ? sysPtr![i] : 0  // R = system
            }

            let byteCount = framesToProcess * 2 * MemoryLayout<Float>.size
            let pts = CMTime(value: CMTimeValue(frameOffset), timescale: CMTimeScale(sampleRate))

            // Copy interleaved chunk into a CMBlockBuffer.
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

            let writeStatus = stereoBlock.withUnsafeBufferPointer { ptr in
                CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress!,
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
                sampleCount: CMItemCount(framesToProcess),
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
            guard sampleStatus == noErr, let sb = sampleBuffer else {
                throw AudioArchiverError.encodingFailed("CMSampleBuffer create failed (\(sampleStatus))")
            }

            input.append(sb)
            frameOffset += Int64(framesToProcess)
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

    /// Verify the output .m4a is non-empty, has an audio track, and is as long as its sources.
    ///
    /// "Non-empty with a track" is far too weak a bar to justify what happens next — deleting the
    /// only lossless copy of a meeting. A truncated or half-encoded archive satisfies it perfectly.
    /// Comparing the encoded duration against the source duration is the check that makes the word
    /// "verified" in gotcha #38 mean something, and it catches short encodes generally, not just the
    /// rate-mismatch case that motivated it.
    ///
    /// `expectedSeconds` is nil only where no source duration is available; the duration check is
    /// then skipped rather than guessed at.
    private static func verify(outputURL: URL, expectedSeconds: Double? = nil) async throws {
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

        guard let expectedSeconds, expectedSeconds > 0 else { return }
        let duration = try await asset.load(.duration)
        let actualSeconds = CMTimeGetSeconds(duration)
        guard actualSeconds.isFinite, actualSeconds > 0 else {
            throw AudioArchiverError.verificationFailed("Output duration is unreadable")
        }
        // AAC pads to a whole packet (1024 frames) and the encoder can add priming, so allow a
        // second of slack. The failures worth catching are proportional, not marginal.
        let tolerance = 1.0
        guard abs(actualSeconds - expectedSeconds) <= tolerance else {
            throw AudioArchiverError.verificationFailed(
                "Output is \(String(format: "%.1f", actualSeconds))s but sources are \(String(format: "%.1f", expectedSeconds))s"
            )
        }
    }
}
