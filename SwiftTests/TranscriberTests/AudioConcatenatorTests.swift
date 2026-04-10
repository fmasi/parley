import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

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
            sources: [source],
            outputDirectory: dir,
            outputName: "output"
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
            sources: sources,
            outputDirectory: dir,
            outputName: "merged"
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
            sources: [source1, source2],
            outputDirectory: dir,
            outputName: "merged"
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
            sources: [source1, source2],
            outputDirectory: dir,
            outputName: "merged"
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
                sources: [],
                outputDirectory: dir,
                outputName: "output"
            )
            Issue.record("Expected concatenate to throw on empty sources")
        } catch AudioConcatenatorError.noSources {
            // Expected
        }
    }
}
