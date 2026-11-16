import AppKit
import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers
import os

/// Opens the recording picker (#29) as a floating NSPanel: the menu's "Rename Speakers…" for any past recording.
/// The panel is up at once; the recordings folder is scanned behind it, off the main thread and bounded
/// (`RenameReads.recentRecordings`), so a share that does not answer shows a note, never a frozen menu.
@MainActor
final class RecordingPickerWindowController: NSObject, NSWindowDelegate {
    static let shared = RecordingPickerWindowController()
    private var panel: NSPanel?
    private var loadTask: Task<Void, Never>?

    /// Show the picker over the recordings under `root`. `latest` (the menu's last transcript) is listed even when the
    /// recordings folder has changed since. `onOpen` gets the transcript chosen, from the list or Choose File….
    func show(root: URL, latest: URL?, appState: AppState, onOpen: @escaping @MainActor (URL) -> Void) {
        loadTask?.cancel()
        panel?.close()
        panel = nil

        let model = RecordingPickerModel()
        let newPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        // Bound to THIS panel: a late scan or click from a replaced picker must not close a newer one.
        let close = { [weak self, weak newPanel] in
            newPanel?.close()
            if let self, self.panel === newPanel {
                self.panel = nil
                self.loadTask?.cancel()
            }
        }
        let view = RecordingPickerView(
            model: model,
            appState: appState,
            onOpen: { transcript in
                close()
                onOpen(transcript)
            },
            onChooseFile: { [weak self] in
                guard let picked = self?.chooseTranscript(in: root) else { return }
                close()
                onOpen(picked)
            },
            onCancel: close
        )

        newPanel.title = "Rename Speakers"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: view)
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
        panel = newPanel
        Logger.state.debug("Panel shown: RecordingPicker")

        loadTask = Task { @MainActor in
            let scan = await RenameReads.shared.recentRecordings(root: root, latest: latest)
            guard !Task.isCancelled else { return }
            switch scan {
            case nil:
                Logger.files.error("Recording picker: the recordings folder did not answer in time")
                model.state = .timedOut
            case let scan? where !scan.folderReadable && scan.recordings.isEmpty:
                Logger.files.error("Recording picker: the recordings folder could not be listed")
                model.state = .folderUnreadable
            case let scan?:
                Logger.files.info("Recording picker: \(scan.recordings.count, privacy: .public) recording(s) listed, \(scan.unreadableDays, privacy: .public) day folder(s) unreadable")
                model.state = .loaded(scan.recordings, note: scan.note)
            }
        }
    }

    /// Choose File…: any transcript, the recordings folder first.
    private func chooseTranscript(in root: URL) -> URL? {
        let open = NSOpenPanel()
        open.title = "Choose a transcript"
        open.message = "Select the transcript (.json) whose speakers you want to rename."
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.directoryURL = root
        NSApp.activate()
        return open.runModal() == .OK ? open.url : nil
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let closing = notification.object as? NSPanel, closing === panel else { return }
            Logger.state.debug("Panel closed via window button: RecordingPicker")
            panel = nil
            loadTask?.cancel()
        }
    }
}
