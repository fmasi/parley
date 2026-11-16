import Foundation

/// Re-detect keeps the speaker names already typed (#359), where the voice clearly matches.
///
/// A re-detect relabels a channel's lines; it never re-runs ASR (`TranscriptRediarizer`). So the
/// lines before and after are the same lines, and the speech an old label and a new one share says
/// which new speaker an old name belongs to. On a real 72-minute call re-detected from 3 to 2
/// remote speakers, over 99% of the first two speakers' speech kept its label and the third went
/// wholly into the first: dropping every name there (the behaviour before #359) cost the user all
/// their naming work for nothing.
///
/// The rule is deliberately strict, because a name on the wrong voice is the silent wrong answer
/// this product exists to avoid (the reason names were dropped at all, #202):
/// - a new speaker KEEPS a name when more than half of its speech carried that name before, more
///   than half of that name's speech went to it, AND no other new speaker took a quarter or more of
///   that name's speech. The first says the new speaker is mostly that person, the second that it is
///   where that person went, the third that the name was not split: raising the count usually means
///   one label was really two people, and the larger half of a 60/40 split is a guess. So one name
///   is kept on at most one new speaker, and one new speaker keeps at most one name;
/// - a name not kept anywhere is OFFERED as a suggestion — on each new speaker that took at least a
///   quarter of its speech, and always on the one that took the most — never filled in;
/// - the names typed on one person split in two ("Anna" on two rows) count as one person.
///
/// Only speech that is somebody's votes: a flagged line (echo, gate noise, a repeat, no usable time)
/// and a line under the channel's unattributed label are left out (`votingLines`). An echo cluster
/// is never a person on this side, so it is left out of the new speakers altogether, and a name typed
/// on an old echo row is never carried (`uncarriable`). The other channel is never touched.
///
/// The transcript itself still drops the channel's names at a re-detect (`clearingChannelNames`,
/// stashed under `speaker_names_previous`): the kept names go back into the dialog's fields, where
/// the person sees them and saves them, or not. The copy says so, and closing the dialog with kept
/// names unsaved asks first (`discardConfirmation`).
public enum SpeakerNameCarryOver {

    // MARK: - Speech shared between old and new labels

    /// One line of speech on the channel, under one label.
    public struct Line: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let label: String

        public init(start: Double, end: Double, label: String) {
            self.start = start
            self.end = end
            self.label = label
        }

        /// Its seconds; 0 for a line with no length or no finite time.
        var seconds: Double {
            guard start.isFinite, end.isFinite, end > start else { return 0 }
            return end - start
        }
    }

    /// The seconds of speech each old label shares with each new one, by time.
    ///
    /// By time, not by line: a speaker change can split a line in two (#120), and each part then
    /// counts with its own label.
    public struct Overlap: Equatable, Sendable {
        /// Old label → new label → the seconds of speech they share.
        public let seconds: [String: [String: Double]]
        /// Each old label's speech, in seconds: all of it, whether or not a new speaker took it.
        public let oldSpeech: [String: Double]
        /// Each new label's speech, in seconds.
        public let newSpeech: [String: Double]

        /// Nothing shared: a re-detect that reported no overlap.
        public static let none = Overlap(old: [], new: [])

        public init(old: [Line], new: [Line]) {
            func totals(_ lines: [Line]) -> [String: Double] {
                lines.reduce(into: [:]) { if $1.seconds > 0 { $0[$1.label, default: 0] += $1.seconds } }
            }
            oldSpeech = totals(old)
            newSpeech = totals(new)
            // Each old line meets only the new lines that can reach it: sorted by start, from the first
            // whose start is within the longest new line's length before it. O((n + m) log m) on lines
            // that do not overlap each other, as one channel's do not.
            let sorted = new.filter { $0.seconds > 0 }.sorted { $0.start < $1.start }
            let longest = sorted.map(\.seconds).max() ?? 0
            var shared: [String: [String: Double]] = [:]
            for line in old where line.seconds > 0 {
                let from = line.start - longest
                var low = 0, high = sorted.count
                while low < high {
                    let mid = (low + high) / 2
                    if sorted[mid].start < from { low = mid + 1 } else { high = mid }
                }
                var i = low
                while i < sorted.count, sorted[i].start < line.end {
                    let both = min(line.end, sorted[i].end) - max(line.start, sorted[i].start)
                    if both > 0 { shared[line.label, default: [:]][sorted[i].label, default: 0] += both }
                    i += 1
                }
            }
            seconds = shared
        }
    }

    /// The lines of one channel that vote: unflagged, with a usable time, under a label that is
    /// somebody's — not the channel's unattributed label, and not one in `excluding` (an echo
    /// cluster's).
    public static func votingLines(
        in segments: [[String: Any]], source: String, excluding: Set<String> = []
    ) -> [Line] {
        let notAPerson: Set<String> = [SpeakerAssignment.unattributedLabel(source: source), SpeakerAssignment.unknownSpeaker]
        return segments.compactMap { segment in
            guard segment["source"] as? String == source, !TranscriptAssembler.isFlagged(segment),
                  let label = segment["speaker"] as? String,
                  !notAPerson.contains(label), !excluding.contains(label),
                  let start = segment["start"] as? Double, let end = segment["end"] as? Double
            else { return nil }
            return Line(start: start, end: end, label: label)
        }
    }

    // MARK: - Which labels carry a name

    /// A label the pipeline or a re-detect wrote ("Remote Speaker 2", "Local Unknown", a bare
    /// "Unknown" or "Speaker 3"): not a name anybody gave.
    public static func isPipelineLabel(_ label: String) -> Bool {
        var rest = Substring(label)
        for side in ["Local ", "Remote "] where rest.hasPrefix(side) {
            rest = rest.dropFirst(side.count)
            break
        }
        if rest == Substring(SpeakerAssignment.unknownSpeaker) { return true }
        guard rest.hasPrefix("Speaker ") else { return false }
        let number = rest.dropFirst("Speaker ".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// The name each old label of a channel carries.
    ///
    /// - `fields`: the dialog's rows on the channel, label → what its name field holds now, saved or
    ///   not. A field that is empty, or holds a pipeline label, gives no name — even on a row whose
    ///   label is a name saved earlier: the person cleared it.
    /// - `oldLabels`: the channel's labels (`Overlap.oldSpeech`). One no row shows (too few lines
    ///   for a row) is a name when it is not a pipeline label: a rename wrote the name as the label.
    public static func names(fields: [String: String], oldLabels: some Sequence<String>) -> [String: String] {
        var names: [String: String] = [:]
        for (label, field) in fields {
            let typed = field.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, !isPipelineLabel(typed) { names[label] = typed }
        }
        for label in oldLabels where fields[label] == nil && !isPipelineLabel(label) {
            names[label] = label
        }
        return names
    }

    // MARK: - The plan

    /// Which name goes where after a re-detect.
    public struct Plan: Equatable, Sendable {
        /// New label → the name it keeps.
        public let kept: [String: String]
        /// New label → names offered on it, most shared speech first. Never filled in.
        public let suggestions: [String: [String]]
        /// The names kept on no new speaker, most speech first.
        public let notKept: [String]

        public static let none = Plan(kept: [:], suggestions: [:], notKept: [])

        public init(kept: [String: String], suggestions: [String: [String]], notKept: [String]) {
            self.kept = kept
            self.suggestions = suggestions
            self.notKept = notKept
        }

        /// The kept names, in the new labels' order.
        public var keptNames: [String] {
            kept.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.value)
        }
    }

    /// "Most" is more than this share, of the new speaker's speech and of the name's.
    static let most = 0.5
    /// A name not kept is offered on every new speaker that took at least this share of its speech;
    /// a name with a second speaker this large is not kept at all — it was split.
    static let offerShare = 0.25

    /// Where each name goes. See the type's comment for the rule.
    ///
    /// - `names`: old label → name (`names(fields:oldLabels:)`).
    /// - `uncarriable`: old labels whose name is never carried or offered — an echo voice's. Their
    ///   speech still counts, as nobody's.
    public static func plan(_ overlap: Overlap, names: [String: String], uncarriable: Set<String> = []) -> Plan {
        // One person per name: the labels a name was typed on, pooled.
        var labelsOf: [String: [String]] = [:]
        for (label, name) in names where !uncarriable.contains(label) { labelsOf[name, default: []].append(label) }
        var speech: [String: Double] = [:]                 // name → its speech
        var shared: [String: [String: Double]] = [:]       // name → new label → seconds
        for (name, labels) in labelsOf {
            for label in labels {
                speech[name, default: 0] += overlap.oldSpeech[label] ?? 0
                for (new, seconds) in overlap.seconds[label] ?? [:] { shared[name, default: [:]][new, default: 0] += seconds }
            }
        }

        var kept: [String: String] = [:]
        for (name, perNew) in shared {
            guard let total = speech[name], total > 0 else { continue }
            for (new, seconds) in perNew {
                guard let newTotal = overlap.newSpeech[new], newTotal > 0,
                      seconds / newTotal > most, seconds / total > most else { continue }
                // Not split: no other new speaker holds a quarter or more of this name.
                let split = perNew.contains { $0.key != new && $0.value >= offerShare * total }
                if !split { kept[new] = name }
            }
        }

        let keptNames = Set(kept.values)
        var offered: [String: [(name: String, seconds: Double)]] = [:]
        for (name, perNew) in shared where !keptNames.contains(name) {
            let total = speech[name] ?? 0
            let home = perNew.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
            for (new, seconds) in perNew where seconds > 0 && (new == home || seconds >= offerShare * total) {
                offered[new, default: []].append((name, seconds))
            }
        }
        let suggestions = offered.mapValues { list in
            list.sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }.map(\.name)
        }

        // Every name that is not kept, uncarriable ones included: the person typed it, and is told.
        let allNames = Set(names.values)
        let notKept = allNames.subtracting(keptNames)
            .sorted { (speech[$0] ?? 0, $1) > (speech[$1] ?? 0, $0) }
        return Plan(kept: kept, suggestions: suggestions, notKept: notKept)
    }

    /// `plan(_:names:uncarriable:)` from what the dialog holds: its name fields on the channel (row
    /// label → text, saved or not), the echo findings the transcript recorded before the re-detect,
    /// and the plan of an earlier re-detect of the same channel in this dialog, if any.
    ///
    /// - A row the echo check judged to be the other side's voice ON THIS CHANNEL
    ///   (`echo.voice(forRow:)`, which follows the renames `speaker_names` records, with its track the
    ///   re-detected `channel`) is not a person on this side: a name typed on it is never carried or
    ///   offered, only reported as not kept. The check judges only the mic side, so a remote speaker
    ///   that happens to share a local echo row's name is not one.
    /// - The earlier plan's suggestions that no field holds now were never claimed: they are reported
    ///   as not kept again, so a second re-detect does not drop them silently. (Their speech is under
    ///   labels that no longer exist, so they cannot be offered anywhere.)
    public static func plan(
        _ overlap: Overlap, fields: [String: String], echo: EchoNotice.Findings, channel: String, previous: Plan? = nil
    ) -> Plan {
        let names = names(fields: fields, oldLabels: overlap.oldSpeech.keys)
        let echoRows = Set(names.keys.filter { echo.voice(forRow: $0)?.track == channel })
        let plan = plan(overlap, names: names, uncarriable: echoRows)
        guard let previous else { return plan }
        let inFields = Set(names.values)
        let reported = Set(plan.notKept).union(plan.kept.values)
        let unclaimed = Set(previous.suggestions.values.flatMap { $0 })
            .subtracting(inFields).subtracting(reported).sorted()
        return Plan(kept: plan.kept, suggestions: plan.suggestions, notKept: plan.notKept + unclaimed)
    }

    /// What a Cancel or a close would lose: the names the fields hold on every channel a re-detect
    /// rewrote in this dialog (one with a plan). That re-detect took the channel's names out of the
    /// transcript, so whatever its fields hold — kept, taken from a suggestion, edited or typed — is
    /// only there until Save. By channel, then by row label.
    ///
    /// - Parameter fields: channel → row label → what its name field holds.
    public static func unsavedNames(fields: [String: [String: String]], plans: [String: Plan]) -> [String] {
        var unsaved: [String] = []
        for channel in plans.keys.sorted() {
            let named = names(fields: fields[channel] ?? [:], oldLabels: [])
            for label in named.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if let name = named[label], !unsaved.contains(name) { unsaved.append(name) }
            }
        }
        return unsaved
    }

    /// The dialog's name fields after a re-detect, by row label.
    ///
    /// On the re-detected channel a row's field holds the name it kept, else its label (as a fresh
    /// row does). On the other channel the field holds what it held before — typed and unsaved
    /// included — else its label: a re-detect never touches the other channel's names.
    public static func fields(
        rows: [(id: String, channel: String?)], previous: [String: String], redetected: String, plan: Plan
    ) -> [String: String] {
        var fields: [String: String] = [:]
        for row in rows {
            if row.channel == redetected {
                fields[row.id] = plan.kept[row.id] ?? row.id
            } else {
                fields[row.id] = previous[row.id] ?? row.id
            }
        }
        return fields
    }

    // MARK: - Copy

    /// The confirmation before a re-detect on a channel that has names. What happens to each name is
    /// only known once the voices are worked out again, so it says the rule, and the dialog says the
    /// result on each speaker after.
    public static func confirmation(channel: String, names: [String]) -> (title: String, message: String) {
        let side = channel == "local" ? "this side" : "the other side"
        let other = channel == "local" ? "the other side" : "this side"
        let named = names.isEmpty ? "" : "Names on \(side) now: \(list(names)). "
        return (
            "Re-detect the speakers on \(side)?",
            named
                + "A name stays on a new speaker only when most of that speaker's lines had the name, most of "
                + "the name's lines went to that speaker, and no other speaker took a large share of them. Any other name is left off and shown as a "
                + "suggestion, never filled in — a name on the wrong voice would put it on the wrong words. "
                + "The re-detect removes these names from the transcript; the ones kept come back in the fields. "
                + "Check them, then Save to write them to the transcript. Names on \(other) are unaffected."
        )
    }

    /// Under the channel's re-detect row, after it ran: which names were kept and which were not.
    /// nil when the channel had no names.
    public static func outcome(_ plan: Plan) -> String? {
        var sentences: [String] = []
        let kept = plan.keptNames
        if !kept.isEmpty { sentences.append("Names kept: \(list(kept)).") }
        let offered = Set(plan.suggestions.values.flatMap { $0 })
        let suggested = plan.notKept.filter(offered.contains)
        let lost = plan.notKept.filter { !offered.contains($0) }
        if !suggested.isEmpty {
            sentences.append("Not kept, shown as \(suggested.count == 1 ? "a suggestion" : "suggestions"): \(list(suggested)).")
        }
        if !lost.isEmpty {
            sentences.append("Not kept or suggested: \(list(lost)).")
        }
        // The transcript lost the channel's names at the re-detect: they are only in the fields now.
        if !kept.isEmpty { sentences.append("Save to write them to the transcript.") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The note on a speaker card whose name was kept, while its field (trimmed) still holds that
    /// name; nil otherwise — once the person changes the name, the note no longer describes it.
    public static func cardNote(forRow row: String, field: String, plan: Plan) -> String? {
        guard let name = plan.kept[row], field.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return nil }
        return "Kept “\(name)” from before the re-detect: most of these lines had that name. Play a sample to check."
    }

    /// Asked before Cancel, Escape or closing the window throws away kept names not yet saved.
    public static func discardConfirmation(names: [String]) -> (title: String, message: String, discard: String, keep: String) {
        (
            "Close without saving the names?",
            "\(list(names)) \(names.count == 1 ? "is" : "are") only in the fields since the re-detect — "
                + "not in the transcript. Closing now leaves \(names.count == 1 ? "that speaker" : "those speakers") "
                + "unnamed in the transcript.",
            "Close Without Saving",
            "Keep Editing"
        )
    }

    /// "A", "A and B", "A, B and C".
    private static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
