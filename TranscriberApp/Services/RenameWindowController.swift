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

        // Collect unique speakers in order of appearance
        var seen = Set<String>()
        var speakers: [SpeakerEntry] = []
        for seg in segments {
            if let speaker = seg["speaker"] as? String, !seen.contains(speaker) {
                seen.insert(speaker)
                // Look for a sample audio clip in the same directory
                let samplePath = jsonPath.deletingLastPathComponent()
                    .appendingPathComponent("\(speaker.lowercased().replacingOccurrences(of: " ", with: "_")).wav")
                speakers.append(SpeakerEntry(
                    id: speaker,
                    displayName: speaker,
                    samplePath: FileManager.default.fileExists(atPath: samplePath.path) ? samplePath : nil
                ))
            }
        }
        return speakers
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
