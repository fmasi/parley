import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// `.serialized`: these tests drive AVAssetReader, which are clients of shared media XPC
/// daemons. A timed-out CI run on 2026-09-04 showed 27 such tests starting within six
/// seconds and none ever finishing — a wedged daemon blocks every client forever. Running
/// this suite's cases one at a time reduces how many are ever in flight together.
///
/// NOTE: CI currently also runs the whole suite with `--no-parallel`, because serialising
/// these suites alone cut the frozen set from 27 tests to 15 and did not stop the stall —
/// it is cross-suite. These traits are kept because they document which suites are
/// implicated, and they keep the constraint if parallelism is ever restored.
@Suite(.serialized)
struct AudioSourceResolverSplitTests {

    /// Helper: create a stereo WAV file with distinct L/R content.
    private static func createTestStereoWav(at url: URL, durationSeconds: Double = 1.0, sampleRate: Double = 48000) throws {
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw TestHelperError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let leftPtr = buffer.floatChannelData![0]
        let rightPtr = buffer.floatChannelData![1]
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            leftPtr[i] = Float(sin(2.0 * .pi * 440.0 * t))
            rightPtr[i] = Float(sin(2.0 * .pi * 880.0 * t))
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Helper: create stereo AAC by converting a stereo WAV.
    private static func createTestStereoAac(at aacURL: URL, sampleRate: Double = 48000) async throws {
        let wavURL = aacURL.deletingPathExtension().appendingPathExtension("tmp.wav")
        try createTestStereoWav(at: wavURL, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let asset = AVAsset(url: wavURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw TestHelperError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
        ])
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: aacURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64000,
        ])
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        while let sample = readerOutput.copyNextSampleBuffer() {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            writerInput.append(sample)
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
    }

    enum TestHelperError: Error {
        case cannotCreateBuffer
        case noAudioTrack
    }

    @Test func splitChannelsCreatesTwoFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aacPath = dir.appendingPathComponent("test.m4a")
        try await Self.createTestStereoAac(at: aacPath)

        let (localPath, remotePath) = try await AudioSourceResolver.splitChannels(stereoAac: aacPath, outputDirectory: dir)

        #expect(FileManager.default.fileExists(atPath: localPath.path))
        #expect(FileManager.default.fileExists(atPath: remotePath.path))
        #expect(localPath.pathExtension == "wav")
        #expect(remotePath.pathExtension == "wav")

        // Verify mono
        let localFile = try AVAudioFile(forReading: localPath)
        let remoteFile = try AVAudioFile(forReading: remotePath)
        #expect(localFile.processingFormat.channelCount == 1)
        #expect(remoteFile.processingFormat.channelCount == 1)
    }
}
