import Foundation

/// Run the chosen engine on one synthetic second before trusting it with a meeting (§11.2).
public enum EnginePreflight {
    public enum Failure: Error, Equatable { case engineThrew(String) }

    /// What a Settings Save does about the chosen engine.
    public enum SaveStep: Equatable, Sendable {
        /// Run it on the synthetic second, and commit the settings only when it passes.
        case preflightThenCommit
        /// Its model is not downloaded yet, so there is nothing to run: commit, and the Save starts the download.
        case commitThenDownload
    }

    /// A model that is missing is not a broken engine: an engine without its model can only throw "not downloaded", and
    /// refusing the Save on that refuses the one action that downloads it. Everything else is preflighted — an engine with
    /// no download of Parley's (Apple Speech) always.
    ///
    /// A model the user chose to re-download (`redownloadChosen`, #349) is never preflighted either: it may be the one that
    /// failed verification, and loading a corrupt model makes FluidAudio delete the cache and download again in place,
    /// unstaged (#351). The Save commits and runs the staged re-download instead.
    public static func saveStep(for engine: EngineID, modelCached: Bool, redownloadChosen: Bool = false) -> SaveStep {
        engine.descriptor.requiresModelDownload && (!modelCached || redownloadChosen)
            ? .commitThenDownload : .preflightThenCommit
    }

    public static func run(engine: any TranscriptionEngine, scratchDirectory: URL = FileManager.default.temporaryDirectory) async throws {
        let url = scratchDirectory.appendingPathComponent("parley-preflight-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticWAV.write(to: url, seconds: 1)
        do {
            _ = try await engine.transcribe(audioPath: url, language: nil, audioSource: .system)
        } catch {
            throw Failure.engineThrew("\(error)")
        }
    }
}
