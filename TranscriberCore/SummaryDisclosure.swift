import Foundation

/// Disclosure stamp (#138): the transcript's own record of whether its contents were ever
/// transmitted off this machine.
///
/// Parley is airgapped by default for meeting content — the only path by which a transcript's
/// text can leave the machine is summary generation against a user-configured endpoint. This
/// stamp makes that property auditable from the artifact itself: every transcript carries an
/// explicit `disclosure` block. When no summary was generated, that is stated explicitly
/// rather than by omission — an absent field is ambiguous; an explicit `false` is evidence.
public struct SummaryDisclosure: Equatable, Sendable {
    /// Whether a summary was successfully generated from this transcript.
    public let summaryGenerated: Bool
    /// Classification + host of the summary endpoint, e.g. `"local (127.0.0.1:1234)"` or
    /// `"remote (api.openai.com)"`. Host (plus port when local) ONLY — never the full URL,
    /// path, query, or any credential the configured endpoint string may carry (#134: the
    /// endpoint URL can embed a token on some proxies). `nil` when no summary was attempted.
    public let summaryEndpoint: String?
    /// Whether the transcript's contents were (or may have been) sent to a remote endpoint.
    public let transcriptTransmitted: Bool

    public init(summaryGenerated: Bool, summaryEndpoint: String?, transcriptTransmitted: Bool) {
        self.summaryGenerated = summaryGenerated
        self.summaryEndpoint = summaryEndpoint
        self.transcriptTransmitted = transcriptTransmitted
    }

    /// The airgapped default stamped into every transcript at assembly: no summary was
    /// generated and nothing was transmitted.
    public static let airgapped = SummaryDisclosure(
        summaryGenerated: false, summaryEndpoint: nil, transcriptTransmitted: false
    )

    /// Disclosure for a summary attempt that has been dispatched but has not (yet) produced
    /// a summary. For a remote endpoint this already records `transcript_transmitted: true` —
    /// once the request is sent, the content has left the machine whether or not a summary
    /// comes back.
    public static func attempted(endpoint: String) -> SummaryDisclosure {
        build(endpoint: endpoint, generated: false)
    }

    /// Disclosure for a successfully generated summary against `endpoint`.
    public static func generated(endpoint: String) -> SummaryDisclosure {
        build(endpoint: endpoint, generated: true)
    }

    private static func build(endpoint: String, generated: Bool) -> SummaryDisclosure {
        let (label, isRemote) = classify(endpoint: endpoint)
        return SummaryDisclosure(
            summaryGenerated: generated,
            summaryEndpoint: label,
            transcriptTransmitted: isRemote
        )
    }

    /// Classify a configured endpoint URL as on-device vs remote and produce the host-only
    /// label. Conservative on purpose: only clear loopback *literals* (`localhost`, `::1`,
    /// `127.0.0.0/8`) count as local. A hostname that merely *resolves* to loopback (e.g.
    /// `my-mac.local`), a LAN/private-range address (`192.168.x.x`), or an expanded IPv6
    /// loopback form all classify as remote — for an audit stamp, over-claiming a disclosure
    /// is the safe direction; denying one that happened is not.
    /// An unparsable endpoint yields `"remote (unknown)"` — the raw string is never echoed
    /// because it may carry a credential (#134).
    static func classify(endpoint: String) -> (label: String, isRemote: Bool) {
        guard let components = URLComponents(string: endpoint),
              let host = components.host, !host.isEmpty
        else {
            return ("remote (unknown)", true)
        }
        if isLoopbackLiteral(host) {
            let hostPort = components.port.map { "\(host):\($0)" } ?? host
            return ("local (\(hostPort))", false)
        }
        return ("remote (\(host))", true)
    }

    /// True only for unambiguous loopback literals: `localhost`, `::1`, or a strict IPv4
    /// dotted-quad in `127.0.0.0/8`.
    static func isLoopbackLiteral(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    /// Build the snake_case dictionary embedded in transcript metadata under `disclosure`,
    /// alongside `capture_provenance`.
    public func asMetadataDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "summary_generated": summaryGenerated,
            "transcript_transmitted": transcriptTransmitted,
        ]
        if let summaryEndpoint { d["summary_endpoint"] = summaryEndpoint }
        return d
    }
}
