import Foundation
import AVFoundation
import CoreMedia
import os

public enum AudioSourceResolverError: LocalizedError {
    case noAudioFiles(baseName: String, directory: URL)

    public var errorDescription: String? {
        switch self {
        case .noAudioFiles(let baseName, let directory):
            return "No audio files found for '\(baseName)' in \(directory.path)"
        }
    }
}

/// Splits a stereo AAC archive into separate mono WAV streams for the pipeline.
///
/// Channel convention for stereo AAC:
/// - Left channel = local microphone (the user)
/// - Right channel = remote system audio (other participants)
public enum AudioSourceResolver {

    /// Split a stereo AAC file into two mono WAV files.
    /// Returns (local mic, remote system) paths.
    /// L channel → local mic, R channel → remote system.
    public static func splitChannels(
        stereoAac: URL,
        outputDirectory: URL
    ) async throws -> (local: URL, remote: URL) {
        let baseName = stereoAac.deletingPathExtension().lastPathComponent
        let localPath = outputDirectory.appendingPathComponent("\(baseName)_split_mic.wav")
        let remotePath = outputDirectory.appendingPathComponent("\(baseName)_split_system.wav")

        let asset = AVURLAsset(url: stereoAac)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioSourceResolverError.noAudioFiles(baseName: baseName, directory: outputDirectory)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 2,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(readerOutput)
        reader.startReading()

        // Detect sample rate from track
        let descriptions = try await track.load(.formatDescriptions)
        let sampleRate: Double
        if let desc = descriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            sampleRate = asbd?.pointee.mSampleRate ?? 48000
        } else {
            sampleRate = 48000
        }

        let localWriter = try WavFileWriter(path: localPath.path)
        let remoteWriter = try WavFileWriter(path: remotePath.path)
        localWriter.setSampleRate(UInt32(sampleRate))
        localWriter.setChannelCount(1)
        remoteWriter.setSampleRate(UInt32(sampleRate))
        remoteWriter.setChannelCount(1)

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { rawPtr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawPtr.baseAddress!)
            }

            // Deinterleave stereo Int16: [L0, R0, L1, R1, ...] → separate L and R
            let sampleCount = length / MemoryLayout<Int16>.size
            let frameCount = sampleCount / 2
            data.withUnsafeBytes { rawPtr in
                let int16Ptr = rawPtr.bindMemory(to: Int16.self)
                var leftSamples = [Int16](repeating: 0, count: frameCount)
                var rightSamples = [Int16](repeating: 0, count: frameCount)
                for i in 0..<frameCount {
                    leftSamples[i] = int16Ptr[i * 2]       // L = local mic
                    rightSamples[i] = int16Ptr[i * 2 + 1]  // R = remote system
                }
                leftSamples.withUnsafeBufferPointer { localWriter.appendInt16($0) }
                rightSamples.withUnsafeBufferPointer { remoteWriter.appendInt16($0) }
            }
        }

        localWriter.finalize()
        remoteWriter.finalize()

        Logger.files.info("Split stereo AAC into L=\(localPath.lastPathComponent, privacy: .private), R=\(remotePath.lastPathComponent, privacy: .private)")
        return (local: localPath, remote: remotePath)
    }
}
