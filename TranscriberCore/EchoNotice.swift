import Foundation

/// What the UI says about echo: the other side's voice, played by the loudspeakers and picked up by
/// the microphone, which the diarizer then finds as a speaker of its own on this side (#244).
///
/// On a real call the rename dialog showed that voice as "Local Speaker 2" with nothing to explain
/// it, and offered the speaker count as the fix; taking it put the other participant's words under
/// the user's name. The echo check (#242) and the re-detect guard (#243) now handle the audio side;
/// this is the part that tells the person looking at the dialog what they are looking at.
///
/// Everything here is built from what the transcript's metadata already records (`echo_clusters`,
/// `echo_segments_flagged`, `speaker_count_<track>`, `speaker_names`): nothing is recomputed from
/// the segments, which are read only for the labels the remote lines carry (to name a renamed
/// remote speaker, #270), and only `Findings.read(transcriptAt:)` touches a file.
///
/// The copy:
/// - names the other side's speakers as a person sees them now (#270): the label `echo_clusters`
///   holds ("Remote Speaker 1"), or the name a rename gave it, when `speaker_names` and the remote
///   lines settle it (`TranscriptRenamer.currentLabel`); a label they do not settle is left out, and
///   with none left the card says "the other side". A rename does not rewrite the record, so it is
///   resolved here; a re-detect of the remote channel remaps or drops the keys it renumbered
///   (`TranscriptRediarizer.remappingMatchedRemote`), and a record re-detected by an older build
///   quotes none (`TranscriptRediarizer.matchedRemoteIsCurrent`);
/// - describes a match ("looks like"), never a fact. The check sees lines on this side that repeat
///   the other side's words at the same moment. That is nearly always the other side through the
///   loudspeakers; it is also what the mirror case looks like (this side's voice coming back on the
///   other side's track), and the numbers are true of both.
public enum EchoNotice {

    // MARK: - What the metadata records

    /// One speaker label the echo check judged to be echo, summed over its `echo_clusters` entries.
    ///
    /// A label has one entry per chunk (and, after a re-detect, one per raw cluster), so its numbers
    /// are sums. Every entry of the label counts, whatever its own verdict: the same voice can be
    /// too short to judge in one chunk and is still this label's lines. In such a chunk a matched
    /// line of one or two words is not flagged, so `matchedLines` can exceed the lines actually
    /// marked by those few.
    public struct Voice: Equatable, Sendable {
        /// `"local"` — the only channel the check judges.
        public let track: String
        /// The label as `echo_clusters` holds it ("Local Speaker 2").
        public let label: String
        /// The label's lines the check looked at.
        public let lines: Int
        /// Those that repeat the other side at the same time. Never more than `lines`.
        public let matchedLines: Int
        /// The share of the label's speaking time those lines hold, 0...100 — the measure the
        /// verdict is taken on, and not the same number as `matchedLines / lines`.
        public let percent: Int
        /// The other side's speakers its matched lines repeat, most matched seconds first: the label
        /// the check recorded, or the name a rename gave it since (#270).
        public let remoteLabels: [String]

        /// The lines that match nothing on the other side: they stay unflagged under the label.
        public var otherLines: Int { lines - matchedLines }
    }

    /// What a transcript's metadata says about echo, for the three places that mention it.
    public struct Findings: Equatable, Sendable {
        /// The labels with at least one `"echo"` verdict, by track then label. A label whose entries
        /// are all `"kept"` is somebody on this side and is never listed.
        public let voices: [Voice]
        /// `metadata.echo_segments_flagged`: every line marked as echo, in or out of an echo voice.
        public let flaggedLines: Int
        /// `metadata.speaker_count_<track>`: the people a re-detect found on a channel, where one ran.
        public let recordedPeople: [String: Int]
        /// `metadata.speaker_names`: the name each label was given, as each rename recorded it.
        let names: [String: String]

        /// A transcript that records no echo, or that could not be read.
        public static let none = Findings(metadata: [:])

        /// From a transcript's `metadata`. An entry that is not a verdict (no label, no verdict) is
        /// skipped; a number that is missing, negative or not finite counts as 0.
        ///
        /// - Parameter remoteSpeakers: the labels the remote channel's lines carry now, which say
        ///   which name a renamed remote speaker holds (`TranscriptRenamer.currentLabel`, #270). nil
        ///   when the lines are not known; `init(json:)` passes them.
        public init(metadata: [String: Any], remoteSpeakers: Set<String>? = nil) {
            struct Key: Hashable { let track: String, label: String }
            struct Sum {
                var lines = 0.0, matched = 0.0, seconds = 0.0, matchedSeconds = 0.0
                var remote: [String: Double] = [:]
                var isEcho = false
            }
            func number(_ value: Any?) -> Double {
                guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return 0 }
                return min(max(value, 0), 1e9)
            }
            // The renames, to quote the other side's speakers by what they are called now (#270). A
            // record whose remote labels belong to a clustering that no longer exists quotes none.
            let names = metadata["speaker_names"] as? [String: String] ?? [:]
            let remoteKnown = TranscriptRediarizer.matchedRemoteIsCurrent(in: metadata)
            var sums: [Key: Sum] = [:]
            for case let entry as [String: Any] in metadata["echo_clusters"] as? [Any] ?? [] {
                guard let label = entry["label"] as? String, let verdict = entry["verdict"] as? String else { continue }
                let key = Key(track: entry["track"] as? String ?? "local", label: label)
                var sum = sums[key] ?? Sum()
                sum.lines += number(entry["segments"])
                sum.matched += number(entry["matched_segments"])
                sum.seconds += number(entry["seconds"])
                sum.matchedSeconds += number(entry["matched_seconds"])
                // The key is the remote label the check saw; a rename since gave that speaker a name, and
                // two labels given one name are one person, their seconds adding up. A key whose name
                // the renames cannot settle is left out, never guessed: no key left reads "the other side".
                for (remote, seconds) in entry["matched_remote"] as? [String: Any] ?? [:] where remoteKnown {
                    guard let now = TranscriptRenamer.currentLabel(of: remote, names: names, present: remoteSpeakers)
                    else { continue }
                    sum.remote[now, default: 0] += number(seconds)
                }
                if verdict == EchoDeduplicator.ClusterVerdict.Verdict.echo.rawValue { sum.isEcho = true }
                sums[key] = sum
            }
            voices = sums.filter(\.value.isEcho)
                .sorted { ($0.key.track, $0.key.label) < ($1.key.track, $1.key.label) }
                .map { key, sum in
                    Voice(track: key.track, label: key.label,
                          lines: Int(sum.lines), matchedLines: Int(min(sum.matched, sum.lines)),
                          percent: sum.seconds > 0 ? Int((min(sum.matchedSeconds / sum.seconds, 1) * 100).rounded()) : 0,
                          // Equal seconds: by label, so the copy is the same from one open to the next.
                          remoteLabels: sum.remote.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key))
                }
            flaggedLines = Int(number(metadata["echo_segments_flagged"]))
            var people: [String: Int] = [:]
            for (key, value) in metadata where key.hasPrefix("speaker_count_") && value as? NSNumber != nil {
                people[String(key.dropFirst("speaker_count_".count))] = Int(number(value))
            }
            recordedPeople = people
            self.names = names
        }

        /// From a parsed transcript (its root object).
        public init(json: [String: Any]) {
            var remote: Set<String> = []
            for case let segment as [String: Any] in json["segments"] as? [Any] ?? [] where segment["source"] as? String == "remote" {
                if let speaker = segment["speaker"] as? String { remote.insert(speaker) }
            }
            self.init(metadata: json["metadata"] as? [String: Any] ?? [:], remoteSpeakers: remote)
        }

        /// From a transcript on disk; `.none` when it cannot be read. Synchronous file I/O — call it
        /// off the main actor.
        public static func read(transcriptAt url: URL) -> Findings {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .none }
            return Findings(json: json)
        }

        /// Every label the rows of a dialog can show a cluster under: the one `echo_clusters` holds,
        /// then each name a rename gave it. `speaker_names` maps the label current at each rename to
        /// the new one, so a twice-renamed speaker is a chain — followed here, and a loop in it
        /// (renamed there and back) ends it.
        private func rowLabels(of label: String) -> [String] {
            var labels = [label]
            while let next = names[labels[labels.count - 1]], !labels.contains(next) { labels.append(next) }
            return labels
        }

        /// The echo voice a speaker row stands for, if it is one. `row` is the row's label: the
        /// speaker label, or the name it was given.
        public func voice(forRow row: String) -> Voice? {
            voices.first { rowLabels(of: $0.label).contains(row) }
        }

        /// The notice on a speaker card, nil when the row is not an echo voice.
        public func cardNotice(forRow row: String) -> String? {
            voice(forRow: row).map(EchoNotice.cardNotice(for:))
        }

        /// The hint under a channel's re-detect row, nil when the channel has no echo voice.
        public func redetectHint(on track: String) -> String? {
            EchoNotice.redetectHint(echoVoices: voices.filter { $0.track == track }.count)
        }

        /// How many PEOPLE the speaker-count stepper offers for a channel: its rows that are neither
        /// an echo voice nor the channel's unattributed label ("Remote Unknown"). A stated count is a
        /// count of people (`SpeakerCountEnforcer` keeps an echo cluster out of it, and the stored
        /// `speaker_count_<track>` leaves the unattributed label out), so pre-filling the number of
        /// rows would ask for one speaker too many (#244, #360).
        ///
        /// Never below what a re-detect recorded in `speaker_count_<track>` — the rows leave out a
        /// speaker with only a few lines — and never below 1, the least the stepper can ask for.
        ///
        /// - Parameter rows: the labels of the channel's speaker rows.
        public func people(on track: String, rows: [String]) -> Int {
            var notPeople = Set(voices.filter { $0.track == track }.flatMap { rowLabels(of: $0.label) })
            notPeople.insert(SpeakerAssignment.unattributedLabel(source: track))
            return max(1, rows.filter { !notPeople.contains($0) }.count, recordedPeople[track] ?? 0)
        }

        /// The lines the completion notice counts: 0 when no label was judged echo, else every line
        /// marked as echo (the echo voices' matched lines, should the stamped count be missing).
        public var completionLines: Int {
            voices.isEmpty ? 0 : max(flaggedLines, voices.reduce(0) { $0 + $1.matchedLines })
        }
    }

    // MARK: - Copy

    /// The speaker card of an echo voice: what it looks like, the match behind that, and what
    /// happened to its lines.
    public static func cardNotice(for voice: Voice) -> String {
        let one = voice.matchedLines == 1
        var text = "Looks like the other side's voice through your loudspeakers: "
            + "\(voice.matchedLines) of \(lines(voice.lines)) (\(voice.percent)% of its speaking time) "
            + "\(one ? "matches" : "match") \(list(voice.remoteLabels)) at the same time "
            + "and \(one ? "is" : "are") marked as echo."
        if voice.otherLines == 1 {
            text += " The other line stays under this label."
        } else if voice.otherLines > 1 {
            text += " The other \(voice.otherLines) lines stay under this label."
        }
        return text
    }

    /// Under a channel's re-detect row, before it is pressed: what the count asks for, and what a
    /// re-detect does with an echo voice. nil without one.
    ///
    /// The count is the people on this side (#265): re-detect leaves the diarizer room for one more
    /// voice and looks for the echo voice itself, so the hint no longer asks the user to count around
    /// it. "Looks for", not a promise: a diarizer that blends the echo voice into a person even with
    /// that room leaves nothing to keep apart, and only the lines that repeat the other side's words
    /// are marked.
    public static func redetectHint(echoVoices: Int) -> String? {
        guard echoVoices > 0 else { return nil }
        return echoVoices == 1
            ? "Set the number of people on this side. Re-detect looks for the echo voice on its own and "
                + "keeps it apart when it finds it; its matched lines stay marked as echo."
            : "Set the number of people on this side. Re-detect looks for the echo voices on their own and "
                + "keeps them apart when it finds them; their matched lines stay marked as echo."
    }

    /// Under a channel's re-detect row, after it ran: the people found, the echo voices kept out of
    /// the merge, the lines marked as echo, the lines relabeled. Without echo it reads as it did
    /// before the check existed.
    public static func redetectOutcome(_ outcome: TranscriptRediarizer.Outcome) -> String {
        var parts = ["\(outcome.speakerCount) speaker\(outcome.speakerCount == 1 ? "" : "s") found"]
        if outcome.echoClusters > 0 {
            parts.append("\(outcome.echoClusters) echo voice\(outcome.echoClusters == 1 ? "" : "s") kept separate")
        }
        if outcome.echoFlagged > 0 { parts.append("\(lines(outcome.echoFlagged)) marked as echo") }
        parts.append("\(lines(outcome.segmentsRelabeled)) relabeled")
        return parts.joined(separator: " · ")
    }

    /// The completion notification's title, after "Transcription Complete — ", when the recording
    /// has an echo voice and nothing that is a problem.
    public static let completionTitle = "echo marked"

    /// The completion notification's clause for a recording with an echo voice; nil when no line is
    /// marked. Lower case and unpunctuated: `CaptureQualityNotice.completionBody` joins it to the rest.
    public static func completionNotice(lines count: Int) -> String? {
        guard count > 0 else { return nil }
        return "it looks like part of the other side's voice came through your microphone, and "
            + "\(lines(count)) \(count == 1 ? "is" : "are") marked as echo (headphones avoid this)"
    }

    private static func lines(_ count: Int) -> String { "\(count) \(count == 1 ? "line" : "lines")" }

    /// "A", "A and B", "A, B and C"; beyond three, the first two and a count. No label at all (an
    /// entry without `matched_remote`) is "the other side".
    private static func list(_ labels: [String]) -> String {
        switch labels.count {
        case 0: return "the other side"
        case 1: return labels[0]
        case 2, 3: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        default: return "\(labels[0]), \(labels[1]) and \(labels.count - 2) others"
        }
    }
}
