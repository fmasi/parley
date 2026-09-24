import Foundation
import os

/// Append-as-you-go anomaly log (§8.11): `<session>.diag.live.jsonl` next to the recording. Written
/// line by line so a crash loses at most the line in flight; merged into the ring at finalize.
public final class LiveDiagnosticsLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

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
        var seen = Set<String>()
        func key(_ e: CaptureEvent) -> String {
            "\(e.timestamp.timeIntervalSinceReferenceDate)|\(e.origin.rawValue)|\(e.kind.rawValue)|\(e.detail.sorted { $0.key < $1.key })"
        }
        var result = ring
        var extra: [CaptureEvent] = []
        for e in ring.events { seen.insert(key(e)) }
        for e in events() where seen.insert(key(e)).inserted { extra.append(e) }
        result.merge(extra)
        return result
    }

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
