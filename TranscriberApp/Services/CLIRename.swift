import AVFoundation
import Foundation
import os
import TranscriberCore

/// Interactive CLI speaker rename. Sample collection and rename application live in
/// `TranscriptRenamer` (TranscriberCore, shared with the GUI dialog); this file owns only
/// the terminal interaction and audio playback.
enum CLIRename {

    static func run(jsonPath: URL) throws {
        // One sample per speaker — the CLI plays it inline rather than offering alternatives.
        let entries = try TranscriptRenamer.collectSpeakerSamples(
            from: jsonPath, maxSamplesPerSpeaker: 1
        )
        // A speaker with no usable segment at all cannot be auditioned or renamed here.
        let samples: [(id: String, sample: SpeakerSample)] = entries.compactMap { entry in
            entry.samples.first.map { (entry.id, $0) }
        }

        guard !samples.isEmpty else {
            print("No speakers found in transcript.")
            return
        }

        print("\nFound \(samples.count) speaker(s) in transcript.\n")

        // Interactive rename loop
        var mapping: [String: String] = [:]

        for (id, sample) in samples {
            print("--- \(id) ---")
            print("Sample: \"\(sample.text.prefix(100))\"")

            // Play audio sample if available
            if let audioFile = sample.audioFile,
               FileManager.default.fileExists(atPath: audioFile.path) {
                print("Playing audio sample...")
                playAudioSample(
                    file: audioFile, start: sample.start,
                    duration: sample.end - sample.start, isLocal: sample.isLocal
                )
            }

            print("Enter new name (or press Enter to keep '\(id)'): ", terminator: "")
            if let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
                mapping[id] = input
                print("  -> Renamed to: \(input)")
            } else {
                print("  -> Keeping: \(id)")
            }
            print()
        }

        // Apply renames if any were made. Report honestly — a "success" line after a failed write
        // is the silent-wrong-answer this whole product exists to avoid (the GUI path is atomic +
        // surfaced for the same reason).
        if !mapping.isEmpty {
            if TranscriptRenamer.applyRenames(mapping, jsonPath: jsonPath) {
                print("Speaker names updated in: \(jsonPath.lastPathComponent)")
            } else {
                print("Error: could not write speaker names to \(jsonPath.lastPathComponent). Nothing was saved.")
            }
        }

        // Generate format file
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }
        print("Done.")
    }

    /// Play one speaker sample: the RIGHT moment, from the RIGHT channel.
    ///
    /// This used to shell out to `afplay`, which has no seek flag — so `start` was accepted and
    /// then ignored, and every sample played the first ten seconds of the recording, mixing both
    /// channels of the stereo archive. The user was auditioning the wrong moment, and often the
    /// wrong people, while the printed sample text showed something else entirely.
    private static func playAudioSample(file: URL, start: Double, duration: Double, isLocal: Bool) {
        guard duration > 0 else { return }

        let preview: URL
        do {
            preview = try SpeakerSamplePreview.makeMonoPreview(
                of: file, from: start, to: start + duration, isLocal: isLocal
            )
        } catch {
            Logger.transcription.error("Sample preview failed: \(error, privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: preview) }

        guard let player = try? AVAudioPlayer(contentsOf: preview) else {
            Logger.transcription.error("Sample preview: AVAudioPlayer init failed")
            return
        }
        player.play()
        // Run the run loop rather than Thread.sleep: AVAudioPlayer relies on it being serviced for
        // its internal bookkeeping, and a bare sleep would block silently if playback never started.
        // Bounded by the clip length, so a player that fails to start cannot hang the CLI.
        let deadline = Date().addingTimeInterval(min(player.duration, duration) + 0.5)
        while player.isPlaying, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        player.stop()
    }
}
