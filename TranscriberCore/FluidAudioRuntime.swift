import Foundation
import os
import FluidAudio

/// Parley's settings for FluidAudio's process-wide switches.
///
/// - Airgap (#351): FluidAudio is offline except inside `allowingDownloads`. Offline, a model that
///   fails to load throws instead of being deleted and downloaded again in place (FluidAudio's
///   `ModelHub.loadModels` recovery), and a missing one throws instead of being fetched. Models
///   download only in Setup, on Settings Save and through the CLI's `download-models`, and those
///   paths go through `allowingDownloads`.
/// - Privacy (#343): FluidAudio's own log lines (some carry recognised words) go to the unified log
///   only, where their text is private, never to stderr; its debug lines are dropped.
public enum FluidAudioRuntime {
    static let downloads = ModelDownloadGate { offline in ModelHub.offlineMode = offline }

    /// The level below which FluidAudio's own messages are dropped.
    static let minimumLogLevel: AppLogger.Level = .info

    /// Apply Parley's settings. Idempotent and cheap: called at launch and before every model load,
    /// so no entry point (app, CLI, a test) can load a model with FluidAudio online.
    public static func configure() {
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = minimumLogLevel
        downloads.enforce()
    }

    /// Runs `body` with FluidAudio allowed to download. Only Setup, Settings Save and the CLI's
    /// `download-models` call this. A model load that runs at the same moment, on another task, is
    /// online too; Settings starts a download only while no recording is being processed.
    public static func allowingDownloads<T>(_ body: () async throws -> T) async rethrows -> T {
        configure()
        return try await downloads.allowing(body)
    }
}

/// Counts the downloads in progress and keeps a process-wide offline switch in step: offline while
/// none is running (#351). Thread-safe; the switch is set under the lock, so two scopes ending at
/// once can never leave it online.
public final class ModelDownloadGate: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: 0)
    private let setOffline: @Sendable (Bool) -> Void

    public init(setOffline: @escaping @Sendable (Bool) -> Void) {
        self.setOffline = setOffline
    }

    /// Whether a download scope is open.
    public var isAllowing: Bool { active.withLock { $0 > 0 } }

    /// Sets the switch to match the open scopes: offline when there are none.
    public func enforce() {
        active.withLock { setOffline($0 == 0) }
    }

    public func allowing<T>(_ body: () async throws -> T) async rethrows -> T {
        active.withLock { count in
            count += 1
            setOffline(false)
        }
        defer {
            active.withLock { count in
                count -= 1
                setOffline(count == 0)
            }
        }
        return try await body()
    }
}

/// FluidAudio's revision marker (`.fluidaudio-revision`, written into a model folder when a pinned
/// revision is downloaded). FluidAudio treats a pinned-revision folder without the matching marker
/// as stale and fetches the files again at load time; offline, it refuses to load it. So a model
/// counts as cached only when its marker matches (#351), and Setup downloads it instead of a
/// transcription failing.
public enum ModelRevisionMarker {
    static let fileName = ".fluidaudio-revision"

    /// Mirrors FluidAudio's `ModelCache.matchesRevision`: a `main` folder without a marker predates
    /// markers and is current; a pinned revision needs an exact marker.
    public static func matches(repoDir: URL, revision: String) -> Bool {
        let marker = repoDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: marker) else { return revision == "main" }
        guard let stored = String(data: data, encoding: .utf8) else { return false }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == revision
    }
}
