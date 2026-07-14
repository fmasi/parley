import Foundation
import Testing
@testable import TranscriberCore

/// Golden snapshot of the fully-resolved effective configuration (#137, item 5).
///
/// `embeddingExcludeOverlap: false` was a FLAG, not logic — no unit test of behaviour could see
/// it, and it collapsed every speaker into one cluster for months. This test serializes every
/// default that shapes a transcript — the app-level Config defaults, the resolved values the
/// runner consumes, and the complete FluidAudio diarizer config (via the SAME
/// `makeOfflineConfig()` production calls, so the snapshot cannot drift from reality) — and
/// compares it against a checked-in golden file.
///
/// Any change to any default — a human editing a value, or a FluidAudio bump silently moving
/// one of ITS defaults — becomes a red diff line a reviewer must approve.
///
/// To regenerate after an INTENTIONAL change:
///     UPDATE_GOLDEN=1 swift test --filter GoldenConfigTests   (plus the usual -Xswiftc/-Xlinker flags)
/// then review and commit the diff to resolved-config.golden.json. The default run only compares.
@Suite struct GoldenConfigTests {

    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/resolved-config.golden.json")
    }

    @Test func resolvedConfigMatchesGolden() throws {
        let actual = Self.renderResolvedConfig()

        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(actual.utf8).write(to: Self.goldenURL)
            print("GoldenConfigTests: rewrote \(Self.goldenURL.path)")
        }

        let golden = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        guard actual != golden else { return }

        // Line-level diff so the offending default is named in the failure, not buried.
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let goldenLines = golden.split(separator: "\n", omittingEmptySubsequences: false)
        var drift: [String] = []
        for i in 0..<max(actualLines.count, goldenLines.count) {
            let a = i < actualLines.count ? String(actualLines[i]) : "<missing>"
            let g = i < goldenLines.count ? String(goldenLines[i]) : "<missing>"
            if a != g { drift.append("line \(i + 1): golden `\(g)` -> actual `\(a)`") }
        }
        let message = "Resolved config drifted from the golden snapshot. A default changed — "
            + "if that is intentional, regenerate with UPDATE_GOLDEN=1 and commit the diff so a "
            + "human approves the new value. Drift:\n" + drift.joined(separator: "\n")
        Issue.record(Comment(rawValue: message))
    }

    // MARK: - Rendering

    /// The full resolved-config document. Deterministic: sorted keys, hand-rendered JSON (no
    /// dependence on JSONSerialization's formatting), fixed normalizations for the two
    /// machine-dependent values (home directory, OS-resolved engine).
    private static func renderResolvedConfig() -> String {
        let config = Config.default

        // The diarizer exactly as TranscriptionRunner.applyDiarizerConfig builds it.
        let diarizer = FluidAudioDiarizer(
            clusteringThreshold: config.diarizationClusteringThreshold,
            maxSpeakers: config.diarizationMaxSpeakers,
            excludeOverlap: config.resolvedDiarizationExcludeOverlap
        )

        let resolved: [(String, String)] = [
            ("chunk_duration_minutes", "\(config.validatedChunkDuration)"),
            ("chunk_processing_qos", quoted(String(describing: config.resolvedQos))),
            ("diarization_exclude_overlap", config.resolvedDiarizationExcludeOverlap ? "true" : "false"),
        ]

        let sections: [(String, String)] = [
            ("app_config_defaults", renderAppConfig(config)),
            ("fluidaudio_offline_diarizer", mirrorJSON(diarizer.makeOfflineConfig(), indent: "  ")),
            ("resolved", "{\n" + resolved.map { "    \"\($0.0)\": \($0.1)" }.joined(separator: ",\n") + "\n  }"),
        ]
        return "{\n" + sections.map { "  \"\($0.0)\": \($0.1)" }.joined(separator: ",\n") + "\n}\n"
    }

    /// Config.default via its own Codable path (the snake_case keys users see in config.json,
    /// nil optionals omitted exactly as a written config.json omits them), normalized so the
    /// golden is identical on every machine:
    ///   - recording_directory: the home prefix becomes "~"
    ///   - engine: resolvedDefault is OS-dependent (speechAnalyzer on macOS 26+, else
    ///     fluidAudio); the golden pins the rule as a string, and EngineIDTests covers the rule.
    private static func renderAppConfig(_ config: Config) -> String {
        guard let data = try? JSONEncoder().encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "\"<encoding failed>\"" }

        if let dir = dict["recording_directory"] as? String {
            dict["recording_directory"] = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        dict["engine"] = "<os-resolved: speechAnalyzer on macOS 26+, else fluidAudio>"

        let pairs = dict.keys.sorted().map { key -> String in
            "    \"\(key)\": \(renderJSONLeaf(dict[key]!))"
        }
        return "{\n" + pairs.joined(separator: ",\n") + "\n  }"
    }

    /// Values out of JSONSerialization: strings, and NSNumber (which needs the CFBoolean check
    /// because `"\(NSNumber(true))"` prints 1, not true).
    private static func renderJSONLeaf(_ value: Any) -> String {
        if let s = value as? String { return quoted(s) }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return "\(n)"
        }
        return quoted("\(value)")
    }

    // MARK: - Mirror -> deterministic JSON

    /// Reflection-based dump: captures EVERY stored property recursively, so a FluidAudio bump
    /// that adds or re-defaults a field changes the golden even though our code never mentions
    /// that field. That is the point — an explicit field list would only guard the defaults we
    /// already thought of.
    private static func mirrorJSON(_ subject: Any, indent: String) -> String {
        let mirror = Mirror(reflecting: subject)
        switch mirror.displayStyle {
        case .optional:
            guard let child = mirror.children.first else { return "null" }
            return mirrorJSON(child.value, indent: indent)
        case .struct, .class:
            let inner = indent + "  "
            let pairs = mirror.children
                .compactMap { child -> (String, String)? in
                    guard let label = child.label else { return nil }
                    return (label, mirrorJSON(child.value, indent: inner))
                }
                .sorted { $0.0 < $1.0 }
            guard !pairs.isEmpty else { return "{}" }
            return "{\n" + pairs.map { "\(inner)\"\($0.0)\": \($0.1)" }.joined(separator: ",\n")
                + "\n\(indent)}"
        case .enum:
            return quoted(String(describing: subject))
        default:
            if let b = subject as? Bool { return b ? "true" : "false" }
            if let s = subject as? String { return quoted(s) }
            return "\(subject)"  // Int / Double / Float — Swift's stable shortest description
        }
    }

    private static func quoted(_ value: String) -> String { "\"\(value)\"" }
}
