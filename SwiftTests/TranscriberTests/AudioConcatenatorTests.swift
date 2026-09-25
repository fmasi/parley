// RED-FIRST-EXEMPT: R2c (C-M19) removed the dead AudioConcatenator.concatenate(sources:), which deleted its sources unconditionally; its five callers here were converted to concatenate(chunks:deleteSources: true), a pure refactor of existing tests
import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// `.serialized`: these tests drive AVAssetWriter/AVAssetReader, which are clients of shared media XPC
/// daemons. A timed-out CI run on 2026-09-04 showed 27 such tests starting within six
/// seconds and none ever finishing — a wedged daemon blocks every client forever. Running
/// this suite's cases one at a time reduces how many are ever in flight together.
///
/// NOTE: CI currently also runs the whole suite with `--no-parallel`, because serialising
/// these suites alone cut the frozen set from 27 tests to 15 and did not stop the stall —
/// it is cross-suite. These traits are kept because they document which suites are
/// implicated, and they keep the constraint if parallelism is ever restored.
@Suite(.serialized)
struct AudioConcatenatorTests {

    // MARK: - Helper

    /// Creates a stereo AAC .m4a file at `url` with a sine wave of `durationSeconds`.
    /// Uses AVAssetWriter + CMSampleBuffer to encode PCM directly to AAC without needing
    /// AVAssetExportSession (which requires sandbox entitlements unavailable in test runners).
    private static func createTestM4a(at url: URL, durationSeconds: Double = 1.0, frequency: Double = 440.0) async throws {
        let sampleRate: Double = 44100
        let channels: UInt32 = 2
        let frameCount = Int(sampleRate * durationSeconds)
        // Write in chunks of 4096 frames to satisfy AVAssetWriter requirements
        let chunkSize = 4096

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64000
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw ConcatenatorTestError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Build interleaved Float32 stereo ASBD for CMSampleBuffer
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else {
            throw ConcatenatorTestError.writerFailed("Cannot create format description")
        }

        var samplesWritten = 0
        while samplesWritten < frameCount {
            guard writerInput.isReadyForMoreMediaData else {
                // spin briefly
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            let thisBatch = min(chunkSize, frameCount - samplesWritten)
            let byteCount = thisBatch * Int(channels) * 4  // Float32 = 4 bytes

            // Allocate block buffer and fill with sine wave data
            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard let blockBuffer else {
                throw ConcatenatorTestError.writerFailed("Cannot create block buffer")
            }
            CMBlockBufferAssureBlockMemory(blockBuffer)

            var dataPointer: UnsafeMutablePointer<Int8>?
            var dataLength = 0
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
            if let ptr = dataPointer {
                let floatPtr = UnsafeMutableRawPointer(ptr).bindMemory(to: Float.self, capacity: thisBatch * Int(channels))
                for i in 0..<thisBatch {
                    let sample = Float(sin(2.0 * .pi * frequency * Double(samplesWritten + i) / sampleRate))
                    floatPtr[i * Int(channels)] = sample      // L
                    floatPtr[i * Int(channels) + 1] = sample  // R
                }
            }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(samplesWritten), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(thisBatch),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
            guard let sampleBuffer else {
                throw ConcatenatorTestError.writerFailed("Cannot create sample buffer")
            }
            writerInput.append(sampleBuffer)
            samplesWritten += thisBatch
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw ConcatenatorTestError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    enum ConcatenatorTestError: Error {
        case writerFailed(String)
    }

    // MARK: - Tests

    @Test func singleSourceIsNoOp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("chunk-1.m4a")
        try await Self.createTestM4a(at: source, durationSeconds: 1.0)

        let result = try await AudioConcatenator.concatenate(
            chunks: [source].map { ChunkAudio(url: $0, startTime: nil) },
            outputDirectory: dir,
            outputName: "output",
            deleteSources: true
        )

        #expect(result.outputPath == source)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(result.usedPassthrough == true)
    }

    @Test func concatenatesMultipleSourcesIntoSingleFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sources = try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 1...3 {
                let url = dir.appendingPathComponent("chunk-\(i).m4a")
                group.addTask {
                    try await Self.createTestM4a(at: url, durationSeconds: 1.0, frequency: Double(220 * i))
                    return url
                }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        let result = try await AudioConcatenator.concatenate(
            chunks: sources.map { ChunkAudio(url: $0, startTime: nil) },
            outputDirectory: dir,
            outputName: "merged",
            deleteSources: true
        )

        #expect(result.outputPath.lastPathComponent == "merged.m4a")
        #expect(FileManager.default.fileExists(atPath: result.outputPath.path))

        // Verify it has at least one audio track
        let asset = AVURLAsset(url: result.outputPath)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count >= 1)
    }

    @Test func sourceFilesDeletedAfterConcatenation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source1 = dir.appendingPathComponent("chunk-1.m4a")
        let source2 = dir.appendingPathComponent("chunk-2.m4a")
        try await Self.createTestM4a(at: source1, durationSeconds: 1.0)
        try await Self.createTestM4a(at: source2, durationSeconds: 1.0)

        let result = try await AudioConcatenator.concatenate(
            chunks: [source1, source2].map { ChunkAudio(url: $0, startTime: nil) },
            outputDirectory: dir,
            outputName: "merged",
            deleteSources: true
        )

        #expect(!FileManager.default.fileExists(atPath: source1.path))
        #expect(!FileManager.default.fileExists(atPath: source2.path))
        #expect(FileManager.default.fileExists(atPath: result.outputPath.path))
    }

    @Test func concatenatedDurationApproximatelySumOfSources() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source1 = dir.appendingPathComponent("chunk-1.m4a")
        let source2 = dir.appendingPathComponent("chunk-2.m4a")
        try await Self.createTestM4a(at: source1, durationSeconds: 2.0)
        try await Self.createTestM4a(at: source2, durationSeconds: 3.0)

        let result = try await AudioConcatenator.concatenate(
            chunks: [source1, source2].map { ChunkAudio(url: $0, startTime: nil) },
            outputDirectory: dir,
            outputName: "merged",
            deleteSources: true
        )

        let asset = AVURLAsset(url: result.outputPath)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        #expect(seconds >= 4.5)
        #expect(seconds <= 5.5)
    }

    @Test func emptySourcesThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await AudioConcatenator.concatenate(
                chunks: [],
                outputDirectory: dir,
                outputName: "output",
                deleteSources: true
            )
            Issue.record("Expected concatenate to throw on empty sources")
        } catch AudioConcatenatorError.noSources {
            // Expected
        }
    }

    private func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("concat-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func mixedWavAndM4aSourcesAreRefusedAndNothingIsDeleted() async throws {
        let dir = try tempDir("mixed"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.wav")
        try await Self.createTestM4a(at: a); try RecoveryFixtures.writeFakeWav(at: b, seconds: 1)
        await #expect(throws: AudioConcatenatorError.self) {
            _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)], outputDirectory: dir, outputName: "c", deleteSources: true)
        }
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test func preserveKeepsTheSources() async throws {
        let dir = try tempDir("preserve"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a); try await Self.createTestM4a(at: b)
        _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)], outputDirectory: dir, outputName: "c", deleteSources: false)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    /// P9: a crash restart leaves a gap between chunk 0's end and chunk 1's start; the merged audio
    /// must keep the transcript's wall-clock timeline.
    @Test func gapsBetweenChunksAreFilledWithSilence() async throws {
        let dir = try tempDir("gaps"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a, durationSeconds: 1); try await Self.createTestM4a(at: b, durationSeconds: 1)
        let t0 = Date(timeIntervalSince1970: 0)
        let r = try await AudioConcatenator.concatenate(
            chunks: [ChunkAudio(url: a, startTime: t0), ChunkAudio(url: b, startTime: t0.addingTimeInterval(3))],
            outputDirectory: dir, outputName: "c", deleteSources: true)
        let d = try await AVURLAsset(url: r.outputPath).load(.duration).seconds
        #expect(abs(d - 4) < 0.3)
        #expect(abs(r.gapsInsertedSeconds - 2) < 0.1)
    }

    private func rms(_ url: URL, from: Double, to: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        file.framePosition = AVAudioFramePosition(from * format.sampleRate)
        let count = AVAudioFrameCount((to - from) * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        let p = buffer.floatChannelData![0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += p[i] * p[i] }
        return (sum / Float(max(1, buffer.frameLength))).squareRoot()
    }

    /// R4 review round 1: gaps are measured against each chunk's ABSOLUTE offset from the first,
    /// so sub-second shortfalls cannot add up. Four 1 s chunks 1.6 s apart: each step alone is
    /// under the 1 s threshold, but by chunk 2 the timeline is 1.2 s behind and silence goes in.
    @Test func gapsFollowAbsoluteChunkOffsets() async throws {
        let dir = try tempDir("absgap"); defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 0)
        var chunks: [ChunkAudio] = []
        for i in 0..<4 {
            let url = dir.appendingPathComponent("c-\(i).m4a")
            try await Self.createTestM4a(at: url, durationSeconds: 1)
            chunks.append(ChunkAudio(url: url, startTime: t0.addingTimeInterval(1.6 * Double(i))))
        }
        let r = try await AudioConcatenator.concatenate(chunks: chunks, outputDirectory: dir, outputName: "c", deleteSources: false)
        #expect(abs(r.gapsInsertedSeconds - 1.2) < 0.1)
        #expect(r.usedPassthrough == false, "no passthrough when silence was inserted")
        #expect(try rms(r.outputPath, from: 2.1, to: 3.1) < 0.01, "silence where chunk 2 was late")
        #expect(try rms(r.outputPath, from: 3.3, to: 4.1) > 0.1, "chunk 2 starts at its wall-clock offset")
    }

    /// R0/R2 round ruling (R345 item 8): inputs are ordered by start time, not by the order given.
    @Test func chunksAreOrderedByStartTime() async throws {
        let dir = try tempDir("order"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-5.m4a")
        try await Self.createTestM4a(at: a, durationSeconds: 1); try await Self.createTestM4a(at: b, durationSeconds: 1)
        let t0 = Date(timeIntervalSince1970: 0)
        let r = try await AudioConcatenator.concatenate(
            chunks: [ChunkAudio(url: b, startTime: t0.addingTimeInterval(3)), ChunkAudio(url: a, startTime: t0)],
            outputDirectory: dir, outputName: "c", deleteSources: true)
        #expect(abs(r.gapsInsertedSeconds - 2) < 0.1)
        #expect(abs(try await AVURLAsset(url: r.outputPath).load(.duration).seconds - 4) < 0.3)
    }

    /// R4 DATA-LOSS EDGE: on a finalize re-run the merged file can be the only copy left. A missing
    /// source must fail the call WITHOUT deleting the existing output first.
    @Test func anExistingOutputSurvivesAMissingSource() async throws {
        let dir = try tempDir("survive"); defer { try? FileManager.default.removeItem(at: dir) }
        let merged = dir.appendingPathComponent("c.m4a")
        try await Self.createTestM4a(at: merged, durationSeconds: 2)
        let a = dir.appendingPathComponent("c-0.m4a"), gone = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a)
        await #expect(throws: (any Error).self) {
            _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: gone, startTime: nil)],
                                                        outputDirectory: dir, outputName: "c", deleteSources: true)
        }
        #expect(FileManager.default.fileExists(atPath: merged.path))
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    /// A merge that fails verification keeps every source.
    @Test func aVerificationFailureKeepsEverySource() async throws {
        let dir = try tempDir("verify"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a); try await Self.createTestM4a(at: b)
        AudioConcatenator.verificationToleranceForTesting = -1   // nothing can match
        defer { AudioConcatenator.verificationToleranceForTesting = nil }
        await #expect(throws: AudioConcatenatorError.self) {
            _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)],
                                                        outputDirectory: dir, outputName: "c", deleteSources: true)
        }
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.m4a").path))
    }

    /// Finalize wiring: `preserve_source_wav` keeps the chunk files, and `merged_audio` is stamped.
    @MainActor
    @Test func finalizeHonoursPreserveAndStampsMergedAudio() async throws {
        let dir = try tempDir("finalize"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("m-0.m4a"), b = dir.appendingPathComponent("m-1.m4a")
        try await Self.createTestM4a(at: a); try await Self.createTestM4a(at: b)
        let t0 = Date(timeIntervalSince1970: 0)
        let chunks = [a, b].enumerated().map { i, url in
            ProcessedChunk(index: i, startTime: t0.addingTimeInterval(Double(i) * 3), audioPath: url.lastPathComponent,
                           segments: [.init(start: 0, end: 1, text: "hi", speaker: "Speaker 1", source: "remote")],
                           speakerDatabase: ["Speaker 1": [1, 0, 0]])
        }
        var config = Config.default
        config.preserveSourceWAV = true
        config.mergeChunkedAudio = true
        let state = SessionState(sessionId: "m", meetingStart: t0, engine: "fluid_audio", chunkDurationMinutes: 10, chunks: chunks)
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: config)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any]
        let merged = try #require((json?["metadata"] as? [String: Any])?["merged_audio"] as? [String: Any])
        #expect(merged["passthrough"] as? Bool == false)
        #expect(abs((merged["gaps_inserted_seconds"] as? Double ?? 0) - 2) < 0.1)
    }

    /// Round 4 item 6: a finalize RE-RUN after the first run merged and deleted the chunk files —
    /// the surviving `<session>.m4a` is the recording's audio: listed, stamped and protected.
    @MainActor
    @Test func aFinalizeReRunUsesTheSurvivingMergedAudio() async throws {
        let dir = try tempDir("rerun"); defer { try? FileManager.default.removeItem(at: dir) }
        let merged = dir.appendingPathComponent("m.m4a")
        try await Self.createTestM4a(at: merged, durationSeconds: 2)
        let t0 = Date(timeIntervalSince1970: 0)
        let chunks = (0..<2).map { i in
            ProcessedChunk(index: i, startTime: t0.addingTimeInterval(Double(i)), audioPath: "m-\(i).m4a",   // both deleted
                           segments: [.init(start: 0, end: 1, text: "hi", speaker: "Speaker 1", source: "remote")],
                           speakerDatabase: ["Speaker 1": [1, 0, 0]])
        }
        var config = Config.default
        config.audioArchiveLimitHours = 0   // any unprotected archive would be deleted by the quota
        let state = SessionState(sessionId: "m", meetingStart: t0, engine: "fluid_audio", chunkDurationMinutes: 10, chunks: chunks)
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: config)
        let meta = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])?["metadata"] as? [String: Any])
        #expect(meta["audio_paths"] as? [String] == [merged.path])
        #expect((meta["merged_audio"] as? [String: Any])?["reused_existing"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: merged.path), "the merged file is protected from the quota")
    }

    // MARK: - Round 5: implausible timing

    private func refuses(_ chunks: [ChunkAudio]) async -> Bool {
        do {
            _ = try await AudioConcatenator.concatenate(chunks: chunks, outputDirectory: chunks[0].url.deletingLastPathComponent(),
                                                        outputName: "c", deleteSources: true)
            return false
        } catch AudioConcatenatorError.implausibleTiming {
            return true
        } catch {
            Issue.record("unexpected error: \(error)")
            return false
        }
    }

    /// A start time decades (or just 13 hours) away from the rest was merged by inserting that much
    /// silence — an export that hit its 300 s timeout. Refused instead, and the chunk files are kept.
    @Test(.timeLimit(.minutes(1)))
    func implausibleGapsAreRefusedAndTheChunksKept() async throws {
        let dir = try tempDir("implausible"); defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<3).map { dir.appendingPathComponent("c-\($0).m4a") }
        for url in urls { try await Self.createTestM4a(at: url, durationSeconds: 1) }
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(await refuses([ChunkAudio(url: urls[0], startTime: t0), ChunkAudio(url: urls[1], startTime: t0.addingTimeInterval(13 * 3600))]),
                "one gap over 12 h")
        #expect(await refuses((0..<3).map { ChunkAudio(url: urls[$0], startTime: t0.addingTimeInterval(Double($0) * 7 * 3600)) }),
                "gaps adding up to over 12 h")
        #expect(await refuses([ChunkAudio(url: urls[0], startTime: t0),
                               ChunkAudio(url: urls[1], startTime: Date(timeIntervalSinceReferenceDate: .infinity))]),
                "a non-finite start")
        #expect(await refuses([ChunkAudio(url: urls[0], startTime: t0.addingTimeInterval(10)), ChunkAudio(url: urls[1], startTime: nil),
                               ChunkAudio(url: urls[2], startTime: t0)]),
                "a start before the first chunk's")
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "every chunk file is kept")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.m4a").path), "nothing was written")
        let r = try await AudioConcatenator.concatenate(
            chunks: [ChunkAudio(url: urls[0], startTime: t0), ChunkAudio(url: urls[1], startTime: t0.addingTimeInterval(3))],
            outputDirectory: dir, outputName: "c", deleteSources: false)
        #expect(abs(r.gapsInsertedSeconds - 2) < 0.1, "a plausible gap still merges")
    }

    /// Round 8 item 4: a gap just over the bound must never read "12.0 h > 12 h" — minutes then.
    @Test func aGapJustOverTheBoundIsNeverWordedAsTheBound() {
        let t0 = Date(timeIntervalSince1970: 0)
        let a = URL(fileURLWithPath: "/tmp/a.m4a"), b = URL(fileURLWithPath: "/tmp/b.m4a")
        let why = AudioConcatenator.implausibleTiming([ChunkAudio(url: a, startTime: t0), ChunkAudio(url: b, startTime: t0.addingTimeInterval(12 * 3600 + 61))],
                                                       durations: [1, 1])
        #expect(why == "gap 721 min > 720 min bound")
        let clear = AudioConcatenator.implausibleTiming([ChunkAudio(url: a, startTime: t0), ChunkAudio(url: b, startTime: t0.addingTimeInterval(13.2 * 3600 + 1))],
                                                         durations: [1, 1])
        #expect(clear == "gap 13.2 h > 12 h bound")
    }
}

