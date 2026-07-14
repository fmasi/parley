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

        // parseSpeakers opens an AVAudioFile per chunk to measure durations — O(N) file opens, which
        // visibly stalls the menu bar before the window appears (worst on a network-mounted or cold
        // recordings folder). Do it off the main actor, then present.
        Task { @MainActor in
            let speakers = await Task.detached(priority: .userInitiated) {
                Self.parseSpeakers(from: jsonPath)
            }.value
            guard !speakers.isEmpty else {
                Logger.files.error("Rename: no speakers found in \(jsonPath.lastPathComponent, privacy: .private)")
                let alert = NSAlert()
                alert.messageText = "No speakers to rename"
                alert.informativeText =
                    "Couldn't read any speakers from this file. Make sure it's a Parley transcript "
                    + "(a .json produced alongside a recording), not session.json or another file."
                alert.alertStyle = .informational
                alert.runModal()
                onDismiss?()
                return
            }
            self.present(jsonPath: jsonPath, speakers: speakers, onDismiss: onDismiss)
        }
    }

    /// Build and show the panel. Main actor; assumes `speakers` is non-empty.
    private func present(jsonPath: URL, speakers: [SpeakerEntry], onDismiss: (() -> Void)?) {

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
                guard Self.applySpeakerRenames(mapping, jsonPath: jsonPath) else {
                    // Keep the panel open: the names are still in the fields, so the user can
                    // retry rather than discovering later that nothing was saved.
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save speaker names"
                    alert.informativeText =
                        "The transcript could not be written. Check that the recordings folder is "
                        + "available and has free space, then try again."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
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

    nonisolated static func parseSpeakers(from jsonPath: URL) -> [SpeakerEntry] {
        guard let data = try? Data(contentsOf: jsonPath) else {
            Logger.files.error("Rename: cannot read \(jsonPath.lastPathComponent, privacy: .private)")
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else {
            Logger.files.error("Rename: \(jsonPath.lastPathComponent, privacy: .private) is not a readable transcript")
            return []
        }

        // Resolve the recording's audio layout. `audio_paths` is [chunk0, chunk1, ...] for a
        // chunked recording — NOT [system, mic] — so samples must be mapped onto the chunk that
        // actually contains them (#132).
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
        var segmentCounts: [String: Int] = [:]
        var orderedIds: [String] = []

        for seg in segments {
            guard let speaker = seg["speaker"] as? String,
                  let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if segmentCounts[speaker] == nil { orderedIds.append(speaker) }
            segmentCounts[speaker, default: 0] += 1
            let source = seg["source"] as? String ?? "remote"
            allCandidates.append(SpeakerSampleSelector.Candidate(
                speaker: speaker, start: start, end: end, source: source, text: trimmed
            ))
        }

        let maxSamples = 3
        let minSegments = 5

        // Filter out noise speakers (< minSegments) — they're usually diarization artifacts.
        // Fall back to unfiltered list if filtering would remove all speakers (e.g. short transcripts).
        let filteredIds = orderedIds.filter { (segmentCounts[$0] ?? 0) >= minSegments }
        let significantIds = filteredIds.isEmpty ? orderedIds : filteredIds

        return significantIds.map { speaker in
            // Isolated speech first, then longest — a sample exists to let a human recognise ONE
            // voice, and the longest segment is very often the one they were talked over in.
            let ranked = SpeakerSampleSelector.rank(speaker: speaker, allSegments: allCandidates)

            var samples: [SpeakerSample] = []
            for candidate in ranked where samples.count < maxSamples {
                guard let hit = SpeakerSampleLocator.locate(
                    source: candidate.source,
                    start: candidate.start,
                    end: candidate.end,
                    layout: layout,
                    chunkDurations: chunkDurations
                ) else { continue }
                samples.append(SpeakerSample(
                    text: candidate.text,
                    audioFile: hit.url,
                    start: hit.start,
                    end: hit.end,
                    isLocal: hit.isLocal
                ))
            }

            // No playable audio at all (e.g. archives deleted by the storage quota): still offer
            // the speaker for renaming, with the sample text, but no dead play button.
            if samples.isEmpty {
                samples = ranked.prefix(maxSamples).map {
                    SpeakerSample(text: $0.text, audioFile: nil, start: 0, end: 0, isLocal: $0.source == "local")
                }
            }

            return SpeakerEntry(
                id: speaker,
                displayName: speaker,
                samples: samples
            )
        }
    }

    // MARK: - Apply Renames

    /// Apply speaker renames to the transcript on disk.
    ///
    /// Returns false (and logs) on failure. The previous version wrote with `try?` and returned
    /// Void: on a read-only or full volume the user renamed every speaker, hit Save, the panel
    /// closed, and nothing was written — with no error anywhere. The write is also atomic now,
    /// because by this point the source WAVs are gone and this JSON is the only textual record of
    /// the meeting; a kill mid-write would truncate it.
    @discardableResult
    static func applySpeakerRenames(_ mapping: [String: String], jsonPath: URL) -> Bool {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var segments = json["segments"] as? [[String: Any]]
        else {
            Logger.files.error("Rename: cannot read transcript \(jsonPath.lastPathComponent, privacy: .private)")
            return false
        }

        for i in segments.indices {
            if let speaker = segments[i]["speaker"] as? String,
               let newName = mapping[speaker] {
                segments[i]["speaker"] = newName
            }
        }
        json["segments"] = segments

        // Record the applied names alongside the transcript, as the CLI path already does.
        var metadata = json["metadata"] as? [String: Any] ?? [:]
        var names = metadata["speaker_names"] as? [String: String] ?? [:]
        for (original, renamed) in mapping where original != renamed {
            names[original] = renamed
        }
        if !names.isEmpty {
            metadata["speaker_names"] = names
            json["metadata"] = metadata
        }

        do {
            let updatedData = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            )
            try updatedData.write(to: jsonPath, options: .atomic)
            return true
        } catch {
            Logger.files.error("Rename: failed to write \(jsonPath.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
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
                Logger.files.info("Format file written: \(outputPath.lastPathComponent, privacy: .private)")
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
