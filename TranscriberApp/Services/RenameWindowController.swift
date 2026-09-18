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
    /// The in-flight parse+present task. A second `show()` cancels the first, so two rapid calls
    /// cannot both reach `present()` and leave an orphaned panel on screen.
    private var showTask: Task<Void, Never>?

    func show(jsonPath: URL, onDismiss: (() -> Void)? = nil) {
        // Supersede any in-flight show: cancel its task and close its panel, so two rapid calls
        // cannot both reach present() and orphan a window.
        showTask?.cancel()
        panel?.close()

        // parseSpeakers opens an AVAudioFile per chunk to measure durations — O(N) file opens, which
        // visibly stalls the menu bar before the window appears (worst on a network-mounted or cold
        // recordings folder). Do it off the main actor, then present.
        //
        // channelNames is read here too (once, off-main) rather than by the dialog re-reading the
        // transcript on every "Re-detect" press — the file open+parse that used to happen
        // synchronously on the main actor for the "this will clear your names" warning (#207).
        showTask = Task { @MainActor in
            let (speakers, channelNames) = await Task.detached(priority: .userInitiated) {
                Self.parseSpeakersAndChannelNames(from: jsonPath)
            }.value
            guard !Task.isCancelled else { return }
            guard !speakers.isEmpty else {
                Logger.files.error("Rename: no speakers found in \(jsonPath.lastPathComponent, privacy: .sensitive)")
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
            self.present(jsonPath: jsonPath, speakers: speakers, channelNames: channelNames, onDismiss: onDismiss)
        }
    }

    /// Build and show the panel. Main actor; assumes `speakers` is non-empty.
    private func present(
        jsonPath: URL, speakers: [SpeakerEntry], channelNames: [String: [String: String]],
        onDismiss: (() -> Void)?
    ) {

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
            initialChannelNames: channelNames,
            onSave: { mapping in
                guard TranscriptRenamer.applyRenames(mapping, jsonPath: jsonPath) else {
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

    /// Up to 3 samples per speaker; speakers under 5 segments are usually diarization artifacts.
    /// Collection itself lives in `TranscriptRenamer` (TranscriberCore), shared with the CLI.
    /// - Parameter minSegments: speakers with fewer segments are dropped as diarization noise.
    ///   After an explicit **Re-detect** the user has asserted how many people are on the channel,
    ///   so dropping one of them for being quiet contradicts the answer they just gave — and leaves
    ///   them unable to name a speaker they can see in the transcript. Pass 1 there.
    nonisolated static func parseSpeakers(from jsonPath: URL, minSegments: Int = 5) -> [SpeakerEntry] {
        do {
            let collected = try TranscriptRenamer.collectSpeakerSamples(
                from: jsonPath, maxSamplesPerSpeaker: 3, minSegmentsPerSpeaker: minSegments
            )
            return collected.map { SpeakerEntry(id: $0.id, displayName: $0.id, samples: $0.samples) }
        } catch TranscriptRenamer.RenameError.cannotRead {
            Logger.files.error("Rename: cannot read \(jsonPath.lastPathComponent, privacy: .sensitive)")
            return []
        } catch {
            Logger.files.error("Rename: \(jsonPath.lastPathComponent, privacy: .sensitive) is not a readable transcript")
            return []
        }
    }

    /// `parseSpeakers`, from an already-parsed transcript — see `parseSpeakersAndChannelNames`.
    nonisolated static func parseSpeakers(json: [String: Any], minSegments: Int = 5) -> [SpeakerEntry] {
        let collected = TranscriptRenamer.collectSpeakerSamples(
            json: json, maxSamplesPerSpeaker: 3, minSegmentsPerSpeaker: minSegments)
        return collected.map { SpeakerEntry(id: $0.id, displayName: $0.id, samples: $0.samples) }
    }

    /// The `speaker_names` already saved for each channel, keyed "local"/"remote" (#207).
    ///
    /// Read ONCE (here, off-main, alongside `parseSpeakers`) instead of by the dialog re-reading
    /// and re-parsing the transcript on every "Re-detect" press just to decide whether a warning
    /// is needed. A single parse covers both channels since `TranscriptRediarizer.channelNames(in:
    /// source:)` takes already-parsed metadata and does no I/O of its own.
    nonisolated static func loadChannelNames(from jsonPath: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return loadChannelNames(json: json)
    }

    /// `loadChannelNames`, from an already-parsed transcript — see `parseSpeakersAndChannelNames`.
    nonisolated static func loadChannelNames(json: [String: Any]) -> [String: [String: String]] {
        guard let metadata = json["metadata"] as? [String: Any] else { return [:] }
        return [
            "local": TranscriptRediarizer.channelNames(in: metadata, source: "local"),
            "remote": TranscriptRediarizer.channelNames(in: metadata, source: "remote"),
        ]
    }

    /// `parseSpeakers` and `loadChannelNames` combined behind a SINGLE `Data(contentsOf:)` +
    /// JSON parse of the transcript, instead of each independently re-reading the same file.
    ///
    /// Both `show()` here and `RenameDialog`'s post-re-detect refresh need both results from the
    /// same transcript at the same moment — a stale-out-of-sync pair between two separate reads
    /// is unlikely but not impossible if something rewrites the file between them. More
    /// concretely, a recording directory can be iCloud-mounted, where `Data(contentsOf:)` blocks
    /// on the network per call — halving the round trips halves that latency.
    ///
    /// An unreadable/unparseable transcript degrades to `([], [:])`, matching what the two
    /// individual URL-based helpers above would have returned on the same failure.
    nonisolated static func parseSpeakersAndChannelNames(
        from jsonPath: URL, minSegments: Int = 5
    ) -> (speakers: [SpeakerEntry], channelNames: [String: [String: String]]) {
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Logger.files.error("Rename: cannot read \(jsonPath.lastPathComponent, privacy: .sensitive)")
            return ([], [:])
        }
        return (parseSpeakers(json: json, minSegments: minSegments), loadChannelNames(json: json))
    }

    // MARK: - Generate Format File

    /// `writeFormatFile` reads `output_format` itself and no-ops for json/unknown, so no
    /// pre-read guard is needed here.
    nonisolated static func generateFormatFile(jsonPath: URL) {
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }
    }
}
