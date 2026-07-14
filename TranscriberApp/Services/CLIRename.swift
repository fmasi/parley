import AVFoundation
import Foundation
import os
import TranscriberCore

enum CLIRename {

    struct SpeakerSample {
        let id: String
        let sampleText: String
        let audioFile: URL?
        /// Offsets WITHIN `audioFile` (chunk-local), not absolute transcript time.
        let start: Double
        let end: Double
        /// Which channel of the stereo archive carries this speaker (L = mic, R = system).
        let isLocal: Bool
    }

    static func run(jsonPath: URL) throws {
        // Parse JSON
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else {
            throw RenameError.invalidJSON
        }

        // `audio_paths` is [chunk0, chunk1, ...] for a chunked recording — not [system, mic].
        // Resolve each sample onto the chunk that actually contains it (#132).
        let metadata = json["metadata"] as? [String: Any]
        let audioPaths = (metadata?["audio_paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        let layout = SpeakerSampleLocator.classify(audioPaths: audioPaths)
        let chunkDurations: [TimeInterval?] = {
            if case .chunkedArchives(let chunks) = layout {
                return SpeakerSampleLocator.durations(of: chunks)
            }
            return []
        }()

        // Collect every segment once — sample ranking needs the OTHER speakers too, to tell
        // clean speech from crosstalk.
        var allCandidates: [SpeakerSampleSelector.Candidate] = []
        var orderedIds: [String] = []
        var seen = Set<String>()

        for seg in segments {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(speaker).inserted { orderedIds.append(speaker) }
            let source = seg["source"] as? String ?? "remote"
            allCandidates.append(SpeakerSampleSelector.Candidate(
                speaker: speaker, start: start, end: end, source: source, text: trimmed
            ))
        }

        let samples: [SpeakerSample] = orderedIds.compactMap { speaker in
            // Isolated speech first, then longest — the longest segment is very often the one
            // this speaker was talked over in. Then fall back through the ranking until one
            // actually resolves to playable audio.
            let ranked = SpeakerSampleSelector.rank(speaker: speaker, allSegments: allCandidates)
            guard let best = ranked.first else { return nil }

            for candidate in ranked {
                if let hit = SpeakerSampleLocator.locate(
                    source: candidate.source,
                    start: candidate.start,
                    end: candidate.end,
                    layout: layout,
                    chunkDurations: chunkDurations
                ) {
                    return SpeakerSample(
                        id: speaker, sampleText: candidate.text,
                        audioFile: hit.url, start: hit.start, end: hit.end,
                        isLocal: hit.isLocal
                    )
                }
            }
            // No playable audio — still let the user rename, using the sample text alone.
            return SpeakerSample(
                id: speaker, sampleText: best.text, audioFile: nil, start: 0, end: 0,
                isLocal: best.source == "local"
            )
        }

        guard !samples.isEmpty else {
            print("No speakers found in transcript.")
            return
        }

        print("\nFound \(samples.count) speaker(s) in transcript.\n")

        // Interactive rename loop
        var mapping: [String: String] = [:]

        for sample in samples {
            print("--- \(sample.id) ---")
            print("Sample: \"\(sample.sampleText.prefix(100))\"")

            // Play audio sample if available
            if let audioFile = sample.audioFile,
               FileManager.default.fileExists(atPath: audioFile.path) {
                print("Playing audio sample...")
                playAudioSample(
                    file: audioFile, start: sample.start,
                    duration: sample.end - sample.start, isLocal: sample.isLocal
                )
            }

            print("Enter new name (or press Enter to keep '\(sample.id)'): ", terminator: "")
            if let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
                mapping[sample.id] = input
                print("  -> Renamed to: \(input)")
            } else {
                print("  -> Keeping: \(sample.id)")
            }
            print()
        }

        // Apply renames if any were made
        if !mapping.isEmpty {
            applyRenames(mapping, jsonPath: jsonPath)
            print("Speaker names updated in: \(jsonPath.lastPathComponent)")
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
        // CLI is synchronous by nature: block for the clip, then move on to the prompt.
        Thread.sleep(forTimeInterval: min(player.duration, duration) + 0.1)
        player.stop()
    }

    private static func applyRenames(_ mapping: [String: String], jsonPath: URL) {
        do {
            let data = try Data(contentsOf: jsonPath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var segments = json["segments"] as? [[String: Any]]
            else {
                Logger.files.error("Failed to parse JSON for rename: \(jsonPath.lastPathComponent, privacy: .private)")
                return
            }

            for i in segments.indices {
                if let speaker = segments[i]["speaker"] as? String,
                   let newName = mapping[speaker] {
                    segments[i]["speaker"] = newName
                }
            }
            json["segments"] = segments

            var metadata = json["metadata"] as? [String: Any] ?? [:]
            metadata["speaker_names"] = mapping
            json["metadata"] = metadata

            let updatedData = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            )
            try updatedData.write(to: jsonPath, options: .atomic)
        } catch {
            Logger.files.error("Failed to apply renames: \(error, privacy: .public)")
        }
    }

    enum RenameError: LocalizedError {
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "Invalid JSON transcript file"
            }
        }
    }
}
