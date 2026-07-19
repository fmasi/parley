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
        showTask = Task { @MainActor in
            let speakers = await Task.detached(priority: .userInitiated) {
                Self.parseSpeakers(from: jsonPath)
            }.value
            guard !Task.isCancelled else { return }
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
    nonisolated static func parseSpeakers(from jsonPath: URL) -> [SpeakerEntry] {
        do {
            let collected = try TranscriptRenamer.collectSpeakerSamples(
                from: jsonPath, maxSamplesPerSpeaker: 3, minSegmentsPerSpeaker: 5
            )
            return collected.map { SpeakerEntry(id: $0.id, displayName: $0.id, samples: $0.samples) }
        } catch TranscriptRenamer.RenameError.cannotRead {
            Logger.files.error("Rename: cannot read \(jsonPath.lastPathComponent, privacy: .private)")
            return []
        } catch {
            Logger.files.error("Rename: \(jsonPath.lastPathComponent, privacy: .private) is not a readable transcript")
            return []
        }
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
