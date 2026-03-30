import AppKit
import SwiftUI

/// Opens the RenameDialog as a standalone NSPanel.
/// MenuBarExtra with `.menu` style cannot present sheets, so we use a panel instead.
@MainActor
final class RenameWindowController {
    static let shared = RenameWindowController()
    private var panel: NSPanel?

    func show(jsonPath: URL) {
        // Close any existing panel
        panel?.close()

        let speakers = Self.parseSpeakers(from: jsonPath)
        guard !speakers.isEmpty else { return }

        let closePanel = { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        }

        let dialog = RenameDialog(
            jsonPath: jsonPath,
            speakers: speakers,
            onSave: { mapping in
                Self.applySpeakerRenames(mapping, jsonPath: jsonPath)
                closePanel()
            },
            onCancel: closePanel
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
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
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

        // Collect unique speakers, sample quotes, and first segment timestamps
        var seen = Set<String>()
        var sampleTexts: [String: [String]] = [:]
        var sampleTimes: [String: (start: Double, end: Double, source: String)] = [:]
        var orderedIds: [String] = []

        for seg in segments {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String else { continue }
            if !seen.contains(speaker) {
                seen.insert(speaker)
                orderedIds.append(speaker)
                sampleTexts[speaker] = []
                // Use the first segment as the audio sample
                if let start = seg["start"] as? Double,
                   let end = seg["end"] as? Double {
                    let source = seg["source"] as? String ?? "remote"
                    sampleTimes[speaker] = (start, end, source)
                }
            }
            if let count = sampleTexts[speaker]?.count, count < 2 {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sampleTexts[speaker]?.append(trimmed)
                }
            }
        }

        return orderedIds.map { speaker in
            let times = sampleTimes[speaker]
            let audioFile: URL? = {
                guard let times else { return nil }
                let file = times.source == "local" ? localAudio : remoteAudio
                guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
                return file
            }()
            return SpeakerEntry(
                id: speaker,
                displayName: speaker,
                sampleText: sampleTexts[speaker]?.joined(separator: " ") ?? "",
                sampleAudioFile: audioFile,
                sampleStart: times?.start ?? 0,
                sampleEnd: times?.end ?? 0
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
}
