import Foundation
import os

/// Append-as-you-go anomaly log (§8.11): `<session>.diag.live.jsonl` next to the recording. Written
/// line by line so a crash loses at most the line in flight; merged into the ring at finalize.
public final class LiveDiagnosticsLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

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
    }

    public func append(_ event: CaptureEvent) {
        guard event.severity != .info else { return }
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

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
