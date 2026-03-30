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

        // Collect unique speakers and sample quotes in order of appearance
        var seen = Set<String>()
        var sampleTexts: [String: [String]] = [:]
        var orderedIds: [String] = []

        for seg in segments {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String else { continue }
            if !seen.contains(speaker) {
                seen.insert(speaker)
                orderedIds.append(speaker)
                sampleTexts[speaker] = []
            }
            // Keep first 2 quotes per speaker (enough to identify them)
            if let count = sampleTexts[speaker]?.count, count < 2 {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sampleTexts[speaker]?.append(trimmed)
                }
            }
        }

        let dir = jsonPath.deletingLastPathComponent()
        return orderedIds.map { speaker in
            let samplePath = dir.appendingPathComponent(
                "\(speaker.lowercased().replacingOccurrences(of: " ", with: "_")).wav"
            )
            return SpeakerEntry(
                id: speaker,
                displayName: speaker,
                sampleText: sampleTexts[speaker]?.joined(separator: " ") ?? "",
                samplePath: FileManager.default.fileExists(atPath: samplePath.path) ? samplePath : nil
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
