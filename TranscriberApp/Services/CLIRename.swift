import Foundation
import os
import TranscriberCore

enum CLIRename {

    struct SpeakerSample {
        let id: String
        let sampleText: String
        let audioFile: URL?
        let start: Double
        let end: Double
    }

    static func run(jsonPath: URL) throws {
        // Parse JSON
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else {
            throw RenameError.invalidJSON
        }

        let metadata = json["metadata"] as? [String: Any]
        let audioPaths = metadata?["audio_paths"] as? [String] ?? []
        let remoteAudio = audioPaths.first.map { URL(fileURLWithPath: $0) }
        let localAudio = audioPaths.count > 1 ? URL(fileURLWithPath: audioPaths[1]) : nil

        // Collect speakers — pick the longest segment per speaker for the best sample
        var candidatesBySpaker: [String: [(text: String, start: Double, end: Double, source: String)]] = [:]
        var orderedIds: [String] = []

        for seg in segments {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if candidatesBySpaker[speaker] == nil { orderedIds.append(speaker) }
            let source = seg["source"] as? String ?? "remote"
            candidatesBySpaker[speaker, default: []].append((trimmed, start, end, source))
        }

        let samples: [SpeakerSample] = orderedIds.compactMap { speaker in
            guard let best = candidatesBySpaker[speaker]?.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
            let audioFile = best.source == "local" ? localAudio : remoteAudio
            return SpeakerSample(id: speaker, sampleText: best.text, audioFile: audioFile, start: best.start, end: best.end)
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
                playAudioSample(file: audioFile, start: sample.start, duration: sample.end - sample.start)
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

    private static func playAudioSample(file: URL, start: Double, duration: Double) {
        guard duration > 0 else { return }

        // afplay has no seek option — only --time for duration and --rate for speed.
        // Play from start of file, capped at 10s. Full seek would require AVAudioPlayer.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [
            file.path,
            "--time", String(format: "%.1f", min(duration, 10.0)),
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.transcription.error("afplay failed: \(error, privacy: .public)")
        }
    }

    private static func applyRenames(_ mapping: [String: String], jsonPath: URL) {
        do {
            let data = try Data(contentsOf: jsonPath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var segments = json["segments"] as? [[String: Any]]
            else {
                Logger.files.error("Failed to parse JSON for rename: \(jsonPath.lastPathComponent, privacy: .public)")
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
