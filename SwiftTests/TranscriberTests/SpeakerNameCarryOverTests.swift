import Testing
import Foundation
@testable import TranscriberCore

/// Re-detect keeps the names already typed (#359): which new speaker each old name goes to, by the
/// seconds of speech the two share. Synthetic labels, names and times only.
@Suite struct SpeakerNameCarryOverTests {

    typealias Line = SpeakerNameCarryOver.Line

    private func line(_ start: Double, _ end: Double, _ label: String) -> Line {
        Line(start: start, end: end, label: label)
    }

    /// The same lines under the old and the new labels: a re-detect relabels, it never moves a line.
    private func relabel(_ old: [Line], _ newLabel: (Line) -> String) -> [Line] {
        old.map { line($0.start, $0.end, newLabel($0)) }
    }

    /// `count` lines of 2 s, one every 10 s, in time slot `slot` (0, 1 or 2) of each 10 s: lines of
    /// different slots never overlap, as one channel's lines do not.
    private func lines(_ label: String, count: Int, offset slot: Double) -> [Line] {
        (0..<count).map { line(slot * 3 + Double($0) * 10, slot * 3 + Double($0) * 10 + 2, label) }
    }

    // MARK: - Overlap

    @Test("the same lines under new labels: each pair shares the lines' seconds")
    func sameLinesShareTheirSeconds() {
        let old = [line(0, 4, "A"), line(10, 13, "B"), line(20, 25, "A")]
        let overlap = SpeakerNameCarryOver.Overlap(old: old, new: relabel(old) { $0.label == "A" ? "X" : "Y" })
        #expect(overlap.seconds == ["A": ["X": 9], "B": ["Y": 3]])
        #expect(overlap.oldSpeech == ["A": 9, "B": 3])
        #expect(overlap.newSpeech == ["X": 9, "Y": 3])
    }

    @Test("a line split by a new speaker change shares each part with its own label")
    func aSplitLineSharesByTime() {
        let overlap = SpeakerNameCarryOver.Overlap(old: [line(0, 10, "A")], new: [line(0, 4, "X"), line(4, 10, "Y")])
        #expect(overlap.seconds == ["A": ["X": 4, "Y": 6]])
    }

    @Test("lines with no length or no finite time count for nothing")
    func degenerateLinesCountForNothing() {
        let old = [line(5, 5, "A"), line(6, 4, "A"), line(.nan, 3, "A"), line(0, .infinity, "A"), line(10, 12, "A")]
        let overlap = SpeakerNameCarryOver.Overlap(old: old, new: [line(0, 100, "X")])
        #expect(overlap.seconds == ["A": ["X": 2]])
        #expect(overlap.oldSpeech == ["A": 2])
    }

    @Test("a long new line still meets every old line it covers")
    func aLongNewLineMeetsEveryOldLine() {
        let old = lines("A", count: 5, offset: 0)
        let overlap = SpeakerNameCarryOver.Overlap(old: old, new: [line(0, 50, "X"), line(1, 2, "Y")])
        #expect(overlap.seconds["A"]?["X"] == 10)
        #expect(overlap.seconds["A"]?["Y"] == 1)
    }

    // MARK: - Voting lines

    @Test("only the channel's unflagged, timed, attributed lines vote")
    func votingLinesLeaveOutWhatIsNotAPerson() {
        func seg(_ start: Double, _ speaker: String, _ source: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["start": start, "end": start + 1, "speaker": speaker, "source": source, "text": "w"].merging(extra) { _, new in new }
        }
        let segments: [[String: Any]] = [
            seg(0, "Anna", "remote"),
            seg(1, "Local Speaker 1", "local"),
            seg(2, "Remote Speaker 2", "remote", ["echo": true]),
            seg(3, "Remote Speaker 2", "remote", ["filtered": true]),
            seg(4, "Remote Speaker 2", "remote", ["duplicate": true]),
            seg(5, "Remote Speaker 2", "remote", ["time_unknown": true]),
            seg(6, "Remote Unknown", "remote"),
            seg(7, "Unknown", "remote"),
            seg(8, "Remote Speaker 3", "remote"),
            seg(9, "Remote Speaker 2", "remote"),
        ]
        let voting = SpeakerNameCarryOver.votingLines(in: segments, source: "remote", excluding: ["Remote Speaker 3"])
        #expect(voting == [line(0, 1, "Anna"), line(9, 10, "Remote Speaker 2")])
    }

    // MARK: - Which labels carry a name

    @Test("a pipeline label is not a name; anything else is")
    func pipelineLabels() {
        for label in ["Local Speaker 1", "Remote Speaker 12", "Local Unknown", "Remote Unknown", "Unknown", "Speaker 3"] {
            #expect(SpeakerNameCarryOver.isPipelineLabel(label), "\(label)")
        }
        for name in ["Anna", "Remote Speaker", "Speaker Anna", "Remote Speaker 1 (Anna)", "Local speaker 1"] {
            #expect(!SpeakerNameCarryOver.isPipelineLabel(name), "\(name)")
        }
    }

    @Test("names come from the fields as typed, saved names included, and from labels no row shows")
    func namesFromFieldsAndLabels() {
        let names = SpeakerNameCarryOver.names(
            fields: [
                "Remote Speaker 1": "  Anna ",        // typed, not saved yet
                "Bob": "Bob",                          // saved earlier: the label is the name
                "Carl": "",                            // a saved name the user cleared
                "Remote Speaker 4": "Remote Speaker 4",  // untouched
                "Remote Speaker 5": "Remote Speaker 2",  // a pipeline label typed in: not a name
                "Remote Speaker 6": "   ",
            ],
            oldLabels: ["Remote Speaker 1", "Bob", "Carl", "Dana", "Remote Speaker 7"])
        #expect(names == ["Remote Speaker 1": "Anna", "Bob": "Bob", "Dana": "Dana"])
    }

    // MARK: - The plan

    /// The issue's real call, in miniature: 3 → 2 remote speakers. Remote Speaker 1 and 2 keep their
    /// lines; Remote Speaker 3 (unnamed) goes wholly into the first.
    @Test("3 → 2: each named speaker that kept its lines keeps its name")
    func threeToTwoKeepsBothNames() {
        let old = lines("Anna", count: 10, offset: 0) + lines("Bob", count: 8, offset: 1) + lines("Remote Speaker 3", count: 3, offset: 2)
        let new = relabel(old) { $0.label == "Bob" ? "Remote Speaker 2" : "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna", "Bob": "Bob"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"])
        #expect(plan.suggestions.isEmpty)
        #expect(plan.notKept.isEmpty)
    }

    @Test("a few lines moving does not stop a name: most of both sides is enough")
    func mostIsEnough() {
        // 9 of Anna's 10 lines stay together; one goes to Bob's new speaker.
        let old = lines("Anna", count: 10, offset: 0) + lines("Bob", count: 10, offset: 1)
        let new = relabel(old) { $0.label == "Bob" || $0.start == 90 ? "Remote Speaker 2" : "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna", "Bob": "Bob"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"])
    }

    @Test("two names merged into one speaker: the one with more speech is kept, the other offered")
    func twoNamesMergedKeepTheLarger() {
        let old = lines("Remote Speaker 1", count: 7, offset: 0) + lines("Remote Speaker 2", count: 3, offset: 1)
        let new = relabel(old) { _ in "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            names: ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Anna (2)"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna"])
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna (2)"]])
        #expect(plan.notKept == ["Anna (2)"])
    }

    @Test("one name typed on two speakers counts as one person")
    func oneNameOnTwoLabelsIsOnePerson() {
        let old = lines("Remote Speaker 1", count: 4, offset: 0) + lines("Remote Speaker 2", count: 5, offset: 1)
            + lines("Remote Speaker 3", count: 4, offset: 2)
        // Anna was split as Speaker 1 and 3; they come back together, with Bob apart.
        let new = relabel(old) { $0.label == "Remote Speaker 2" ? "Remote Speaker 2" : "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            names: ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob", "Remote Speaker 3": "Anna"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"])
        #expect(plan.notKept.isEmpty)
    }

    @Test("a name split evenly between two new speakers is kept on neither, and offered on both")
    func anEvenSplitIsOfferedNotKept() {
        let old = lines("Bob", count: 10, offset: 0)
        let new = relabel(old) { $0.start < 50 ? "Remote Speaker 1" : "Remote Speaker 2" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Bob": "Bob"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Bob"], "Remote Speaker 2": ["Bob"]])
        #expect(plan.notKept == ["Bob"])
    }

    @Test("a new speaker that is mostly someone unnamed does not take a name; the name is offered")
    func mostlyUnnamedIsOffered() {
        let old = lines("Anna", count: 3, offset: 0) + lines("Remote Speaker 2", count: 7, offset: 1)
        let new = relabel(old) { _ in "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna"]])
        #expect(plan.notKept == ["Anna"])
    }

    @Test("a new speaker that is mostly one name but holds only part of it does not take it")
    func holdingLessThanHalfOfANameIsNotEnough() {
        // Anna's 10 lines go 4 / 3 / 3 to three new speakers; the first holds nothing else.
        let old = lines("Anna", count: 10, offset: 0)
        let new = relabel(old) { $0.start < 40 ? "Remote Speaker 1" : $0.start < 70 ? "Remote Speaker 2" : "Remote Speaker 3" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna"], "Remote Speaker 2": ["Anna"], "Remote Speaker 3": ["Anna"]])
    }

    @Test("an exact half is not most")
    func exactlyHalfIsNotMost() {
        let old = lines("Anna", count: 2, offset: 0) + lines("Remote Speaker 2", count: 2, offset: 1)
        let new = relabel(old) { _ in "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna"]])
    }

    @Test("a name on an echo voice is never carried or offered")
    func anEchoVoicesNameIsNotCarried() {
        let old = lines("Fred", count: 6, offset: 0) + lines("Local Speaker 2", count: 6, offset: 1)
        let new = relabel(old) { $0.label == "Fred" ? "Local Speaker 1" : "Local Speaker 2" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            names: ["Fred": "Fred", "Local Speaker 2": "Bob"], uncarriable: ["Local Speaker 2"])
        #expect(plan.kept == ["Local Speaker 1": "Fred"])
        #expect(plan.suggestions.isEmpty)
        #expect(plan.notKept == ["Bob"])
    }

    @Test("a speaker kept out of the new speakers (an echo voice) receives no name")
    func aNewEchoVoiceGetsNothing() {
        // The new echo cluster's lines are not among the new voting lines: the overlap never sees them.
        let old = lines("Fred", count: 6, offset: 0)
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: []), names: ["Fred": "Fred"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions.isEmpty)
        #expect(plan.notKept == ["Fred"])
    }

    @Test("a name with no speech that votes (the Unknown row) is reported, never placed")
    func aNameWithoutSpeechIsReported() {
        let old = lines("Anna", count: 3, offset: 0)
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: relabel(old) { _ in "Remote Speaker 1" }),
            names: ["Anna": "Anna", "Remote Unknown": "Crowd"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna"])
        #expect(plan.notKept == ["Crowd"])
    }

    @Test("not kept: the name with the most speech first")
    func notKeptOrder() {
        let old = lines("Remote Speaker 1", count: 8, offset: 0) + lines("Remote Speaker 2", count: 2, offset: 1)
            + lines("Remote Speaker 3", count: 4, offset: 2)
        let new = relabel(old) { _ in "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            names: ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob", "Remote Speaker 3": "Carl"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna"])
        #expect(plan.notKept == ["Carl", "Bob"])
        #expect(plan.suggestions == ["Remote Speaker 1": ["Carl", "Bob"]])
    }

    // MARK: - Kept only when the name is not also elsewhere (review)

    /// Raising the count usually means one label was really two people: the larger half of a name
    /// that split 60/40 is a guess, not a match.
    @Test("a 60/40 split of one name: kept on neither, offered on both")
    func aSixtyFortySplitIsOffered() {
        let old = lines("Anna", count: 10, offset: 0)
        let new = relabel(old) { $0.start < 60 ? "Remote Speaker 1" : "Remote Speaker 2" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna"], "Remote Speaker 2": ["Anna"]])
        #expect(plan.notKept == ["Anna"])
    }

    @Test("a 55/45 cross-mix on 2 → 2: neither name is kept")
    func aCrossMixKeepsNeither() {
        // Anna's lines go 55/45 to Speaker 1/2, Bob's 45/55: each new speaker is mostly one name, and
        // each name is mostly on one speaker, but both are split.
        let old = lines("Anna", count: 20, offset: 0) + lines("Bob", count: 20, offset: 1)
        let new = relabel(old) { line in
            let i = Int((line.start - (line.label == "Anna" ? 0 : 3)) / 10)
            return (line.label == "Anna") == (i < 11) ? "Remote Speaker 1" : "Remote Speaker 2"
        }
        let overlap = SpeakerNameCarryOver.Overlap(old: old, new: new)
        #expect(overlap.seconds["Anna"] == ["Remote Speaker 1": 22, "Remote Speaker 2": 18])
        #expect(overlap.seconds["Bob"] == ["Remote Speaker 1": 18, "Remote Speaker 2": 22])
        let plan = SpeakerNameCarryOver.plan(overlap, names: ["Anna": "Anna", "Bob": "Bob"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna", "Bob"], "Remote Speaker 2": ["Bob", "Anna"]])
        #expect(Set(plan.notKept) == ["Anna", "Bob"])
    }

    @Test("a 90/10 split: the name is kept on the 90")
    func aNinetyTenSplitIsKept() {
        let old = lines("Anna", count: 10, offset: 0)
        let new = relabel(old) { $0.start < 90 ? "Remote Speaker 1" : "Remote Speaker 2" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept == ["Remote Speaker 1": "Anna"])
        #expect(plan.suggestions.isEmpty)
        #expect(plan.notKept.isEmpty)
    }

    @Test("80/20, not kept: offered on the 80, not on the 20")
    func aTwentyShareIsNotOffered() {
        // 80% of Anna's speech went to Speaker 1, but Speaker 1 is mostly someone unnamed.
        let old = lines("Anna", count: 10, offset: 0) + lines("Remote Speaker 9", count: 20, offset: 1)
        let new = relabel(old) { $0.label == "Anna" && $0.start >= 80 ? "Remote Speaker 2" : "Remote Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Remote Speaker 1": ["Anna"]])
        #expect(plan.notKept == ["Anna"])
    }

    @Test("most of a name's speech went to an echo cluster: under a quarter left, still offered where it went")
    func aNameMostlyInAnEchoClusterIsStillOffered() {
        // 8 of Anna's 10 lines are now an echo cluster's, left out of the new speakers; 2 are Speaker 1's.
        let old = lines("Anna", count: 10, offset: 0)
        let new = relabel(old.filter { $0.start < 20 }) { _ in "Local Speaker 1" }
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: new), names: ["Anna": "Anna"])
        #expect(plan.kept.isEmpty)
        #expect(plan.suggestions == ["Local Speaker 1": ["Anna"]])
        #expect(plan.notKept == ["Anna"])
    }

    // MARK: - Echo rows, from the transcript's own metadata (review)

    /// `echo_clusters` and `speaker_names` as a transcript holds them: the pipeline judged "Local
    /// Speaker 2" echo, and the user renamed that row "Bob" (so its lines carry "Bob").
    private let echoMetadata: [String: Any] = [
        "echo_clusters": [
            ["track": "local", "chunk": 0, "label": "Local Speaker 1", "segments": 10, "matched_segments": 0,
             "seconds": 20.0, "matched_seconds": 0.0, "share": 0.0, "verdict": "kept", "matched_remote": [String: Double]()],
            ["track": "local", "chunk": 0, "label": "Local Speaker 2", "segments": 10, "matched_segments": 9,
             "seconds": 20.0, "matched_seconds": 18.0, "share": 0.9, "verdict": "echo",
             "matched_remote": ["Remote Speaker 1": 18.0]],
        ] as [Any],
        "speaker_names": ["Local Speaker 1": "Fred", "Local Speaker 2": "Bob"],
    ]

    @Test("a name on a renamed echo row is never carried: decided from the transcript's echo findings")
    func aRenamedEchoRowsNameIsNotCarried() {
        let old = lines("Fred", count: 10, offset: 0) + lines("Bob", count: 10, offset: 1)
        let new = relabel(old) { $0.label == "Fred" ? "Local Speaker 1" : "Local Speaker 2" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            fields: ["Fred": "Fred", "Bob": "Bob"], echo: EchoNotice.Findings(metadata: echoMetadata))
        #expect(plan.kept == ["Local Speaker 1": "Fred"])
        #expect(plan.suggestions.isEmpty)
        #expect(plan.notKept == ["Bob"])
    }

    @Test("the echo row under its original label, never renamed: its typed name is not carried either")
    func anUnrenamedEchoRowsTypedNameIsNotCarried() {
        let old = lines("Local Speaker 1", count: 10, offset: 0) + lines("Local Speaker 2", count: 10, offset: 1)
        let new = relabel(old) { $0.label }
        var metadata = echoMetadata
        metadata["speaker_names"] = nil
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            fields: ["Local Speaker 1": "Fred", "Local Speaker 2": "Bob"], echo: EchoNotice.Findings(metadata: metadata))
        #expect(plan.kept == ["Local Speaker 1": "Fred"])
        #expect(plan.notKept == ["Bob"])
    }

    @Test("without echo findings the same names are carried as usual")
    func noEchoFindingsCarryAsUsual() {
        let old = lines("Fred", count: 10, offset: 0) + lines("Bob", count: 10, offset: 1)
        let new = relabel(old) { $0.label == "Fred" ? "Local Speaker 1" : "Local Speaker 2" }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new), fields: ["Fred": "Fred", "Bob": "Bob"], echo: .none)
        #expect(plan.kept == ["Local Speaker 1": "Fred", "Local Speaker 2": "Bob"])
    }

    // MARK: - A second re-detect (review)

    @Test("a second re-detect reports the first one's suggestions nobody took as not kept")
    func unclaimedSuggestionsSurviveASecondRedetect() {
        let first = SpeakerNameCarryOver.Plan(
            kept: ["Remote Speaker 1": "Anna"], suggestions: ["Remote Speaker 1": ["Anna (2)"], "Remote Speaker 2": ["Bob"]],
            notKept: ["Anna (2)", "Bob"])
        // The user took the Bob suggestion; "Anna (2)" is in no field.
        let old = lines("Remote Speaker 1", count: 6, offset: 0) + lines("Remote Speaker 2", count: 4, offset: 1)
        let new = relabel(old) { $0.label }
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: new),
            fields: ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"], echo: .none, previous: first)
        #expect(plan.kept == ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"])
        #expect(plan.notKept == ["Anna (2)"])
    }

    @Test("an unclaimed suggestion is not reported twice, nor when the new plan keeps it")
    func unclaimedSuggestionsAreNotDuplicated() {
        let first = SpeakerNameCarryOver.Plan(kept: [:], suggestions: ["Remote Speaker 1": ["Anna", "Carl"]], notKept: ["Anna", "Carl"])
        let old = lines("Remote Speaker 1", count: 6, offset: 0)
        let plan = SpeakerNameCarryOver.plan(
            SpeakerNameCarryOver.Overlap(old: old, new: old), fields: ["Remote Speaker 1": "Carl"], echo: .none, previous: first)
        #expect(plan.kept == ["Remote Speaker 1": "Carl"])
        #expect(plan.notKept == ["Anna"])
    }

    @Test("no names, nothing planned")
    func noNamesNoPlan() {
        let old = lines("Remote Speaker 1", count: 3, offset: 0)
        let plan = SpeakerNameCarryOver.plan(SpeakerNameCarryOver.Overlap(old: old, new: old), names: [:])
        #expect(plan == .none)
    }

    // MARK: - The dialog's fields after a re-detect

    @Test("after a re-detect: this channel's fields take the kept names, the other channel keeps what was typed")
    func fieldsAfterRedetect() {
        let plan = SpeakerNameCarryOver.Plan(kept: ["Remote Speaker 1": "Anna"], suggestions: ["Remote Speaker 2": ["Bob"]], notKept: ["Bob"])
        let fields = SpeakerNameCarryOver.fields(
            rows: [("Local Speaker 1", "local"), ("Remote Speaker 1", "remote"), ("Remote Speaker 2", "remote"),
                   ("Local Speaker 2", "local")],
            previous: ["Local Speaker 1": "Fred (unsaved)", "Remote Speaker 1": "Old typed text", "Remote Speaker 2": "Bob"],
            redetected: "remote", plan: plan)
        #expect(fields == ["Local Speaker 1": "Fred (unsaved)", "Remote Speaker 1": "Anna",
                           "Remote Speaker 2": "Remote Speaker 2", "Local Speaker 2": "Local Speaker 2"])
    }

    /// A row id on both channels: a name saved on a speaker of each side. The rows are one per label
    /// (`TranscriptRenamer.collectSpeakerSamples` groups by the label alone), so the dialog's
    /// "previous" field for that id is the one field it had.
    @Test("a label on both channels is one row, so its previous field is unambiguous")
    func aLabelOnBothChannelsIsOneRow() {
        let json: [String: Any] = ["segments": [
            ["start": 0.0, "end": 2.0, "speaker": "Fred", "source": "local", "text": "hello there"],
            ["start": 3.0, "end": 5.0, "speaker": "Fred", "source": "remote", "text": "hi back"],
            ["start": 6.0, "end": 8.0, "speaker": "Remote Speaker 2", "source": "remote", "text": "and me"],
        ]]
        let rows = TranscriptRenamer.collectSpeakerSamples(json: json, maxSamplesPerSpeaker: 3)
        #expect(rows.map(\.id) == ["Fred", "Remote Speaker 2"])
        // Re-detecting the remote side leaves "Fred" only on this side's lines: its field is the one typed.
        let fields = SpeakerNameCarryOver.fields(
            rows: [("Fred", "local"), ("Remote Speaker 1", "remote")], previous: ["Fred": "Fred M", "Remote Speaker 2": "Zed"],
            redetected: "remote", plan: .none)
        #expect(fields == ["Fred": "Fred M", "Remote Speaker 1": "Remote Speaker 1"])
    }

    // MARK: - Copy

    @Test("the confirmation names the side, the names at stake, and what happens to each")
    func confirmationCopy() {
        let remote = SpeakerNameCarryOver.confirmation(channel: "remote", names: ["Anna", "Bob"])
        #expect(remote.title.contains("the other side"))
        #expect(remote.message.contains("Anna and Bob"))
        #expect(remote.message.contains("suggestion"))
        #expect(remote.message.contains("Names on this side are unaffected"))
        let local = SpeakerNameCarryOver.confirmation(channel: "local", names: ["Fred"])
        #expect(local.title.contains("this side"))
        #expect(local.message.contains("Names on the other side are unaffected"))
        // The transcript loses the side's names at the re-detect, and gets them back on Save.
        #expect(remote.message.contains("Save to write them to the transcript"))
    }

    @Test("the outcome line says which names were kept and which were only offered")
    func outcomeCopy() throws {
        #expect(SpeakerNameCarryOver.outcome(.none) == nil)
        let plan = SpeakerNameCarryOver.Plan(
            kept: ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"],
            suggestions: ["Remote Speaker 1": ["Carl"]], notKept: ["Carl", "Dana"])
        let text = try #require(SpeakerNameCarryOver.outcome(plan))
        #expect(text.contains("Names kept: Anna and Bob"))
        #expect(text.contains("Carl"))
        #expect(text.contains("Dana"))
        #expect(text.contains("suggest"))
        #expect(text.hasSuffix("Save to write them to the transcript."))
        // Nothing kept, nothing to save.
        let none = SpeakerNameCarryOver.Plan(kept: [:], suggestions: [:], notKept: ["Dana"])
        #expect(SpeakerNameCarryOver.outcome(none)?.contains("Save") == false)
    }

    @Test("closing with kept names not saved asks first, naming them")
    func discardCopy() {
        let plan = SpeakerNameCarryOver.Plan(kept: ["Remote Speaker 1": "Anna", "Remote Speaker 2": "Bob"], suggestions: [:], notKept: [])
        #expect(SpeakerNameCarryOver.unsavedKeptNames(in: ["remote": plan, "local": .none]) == ["Anna", "Bob"])
        #expect(SpeakerNameCarryOver.unsavedKeptNames(in: ["local": .none]).isEmpty)
        let copy = SpeakerNameCarryOver.discardConfirmation(names: ["Anna", "Bob"])
        #expect(copy.title == "Close without saving the names?")
        #expect(copy.message.contains("Anna and Bob"))
        #expect(copy.message.contains("not in the transcript"))
        #expect(copy.discard == "Close Without Saving")
        #expect(copy.keep == "Keep Editing")
    }

    @Test("a card says when its name was kept from before the re-detect")
    func cardCopy() {
        let plan = SpeakerNameCarryOver.Plan(kept: ["Remote Speaker 1": "Anna"], suggestions: ["Remote Speaker 2": ["Bob"]], notKept: ["Bob"])
        #expect(SpeakerNameCarryOver.cardNote(forRow: "Remote Speaker 1", field: "Anna", plan: plan)?.contains("Anna") == true)
        #expect(SpeakerNameCarryOver.cardNote(forRow: "Remote Speaker 1", field: "  Anna ", plan: plan) != nil)
        #expect(SpeakerNameCarryOver.cardNote(forRow: "Remote Speaker 2", field: "Bob", plan: plan) == nil)
        #expect(SpeakerNameCarryOver.cardNote(forRow: "Remote Speaker 3", field: "x", plan: .none) == nil)
    }

    @Test("the kept note goes once the field no longer holds the kept name")
    func cardNoteFollowsTheField() {
        let plan = SpeakerNameCarryOver.Plan(kept: ["Remote Speaker 1": "Anna"], suggestions: [:], notKept: [])
        #expect(SpeakerNameCarryOver.cardNote(forRow: "Remote Speaker 1", field: "Anna B", plan: plan) == nil)
        #expect(SpeakerNameCarryOver.cardNote(forRow: "Remote Speaker 1", field: "", plan: plan) == nil)
    }
}
