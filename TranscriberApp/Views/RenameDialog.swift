import SwiftUI
import AVFoundation
import TranscriberCore
import os

struct SpeakerSample {
    let text: String
    let audioFile: URL?
    let start: TimeInterval
    let end: TimeInterval
}

struct SpeakerEntry: Identifiable {
    let id: String  // "Local Speaker 1", "Remote Speaker 1", etc.
    var displayName: String
    let samples: [SpeakerSample]  // up to 3, sorted by duration (longest first)
}

struct RenameDialog: View {
    @State private var speakers: [SpeakerEntry]
    @State private var audioPlayer: AVAudioPlayer?
    @State private var sampleIndices: [String: Int] = [:]  // speaker id → current sample index

    let jsonPath: URL
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    init(
        jsonPath: URL,
        speakers: [SpeakerEntry],
        onSave: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.jsonPath = jsonPath
        self._speakers = State(initialValue: speakers)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speakers")
                .font(.headline)

            ForEach($speakers) { $speaker in
                let speakerId = speaker.id
                let sampleIdx = sampleIndices[speakerId, default: 0]
                let sample = speaker.samples.indices.contains(sampleIdx) ? speaker.samples[sampleIdx] : nil

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(speaker.id)
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(.secondary)

                        TextField("Name", text: $speaker.displayName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { stopPlayback() }
                            .onChange(of: speaker.displayName) { _, _ in stopPlayback() }

                        if let sample, sample.audioFile != nil {
                            Button {
                                playSample(
                                    sample.audioFile!,
                                    from: sample.start,
                                    to: sample.end,
                                    isLocal: speaker.id.hasPrefix("Local")
                                )
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                        }

                        if speaker.samples.count > 1 {
                            Button {
                                let current = sampleIndices[speaker.id] ?? 0
                                sampleIndices[speaker.id] = (current + 1) % speaker.samples.count
                            } label: {
                                Image(systemName: "forward.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Next sample (\(sampleIdx + 1)/\(speaker.samples.count))")
                        }
                    }

                    if let sample {
                        HStack(spacing: 4) {
                            if speaker.samples.count > 1 {
                                Text("\(sampleIdx + 1)/\(speaker.samples.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                                    .monospacedDigit()
                            }
                            Text(sample.text)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        .padding(.leading, 124)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var mapping: [String: String] = [:]
                    for speaker in speakers {
                        if !speaker.displayName.isEmpty {
                            mapping[speaker.id] = speaker.displayName
                        }
                    }
                    onSave(mapping)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
    }

    @State private var stopTimer: Timer?

    private func stopPlayback() {
        audioPlayer?.stop()
        stopTimer?.invalidate()
    }

    /// Play a speaker sample from the stereo archive as mono on both speakers.
    /// Extracts the relevant channel (L=local mic, R=remote system) into a mono buffer
    /// to eliminate echo from mic bleed of the remote speaker in the L channel.
    private func playSample(_ url: URL, from start: TimeInterval, to end: TimeInterval, isLocal: Bool) {
        stopPlayback()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            Logger.audio.error("playSample: can't open \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        let sampleRate = file.processingFormat.sampleRate
        let channelCount = file.processingFormat.channelCount

        guard channelCount >= 2 else {
            playDirect(url, from: start, to: end)
            return
        }

        let startFrame = AVAudioFramePosition(start * sampleRate)
        let endFrame = AVAudioFramePosition(end * sampleRate)
        let safeStart = min(startFrame, file.length)
        let safeEnd = min(endFrame, file.length)
        let frameCount = AVAudioFrameCount(safeEnd - safeStart)
        guard frameCount > 0 else {
            Logger.audio.error("playSample: zero frames (start=\(start), end=\(end), fileLength=\(file.length))")
            return
        }

        // Read the stereo segment using the file's processing format (AVAudioFile handles AAC decode)
        guard let stereoBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            Logger.audio.error("playSample: can't allocate stereo buffer")
            return
        }
        file.framePosition = safeStart
        do {
            try file.read(into: stereoBuf, frameCount: frameCount)
        } catch {
            Logger.audio.error("playSample: read failed: \(error.localizedDescription)")
            return
        }

        // Extract single channel into mono buffer
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            Logger.audio.error("playSample: can't allocate mono buffer")
            return
        }
        monoBuf.frameLength = stereoBuf.frameLength

        let channelIndex: Int = isLocal ? 0 : 1
        guard let src = stereoBuf.floatChannelData?[channelIndex],
              let dst = monoBuf.floatChannelData?[0] else {
            Logger.audio.error("playSample: can't get channel data (channels=\(channelCount), index=\(channelIndex))")
            return
        }
        memcpy(dst, src, Int(stereoBuf.frameLength) * MemoryLayout<Float>.size)

        // Write mono to temp WAV for AVAudioPlayer
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-preview.wav")
        try? FileManager.default.removeItem(at: tmpURL)
        do {
            let tmpFile = try AVAudioFile(forWriting: tmpURL, settings: monoFormat.settings)
            try tmpFile.write(from: monoBuf)
        } catch {
            Logger.audio.error("playSample: temp WAV write failed: \(error.localizedDescription)")
            return
        }

        guard let player = try? AVAudioPlayer(contentsOf: tmpURL) else {
            Logger.audio.error("playSample: AVAudioPlayer init failed for temp WAV")
            return
        }
        player.play()
        audioPlayer = player
        let duration = Double(frameCount) / sampleRate
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            self.audioPlayer?.stop()
        }
    }

    /// Fallback for mono files — play directly with time seek.
    private func playDirect(_ url: URL, from start: TimeInterval, to end: TimeInterval) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        let safeStart = min(start, player.duration)
        let safeEnd = min(end, player.duration)
        let duration = safeEnd - safeStart
        guard duration > 0 else { return }
        player.currentTime = safeStart
        player.play()
        audioPlayer = player
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            self.audioPlayer?.stop()
        }
    }
}
