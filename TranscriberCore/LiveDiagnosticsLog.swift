import Foundation
import os

/// Append-as-you-go anomaly log (§8.11): `<session>.diag.live.jsonl` next to the recording. Written
/// line by line so a crash loses at most the line in flight; merged into the ring at finalize.
///
/// Beside it, `<session>.diag.coverage.json` keeps the LATEST coverage of each helper session (council
/// A-I4 / C-I1): coverage otherwise lives only in `captureStop`, which a crashed helper never writes. One
/// small file, rewritten atomically on every status pull, whatever the length of the call.
public final class LiveDiagnosticsLog: @unchecked Sendable {
    public let url: URL
    public let coverageURL: URL
    private let lock = NSLock()

    /// One helper session's coverage (`remote_*` / `local_*` detail keys) as last pulled.
    public struct CoverageSnapshot: Codable, Equatable, Sendable {
        public let at: Date
        public let facts: [String: String]
        public init(at: Date, facts: [String: String]) { self.at = at; self.facts = facts }
    }
    /// Loaded from disk on first use (an earlier process may have written it), then kept in memory.
    private var coverageCache: [String: CoverageSnapshot]?

    // `.iso8601` (JSONEncoder's built-in strategy) drops sub-second precision, so a disk round-trip
    // and an in-memory ring event for the SAME anomaly would decode to different timestamps and
    // dedup would never match. Encode/decode with millisecond precision instead.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(LiveDiagnosticsLog.dateFormatter.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = LiveDiagnosticsLog.dateFormatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date with fractional seconds: \(s)")
            }
            return date
        }
        return d
    }()

    public init(directory: URL, sessionId: String) {
        url = directory.appendingPathComponent("\(sessionId).diag.live.jsonl")
        coverageURL = directory.appendingPathComponent("\(sessionId).diag.coverage.json")
    }

    /// Coverage evidence is `.info`, yet it is what the record's per-track coverage is built from: kept
    /// whatever its severity, or a crash loses every second of coverage before it (L11 ruling).
    static let coverageKinds: Set<CaptureEventKind> = [.captureStop, .trackCoverage]

    public func append(_ event: CaptureEvent) {
        guard event.severity != .info || Self.coverageKinds.contains(event.kind) else { return }
        guard var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else if (try? line.write(to: url, options: .atomic)) == nil {
            Logger.files.error("LiveDiagnosticsLog: could not write \(self.url.lastPathComponent, privacy: .sensitive)")
        }
    }

    public func events() -> [CaptureEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(CaptureEvent.self, from: $0) }
    }

    public func merged(into ring: CaptureDiagnostics) -> CaptureDiagnostics {
        // Same identity `CaptureDiagnostics` uses internally to make its own counting idempotent
        // (E2 fix round 1) — one definition, so the two can never drift apart.
        var seen = Set<String>()
        var result = ring
        var extra: [CaptureEvent] = []
        for e in ring.events { seen.insert(CaptureEvent.dedupKey(e)) }
        for e in events() where seen.insert(CaptureEvent.dedupKey(e)).inserted { extra.append(e) }
        result.merge(extra)
        return result
    }

    /// Keep `facts` as `helperSession`'s latest coverage.
    public func writeCoverage(helperSession: String, facts: [String: String], at date: Date) {
        lock.lock(); defer { lock.unlock() }
        var all = coverageCache ?? readCoverage()
        all[helperSession] = CoverageSnapshot(at: date, facts: facts)
        coverageCache = all
        guard let data = try? Self.encoder.encode(all), (try? data.write(to: coverageURL, options: .atomic)) != nil else {
            Logger.files.error("LiveDiagnosticsLog: could not write \(self.coverageURL.lastPathComponent, privacy: .sensitive)")
            return
        }
    }

    /// The latest coverage of every helper session of this recording session, by helper session id.
    public func coverageSnapshots() -> [String: CoverageSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return coverageCache ?? readCoverage()
    }

    private func readCoverage() -> [String: CoverageSnapshot] {
        guard let data = try? Data(contentsOf: coverageURL) else { return [:] }
        return (try? Self.decoder.decode([String: CoverageSnapshot].self, from: data)) ?? [:]
    }

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: coverageURL)
        coverageCache = nil
    }
}
