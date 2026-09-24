import Foundation

/// Run the chosen engine on one synthetic second before trusting it with a meeting (§11.2).
public enum EnginePreflight {
    public enum Failure: Error, Equatable { case engineThrew(String) }

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
