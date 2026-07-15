import AVFoundation
import Foundation
import os

/// Renders one speaker sample to a short mono WAV, ready to play.
///
/// Shared by the GUI and CLI rename paths. The CLI previously shelled out to `afplay`, which has
/// no seek flag — so it silently ignored the sample's start offset and played the first ten seconds
/// of the recording instead, mixing both channels. Every CLI rename therefore auditioned the wrong
/// moment, and on a stereo archive the wrong people.
///
/// Extracting a single channel also matters: the archive is L = mic, R = system, so playing the
/// stereo mix means hearing the remote participants underneath the local speaker (and vice versa).
public enum SpeakerSamplePreview {

    public enum PreviewError: Error {
        case cannotOpen(String)
        case emptyRange
        case renderFailed(String)
    }

    /// Extract `start..<end` of one channel into a temp mono WAV and return its URL.
    ///
    /// - Parameter isLocal: true selects L (mic), false selects R (system). Ignored for mono files,
    ///   which carry a single source already.
    public static func makeMonoPreview(
        of url: URL,
        from start: TimeInterval,
        to end: TimeInterval,
        isLocal: Bool
    ) throws -> URL {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PreviewError.cannotOpen(error.localizedDescription)
        }

        let sampleRate = file.processingFormat.sampleRate
        let channelCount = Int(file.processingFormat.channelCount)
        guard sampleRate > 0 else { throw PreviewError.cannotOpen("zero sample rate") }

        let safeStart = min(AVAudioFramePosition(start * sampleRate), file.length)
        let safeEnd = min(AVAudioFramePosition(end * sampleRate), file.length)
        let frameCount = AVAudioFrameCount(max(0, safeEnd - safeStart))
        guard frameCount > 0 else { throw PreviewError.emptyRange }

        guard let sourceBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw PreviewError.renderFailed("cannot allocate read buffer")
        }
        file.framePosition = safeStart
        do {
            try file.read(into: sourceBuf, frameCount: frameCount)
        } catch {
            throw PreviewError.renderFailed(error.localizedDescription)
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            throw PreviewError.renderFailed("cannot allocate mono buffer")
        }
        monoBuf.frameLength = sourceBuf.frameLength

        let channelIndex = (channelCount >= 2 && !isLocal) ? 1 : 0
        guard let src = sourceBuf.floatChannelData?[channelIndex],
              let dst = monoBuf.floatChannelData?[0] else {
            throw PreviewError.renderFailed("cannot access channel data")
        }
        memcpy(dst, src, Int(sourceBuf.frameLength) * MemoryLayout<Float>.size)

        // Unique filename per preview: a fixed name rewritten in place races with a player still
        // reading the previous sample.
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-preview-\(UUID().uuidString).wav")
        do {
            let outFile = try AVAudioFile(forWriting: out, settings: monoFormat.settings)
            try outFile.write(from: monoBuf)
        } catch {
            throw PreviewError.renderFailed(error.localizedDescription)
        }
        return out
    }
}
