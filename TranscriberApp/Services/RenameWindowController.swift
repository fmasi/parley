import AppKit
import SwiftUI
import os
import TranscriberCore

/// Opens the RenameDialog as a standalone NSPanel.
/// MenuBarExtra with `.menu` style cannot present sheets, so we use a panel instead.
@MainActor
final class RenameWindowController: NSObject, NSWindowDelegate {
    static let shared = RenameWindowController()
    private var panel: NSPanel?
    private var onDismissCallback: (() -> Void)?

    func show(jsonPath: URL, onDismiss: (() -> Void)? = nil) {
        // Close any existing panel
        panel?.close()

        let speakers = Self.parseSpeakers(from: jsonPath)
        guard !speakers.isEmpty else {
            onDismiss?()
            return
        }

        self.onDismissCallback = onDismiss

        let closePanel = { [weak self] in
            Logger.state.debug("Panel closed: RenameSpeakers")
            self?.panel?.close()
            self?.panel = nil
            self?.onDismissCallback?()
            self?.onDismissCallback = nil
        }

        let dialog = RenameDialog(
            jsonPath: jsonPath,
            speakers: speakers,
            onSave: { mapping in
                Self.applySpeakerRenames(mapping, jsonPath: jsonPath)
                Task.detached { Self.generateFormatFile(jsonPath: jsonPath) }
                closePanel()
            },
            onCancel: {
                Task.detached { Self.generateFormatFile(jsonPath: jsonPath) }
                closePanel()
            }
        )

        let hostingView = NSHostingView(rootView: dialog)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Rename Speakers"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        newPanel.contentView = hostingView
        newPanel.delegate = self
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
        Logger.state.debug("Panel shown: RenameSpeakers")
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            Logger.state.debug("Panel closed via window button: RenameSpeakers")
            panel = nil
            onDismissCallback?()
            onDismissCallback = nil
        }
    }

    // MARK: - JSON Parsing

    static func parseSpeakers(from jsonPath: URL) -> [SpeakerEntry] {
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else { return [] }

        // Build source→audio file mapping from metadata
        let metadata = json["metadata"] as? [String: Any]
        let audioPaths = metadata?["audio_paths"] as? [String] ?? []
        // First path = system (remote), second = mic (local)
        let remoteAudio = audioPaths.first.map { URL(fileURLWithPath: $0) }
        let localAudio = audioPaths.count > 1 ? URL(fileURLWithPath: audioPaths[1]) : nil

        struct CandidateSegment {
            let start: Double
            let end: Double
            let source: String
            let text: String
            var duration: Double { end - start }
        }

        // Collect all segments per speaker
        var candidates: [String: [CandidateSegment]] = [:]
        var orderedIds: [String] = []

        for seg in segments {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if candidates[speaker] == nil {
                orderedIds.append(speaker)
                candidates[speaker] = []
            }
            let source = seg["source"] as? String ?? "remote"
            candidates[speaker]?.append(CandidateSegment(start: start, end: end, source: source, text: trimmed))
        }

        let maxSamples = 3
        let minSegments = 5

        // Filter out noise speakers (< minSegments) — they're usually diarization artifacts.
        // Fall back to unfiltered list if filtering would remove all speakers (e.g. short transcripts).
        let filteredIds = orderedIds.filter { (candidates[$0]?.count ?? 0) >= minSegments }
        let significantIds = filteredIds.isEmpty ? orderedIds : filteredIds

        return significantIds.map { speaker in
            let allCandidates = candidates[speaker] ?? []
            // Pick the longest segments as samples (best chance of audible, identifiable speech)
            let best = Array(allCandidates.sorted { $0.duration > $1.duration }.prefix(maxSamples))

            let samples = best.map { candidate in
                let audioFile: URL? = {
                    let file = candidate.source == "local" ? localAudio : remoteAudio
                    guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
                    return file
                }()
                return SpeakerSample(
                    text: candidate.text,
                    audioFile: audioFile,
                    start: candidate.start,
                    end: candidate.end
                )
            }

            return SpeakerEntry(
                id: speaker,
                displayName: speaker,
                samples: samples
            )
        }
    }

    // MARK: - Apply Renames

    static func applySpeakerRenames(_ mapping: [String: String], jsonPath: URL) {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var segments = json["segments"] as? [[String: Any]]
        else { return }

        for i in segments.indices {
            if let speaker = segments[i]["speaker"] as? String,
               let newName = mapping[speaker] {
                segments[i]["speaker"] = newName
            }
        }
        json["segments"] = segments

        if let updatedData = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? updatedData.write(to: jsonPath)
        }
    }

    // MARK: - Generate Format File

    nonisolated static func generateFormatFile(jsonPath: URL) {
        let format = Self.readOutputFormat(from: jsonPath) ?? "json"
        guard format == "srt" || format == "txt" else { return }

        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
            let outputPath = jsonPath.deletingPathExtension().appendingPathExtension(format)
            if FileManager.default.fileExists(atPath: outputPath.path) {
                Logger.files.info("Format file written: \(outputPath.lastPathComponent, privacy: .public)")
            }
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }
    }

    private nonisolated static func readOutputFormat(from jsonPath: URL) -> String? {
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any]
        else { return nil }
        return metadata["output_format"] as? String
    }
}
