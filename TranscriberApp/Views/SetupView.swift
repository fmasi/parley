import SwiftUI
import AppKit
import TranscriberCore

struct SetupView: View {
    /// Single source of truth for the window's initial/minimum size, shared
    /// with `SetupWindowController` so the two can't drift out of sync.
    static let preferredSize = CGSize(width: 460, height: 620)

    @Bindable var permissionManager: PermissionManager
    let configManager: ConfigManager
    let onReady: () -> Void

    @State private var selectedEngine: EngineID
    @State private var recordingDirectory: String
    @State private var downloadState: DownloadState = .idle
    @State private var downloadTask: Task<Void, Never>?
    @State private var folderCheckDenied = false
    @State private var checkingFolder = false

    private var modelReady: Bool {
        !selectedEngine.descriptor.requiresModelDownload
            || (FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady())
            || downloadState == .done
    }

    private var canContinue: Bool {
        // Deliberately NOT gated on folderCheckDenied: the only way to clear a
        // denial is to grant folder access in System Settings and press
        // Continue again (there's no "picked a different folder" event to
        // reset it on otherwise). Gating here would strand the user behind a
        // permanently disabled button. The footer message + scroll-into-view
        // below give the denial visibility instead.
        //
        // This relies on the Continue action resetting folderCheckDenied to
        // false before re-running verifyFolderAccess (see below) — that's
        // what drives the true -> false -> true transition on repeated
        // failures, keeping onChange(of: folderCheckDenied)'s scroll trigger
        // alive across retries. If that reset were ever dropped, the scroll
        // would silently stop firing after the first denial.
        permissionManager.allRequiredGranted && modelReady && !checkingFolder
    }

    init(permissionManager: PermissionManager, configManager: ConfigManager, onReady: @escaping () -> Void) {
        self.permissionManager = permissionManager
        self.configManager = configManager
        self.onReady = onReady
        self._selectedEngine = State(initialValue: configManager.config.engine)
        self._recordingDirectory = State(initialValue: configManager.config.recordingDirectory)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable so the footer (Continue) stays reachable even if the
            // window is resized shorter than the content, or content grows
            // (e.g. the download progress row) past the window's fixed height.
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        hero

                        SetupCard(header: "Required to record") {
                            PermissionRow(
                                tile: IconTile(systemImage: "mic.fill", color: .red),
                                name: "Microphone",
                                detail: "Record your voice during meetings",
                                status: permissionManager.microphone,
                                pane: .microphone,
                                onGrant: { Task { await permissionManager.requestMicrophone() } }
                            )
                            Divider()
                            PermissionRow(
                                tile: IconTile(systemImage: "rectangle.inset.filled.and.person.filled", color: .blue),
                                name: "Screen Recording",
                                detail: "Capture system audio from meeting apps",
                                status: permissionManager.screenRecording,
                                pane: .screenRecording,
                                onGrant: { Task { await permissionManager.requestScreenRecording() } }
                            )
                        }

                        SetupCard(header: "Optional") {
                            PermissionRow(
                                tile: IconTile(systemImage: "calendar", color: .orange),
                                name: "Calendar",
                                detail: "Suggest recording name from current meeting",
                                status: permissionManager.calendar,
                                pane: .calendar,
                                onGrant: { Task { await permissionManager.requestCalendar() } }
                            )
                            Divider()
                            PermissionRow(
                                tile: IconTile(systemImage: "bell.badge.fill", color: .purple),
                                name: "Notifications",
                                detail: "Alert you when transcription finishes",
                                status: permissionManager.notifications,
                                pane: .notifications,
                                onGrant: { Task { await permissionManager.requestNotifications() } }
                            )
                        }

                        SetupCard(header: "Recordings") {
                            FolderPickerRow(
                                directory: $recordingDirectory,
                                denied: folderCheckDenied
                            )
                        }
                        .id("recordingsCard")

                        SetupCard(header: "Transcription") {
                            engineRow
                        }
                        .id("transcriptionCard")
                    }
                    .padding(28)
                }
                .onChange(of: folderCheckDenied) { _, denied in
                    // The denial message lives in this card, below the fold in
                    // the common case — scroll it into view instead of leaving
                    // the user to wonder why Continue didn't do anything.
                    // .top (not .center): at the window's minimum height the
                    // Required/Optional cards would otherwise land entirely
                    // above the fold, hiding permission state the user may
                    // still need to check.
                    guard denied else { return }
                    withAnimation {
                        scrollProxy.scrollTo("recordingsCard", anchor: .top)
                    }
                }
                .onAppear {
                    // onAppear fires before SwiftUI's layout pass completes, so
                    // scrollTo has no registered position yet and would silently
                    // no-op. The Task defers to the next main-actor iteration
                    // (after layout), which is where ScrollViewProxy.scrollTo
                    // expects to be called anyway — so this is both correct and safe.
                    Task { @MainActor in
                        scrollToTranscriptionCardIfNeeded(scrollProxy, animated: false)
                    }
                }
                .onChange(of: modelReady) { _, ready in
                    guard !ready else { return }
                    scrollToTranscriptionCardIfNeeded(scrollProxy, animated: true)
                }
                .onChange(of: permissionManager.allRequiredGranted) { _, granted in
                    // Covers the common first-launch path: onAppear's scroll
                    // no-ops while permissions are still ungranted (by
                    // design, see scrollToTranscriptionCardIfNeeded), and
                    // modelReady doesn't change when permissions do — so
                    // without this, finishing permissions never reveals an
                    // already-known-not-ready Transcription card.
                    guard granted else { return }
                    scrollToTranscriptionCardIfNeeded(scrollProxy, animated: true)
                }
            }

            Divider()

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        // Width only — no height constraint here. The ScrollView already
        // fills whatever height the window (resizable, see
        // SetupWindowController) offers, with the footer pinned outside it,
        // so the content is correct both when the window is taller than
        // preferredSize (no dead space) and shorter (content scrolls,
        // footer stays reachable). A `minHeight` here would fight
        // `contentMinSize`'s shrink floor in SetupWindowController.
        .frame(minWidth: Self.preferredSize.width, maxWidth: Self.preferredSize.width)
    }

    // MARK: - Sections

    /// The first thing a new user sees: the product promise, not a permission ask.
    private var hero: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Welcome to Parley")
                .font(.title)
                .fontWeight(.bold)
            Text("Private, on-device meeting transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            // Explain the gate instead of a mutely disabled button; once ready,
            // restate the promise.
            Group {
                if !permissionManager.allRequiredGranted {
                    Label("Grant the required permissions to continue.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if !modelReady {
                    Label("Download the transcription model to continue.", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                } else if folderCheckDenied {
                    Label("Grant folder access above, then try again.", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.orange)
                } else {
                    Label("Everything stays on this Mac.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)

            Spacer(minLength: 0)

            Button(checkingFolder ? "Checking…" : "Continue") {
                // Persist the chosen directory before verifying access.
                configManager.update { $0.recordingDirectory = recordingDirectory }
                checkingFolder = true
                folderCheckDenied = false
                Task {
                    let granted = await verifyFolderAccess(recordingDirectory)
                    checkingFolder = false
                    if granted {
                        onReady()
                    } else {
                        folderCheckDenied = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    @ViewBuilder
    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                IconTile(systemImage: "waveform", color: .indigo)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine").fontWeight(.medium)
                    Picker("Engine", selection: $selectedEngine) {
                        ForEach(EngineID.availableEngines) { engine in
                            Text(engine.descriptor.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: selectedEngine) { _, newEngine in
                        configManager.update { $0.engine = newEngine }
                        downloadTask?.cancel()
                        downloadTask = nil
                        downloadState = .idle
                    }
                }

                Spacer()

                engineBadge
            }

            // Full-width progress bar shown while downloading
            if case .downloading(let fraction) = downloadState {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.leading, 38)
            }
        }
    }

    @ViewBuilder
    private var engineBadge: some View {
        if selectedEngine.descriptor.requiresModelDownload {
            switch downloadState {
            case .idle:
                if FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady() {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Download") { startDownload() }
                        .controlSize(.small)
                }
            case .downloading:
                EmptyView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Retry") { startDownload() }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Mirrors the folderCheckDenied scroll trigger: the Transcription card
    /// (Download button) can land below the fold at preferredSize.height,
    /// especially with the download-progress row visible. Runs on first
    /// appearance (a user can open Setup with an uncached model already
    /// selected) and again if switching engines makes the model not-ready.
    ///
    /// Gated on `allRequiredGranted`: without it, this would yank the user's
    /// scroll position away from the Required card while they're still
    /// clicking Grant buttons there, down to a Transcription card they can't
    /// act on until permissions are done anyway.
    private func scrollToTranscriptionCardIfNeeded(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !modelReady, permissionManager.allRequiredGranted else { return }
        if animated {
            withAnimation { proxy.scrollTo("transcriptionCard", anchor: .top) }
        } else {
            proxy.scrollTo("transcriptionCard", anchor: .top)
        }
    }

    private func verifyFolderAccess(_ directory: String) async -> Bool {
        let dir = ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
        return await Task.detached {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                // Enumerate first — hits the same TCC code path as StorageManager.currentUsageBytes,
                // ensuring the system folder-access prompt fires here rather than later in Settings.
                _ = try FileManager.default.contentsOfDirectory(atPath: dir)
                // Write probe — confirms the directory is actually writable, not just readable.
                // A read-only directory would pass TCC but fail at recording time.
                let probe = url.appendingPathComponent(".transcriber-write-probe-\(UUID().uuidString)")
                try Data("probe".utf8).write(to: probe, options: .atomic)
                try FileManager.default.removeItem(at: probe)
                return true
            } catch {
                return false
            }
        }.value
    }

    private func startDownload() {
        downloadState = .downloading(0)
        downloadTask = Task {
            do {
                try await FluidAudioEngine.preDownloadModel { fraction in
                    Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        downloadState = .downloading(fraction * 0.98)
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { downloadState = .downloading(0.98) }
                try await FluidAudioDiarizer.preDownloadModels()
                guard !Task.isCancelled else { return }
                await MainActor.run { downloadState = .done }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    downloadState = .failed(error.localizedDescription)
                }
            }
        }
    }
}

private enum DownloadState: Equatable {
    case idle
    case downloading(Double)
    case done
    case failed(String)
}

/// A grouped card with a quiet section header — System Settings-adjacent.
private struct SetupCard<Content: View>: View {
    let header: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quinary)
            )
        }
    }
}

/// Shows the recording folder path with a picker button.
/// Access is verified when the user clicks Continue, not on appear.
private struct FolderPickerRow: View {
    @Binding var directory: String
    let denied: Bool

    private var displayPath: String {
        abbreviatedDisplayPath(directory)
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "folder.fill", color: .gray)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Folder").fontWeight(.medium)
                Text(displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if denied {
                    Text("Access denied — grant access in System Settings › Privacy & Security › Files and Folders")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if denied {
                Button("Open Settings") { PrivacyPane.filesAndFolders.open() }
                    .controlSize(.small)
            } else {
                Button("Choose…") {
                    if let path = chooseFolderPath(message: "Choose where to save recordings") {
                        directory = path
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

private struct PermissionRow: View {
    let tile: IconTile
    let name: String
    let detail: String
    let status: PermissionStatus
    let pane: PrivacyPane
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            tile

            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button("Grant") { onGrant() }
                .controlSize(.small)
        case .denied:
            Button("Open Settings") { pane.open() }
                .controlSize(.small)
        }
    }
}
