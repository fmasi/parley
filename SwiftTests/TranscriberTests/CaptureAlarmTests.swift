import Foundation
import Testing
@testable import TranscriberCore

/// H3/H9/L5 (§6): alarms are state, per track, sticky until the condition clears, re-notified
/// periodically. Incident A's watchdog fired once and stayed silent for 51 minutes.
@Suite struct CaptureAlarmTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    /// Helper registry ids, oldest first: "<process start ms>-<registry resets>" (F2 fix round 2).
    let h1 = "1000-0", h2 = "1000-1", h3 = "2000-0"

    /// Each snapshot a helper builds carries the next sequence number.
    private final class SequenceCounter { var value: UInt64 = 0; func next() -> UInt64 { value += 1; return value } }
    private let sequence = SequenceCounter()

    private func snapshot(_ id: String, _ alarms: [ActiveAlarm], sequence seq: UInt64? = nil) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, sequence: seq ?? sequence.next(), isCapturing: true, alarms: alarms, tracks: [])
    }
    private func alarm(_ kind: AlarmKind, at: Date, episode: Int = 1) -> ActiveAlarm {
        ActiveAlarm(kind: kind, raisedAt: at, lastNotifiedAt: nil, message: kind.rawValue, episode: episode)
    }

    @Test func raiseIsIdempotentAndKeepsTheOriginalTimestamp() {
        var r = CaptureAlarmRegistry()
        #expect(r.raise(.remoteNotDelivering, message: "m", now: t0) == true)
        #expect(r.raise(.remoteNotDelivering, message: "m2", now: t0 + 10) == false)
        #expect(r.alarms[.remoteNotDelivering]?.raisedAt == t0)
        #expect(r.alarms[.remoteNotDelivering]?.message == "m")
    }

    @Test func clearReturnsTheAlarmAndEmptiesTheSlot() {
        var r = CaptureAlarmRegistry()
        r.raise(.micDigitalSilence, message: "m", now: t0)
        #expect(r.clear(.micDigitalSilence)?.kind == .micDigitalSilence)
        #expect(r.clear(.micDigitalSilence) == nil)
        #expect(r.isEmpty)
    }

    @Test func episodeCountsRaises() {
        var r = CaptureAlarmRegistry()
        r.raise(.micNotDelivering, message: "m", now: t0); _ = r.clear(.micNotDelivering)
        r.raise(.micNotDelivering, message: "m", now: t0 + 1)
        #expect(r.alarms[.micNotDelivering]?.episode == 2)
    }

    /// App side: helper-owned kinds follow the same helper's snapshot; app-owned ones are untouched.
    @Test func sameHelperSnapshotReplacesHelperOwnedAlarmsOnly() {
        var r = CaptureAlarmRegistry()
        r.raise(.crashProtectionOff, message: "c", now: t0)
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot(h1, [alarm(.micDigitalSilence, at: t0 + 5)]))
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .micDigitalSilence])
        #expect(r.staleKinds.isEmpty)
    }

    /// The helper never owns an app-owned kind: one inside its snapshot is neither adopted nor able to
    /// clear the app's own alarm of that kind.
    @Test func anAppOwnedKindInsideASnapshotIsIgnored() {
        var r = CaptureAlarmRegistry()
        r.raise(.diskLow, message: "app", now: t0)
        r.apply(snapshot(h1, [alarm(.crashProtectionOff, at: t0), alarm(.diskLow, at: t0 + 9)]))
        #expect(Set(r.alarms.keys) == [.diskLow])
        #expect(r.alarms[.diskLow]?.message == "app")
        r.apply(snapshot(h1, []))
        #expect(Set(r.alarms.keys) == [.diskLow], "the helper's snapshot never clears an app-owned alarm")
    }

    /// Spec §6.3 (scan C7): the 5 s poll must not reset the 2-minute notify clock.
    @Test func pollingDoesNotResetTheNotifyClock() {
        var r = CaptureAlarmRegistry()
        let fromHelper = alarm(.remoteNotDelivering, at: t0)
        r.apply(snapshot(h1, [fromHelper]))
        r.markNotified(.remoteNotDelivering, now: t0 + 1)
        r.apply(snapshot(h1, [fromHelper]))   // the next poll, same episode
        #expect(r.alarms[.remoteNotDelivering]?.lastNotifiedAt == t0 + 1)
        #expect(AlarmRealarmPolicy.shouldRenotify(r.alarms[.remoteNotDelivering]!, now: t0 + 6) == false)
    }

    /// F2 fix round 1 (was `aNewEpisodeOfTheSameKindNotifiesAgain`): a flapping condition must not
    /// re-notify with sound on every new episode. The row updates at once; the notification waits
    /// for the per-kind floor.
    @Test func aNewEpisodeOfTheSameKindNotifiesAgainOnlyAfterTheFloor() throws {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0, episode: 1)]))
        r.markNotified(.remoteNotDelivering, now: t0 + 1)
        r.apply(snapshot(h1, []))   // the condition cleared…
        #expect(r.alarms[.remoteNotDelivering] == nil)
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0 + 30, episode: 2)]))   // …and came back
        let a = try #require(r.alarms[.remoteNotDelivering])
        #expect(a.raisedAt == t0 + 30, "the row reflects the new episode at once")
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 30) == false, "within the floor: no sound")
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 1 + AlarmRealarmPolicy.notifyInterval), "after the floor: notify")
    }

    @Test func theNotifyFloorSurvivesAClearOfAnAppOwnedKind() throws {
        var r = CaptureAlarmRegistry()
        r.raise(.diskLow, message: "d", now: t0)
        r.markNotified(.diskLow, now: t0)
        _ = r.clear(.diskLow)
        r.raise(.diskLow, message: "d", now: t0 + 10)
        let a = try #require(r.alarms[.diskLow])
        #expect(a.episode == 2)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 10) == false)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + AlarmRealarmPolicy.notifyInterval))
    }

    @Test func aKindThatNeverNotifiedNotifiesAtOnce() throws {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.micNotDelivering, at: t0)]))
        let a = try #require(r.alarms[.micNotDelivering])
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0))
    }

    /// Spec §6.2 (scan C6): a restarted helper starts empty; the app keeps the old set until the
    /// new helper's evidence on that track proves the condition gone. F2 fix round 1: a content
    /// alarm (permission denied, digital silence) is disproved by real audio, not by first frames.
    @Test func aNewHelperKeepsTheOldAlarmsAsStaleUntilItsEvidence() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remotePermissionDenied, at: t0), alarm(.micNotDelivering, at: t0)]))
        r.apply(snapshot(h2, []))   // crash restart: the new helper's registry is empty
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micNotDelivering])
        #expect(r.staleKinds == [.remotePermissionDenied, .micNotDelivering])
        r.apply(snapshot(h2, []))   // the next poll must not wipe them either
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micNotDelivering])
        r.noteFirstFrames(track: .system, helperSessionId: h2)
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micNotDelivering],
                "frames prove delivery, not permission: a denied tap delivers frames of zeros")
        r.noteRealAudio(track: .system, helperSessionId: h2)
        #expect(Set(r.alarms.keys) == [.micNotDelivering], "mic frames have not arrived yet")
        r.noteFirstFrames(track: .mic, helperSessionId: h2)
        #expect(r.isEmpty)
    }

    /// Each stale class clears on the evidence that disproves it, on its own track, and on nothing else.
    @Test func staleDeliveryKindsClearOnFirstFramesOfTheirTrackOnly() throws {
        for kind in [AlarmKind.micNotDelivering, .remoteNotDelivering, .remoteRecoveryFailed] {
            let track = try #require(kind.track)
            var r = staleRegistry(kind)
            r.noteRealAudio(track: track, helperSessionId: h2)
            r.noteWriteSucceeded(helperSessionId: h2)
            r.noteFirstFrames(track: other(track), helperSessionId: h2)
            #expect(r.alarms[kind] != nil, "\(kind.rawValue): only first frames on its own track disprove it")
            r.noteFirstFrames(track: track, helperSessionId: h2)
            #expect(r.alarms[kind] == nil, "\(kind.rawValue)")
        }
    }

    @Test func staleContentKindsClearOnRealAudioOfTheirTrackOnly() throws {
        for kind in [AlarmKind.micDigitalSilence, .remotePermissionDenied, .remoteCantConfirm] {
            let track = try #require(kind.track)
            var r = staleRegistry(kind)
            r.noteFirstFrames(track: track, helperSessionId: h2)
            r.noteWriteSucceeded(helperSessionId: h2)
            r.noteRealAudio(track: other(track), helperSessionId: h2)
            #expect(r.alarms[kind] != nil, "\(kind.rawValue): only real audio on its own track disproves it")
            r.noteRealAudio(track: track, helperSessionId: h2)
            #expect(r.alarms[kind] == nil, "\(kind.rawValue)")
        }
    }

    /// The track-less stale kind: no track's frames or audio say anything about the disk.
    @Test func aStaleDiskWriteFailureClearsOnlyOnASuccessfulWrite() {
        var r = staleRegistry(.diskWriteFailure)
        for track in [CaptureTrack.mic, .system] {
            r.noteFirstFrames(track: track, helperSessionId: h2)
            r.noteRealAudio(track: track, helperSessionId: h2)
        }
        #expect(r.alarms[.diskWriteFailure] != nil)
        r.noteWriteSucceeded(helperSessionId: h2)
        #expect(r.alarms[.diskWriteFailure] == nil)
    }

    /// Evidence clears only what a REPLACED helper left behind; the current helper's alarms are owned
    /// by its own snapshots.
    @Test func evidenceLeavesTheCurrentHelpersAlarmsAlone() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0), alarm(.micDigitalSilence, at: t0)]))
        r.noteFirstFrames(track: .system, helperSessionId: h1)
        r.noteRealAudio(track: .mic, helperSessionId: h1)
        #expect(Set(r.alarms.keys) == [.remoteNotDelivering, .micDigitalSilence])
    }

    /// Two async channels, no ordering: first frames from a new helper may beat its first snapshot.
    /// The evidence carries the helper id, so the stale transition happens there and is not lost.
    @Test func firstFramesFromANewHelperBeforeItsFirstSnapshotStillClearTheStaleAlarms() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0), alarm(.micDigitalSilence, at: t0)]))
        r.noteFirstFrames(track: .system, helperSessionId: h2)   // before any h2 snapshot
        #expect(r.helperSessionId == HelperSessionId(h2))
        #expect(r.alarms[.remoteNotDelivering] == nil)
        #expect(r.staleKinds == [.micDigitalSilence])
        r.apply(snapshot(h2, []))
        #expect(Set(r.alarms.keys) == [.micDigitalSilence], "h2's empty first snapshot must not wipe the stale content alarm")
    }

    /// A message still in flight from a helper that has since been replaced says nothing about now.
    @Test func lateMessagesFromAReplacedHelperAreIgnored() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot(h2, [alarm(.micNotDelivering, at: t0 + 5)]))
        r.noteFirstFrames(track: .system, helperSessionId: h1)
        r.apply(snapshot(h1, []))
        #expect(r.helperSessionId == HelperSessionId(h2))
        #expect(Set(r.alarms.keys) == [.remoteNotDelivering, .micNotDelivering])
        #expect(r.staleKinds == [.remoteNotDelivering])
    }

    @Test func twoHelperRestartsInARowKeepTheAlarmsStale() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0), alarm(.micDigitalSilence, at: t0)]))
        r.apply(snapshot(h2, []))
        r.apply(snapshot(h3, []))
        #expect(Set(r.alarms.keys) == [.remoteNotDelivering, .micDigitalSilence])
        #expect(r.staleKinds == [.remoteNotDelivering, .micDigitalSilence])
        r.noteFirstFrames(track: .system, helperSessionId: h3)
        #expect(Set(r.alarms.keys) == [.micDigitalSilence])
        r.noteRealAudio(track: .mic, helperSessionId: h3)
        #expect(r.isEmpty)
    }

    /// F2 fix round 1: a replacing helper re-raising the same condition keeps "since when".
    @Test func aNewHelperReRaisingAKindMakesItCurrentAgainAndKeepsItsStart() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remotePermissionDenied, at: t0)]))
        r.apply(snapshot(h2, [alarm(.remotePermissionDenied, at: t0 + 20)]))
        #expect(r.staleKinds.isEmpty)
        #expect(r.alarms[.remotePermissionDenied]?.raisedAt == t0, "the condition has been true since t0")
        r.apply(snapshot(h2, [alarm(.remotePermissionDenied, at: t0 + 20)]))   // the next poll
        #expect(r.alarms[.remotePermissionDenied]?.raisedAt == t0)
    }

    @Test func recordingEndClearsPerRecordingKindsOnly() {
        var r = CaptureAlarmRegistry()
        r.raise(.crashProtectionOff, message: "c", now: t0)
        r.raise(.recordingStopped, message: "s", now: t0)
        r.raise(.diskLow, message: "d", now: t0)
        r.apply(snapshot(h1, [alarm(.micDigitalSilence, at: t0)]))
        r.recordingEnded()
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .recordingStopped])
    }

    @Test func sortedBreaksTimestampTiesByKind() {
        var r = CaptureAlarmRegistry()
        r.raise(.remoteNotDelivering, message: "r", now: t0)
        r.raise(.micNotDelivering, message: "m", now: t0)
        r.raise(.diskLow, message: "d", now: t0)
        r.raise(.crashProtectionOff, message: "c", now: t0 - 1)
        #expect(r.sorted.map(\.kind) == [.crashProtectionOff, .diskLow, .micNotDelivering, .remoteNotDelivering])
    }

    /// F2 fix round 1: sub-second times survive the wire (they order alarms raised within a second).
    @Test func snapshotRoundTrips() throws {
        var r = CaptureAlarmRegistry()
        r.raise(.remoteNotDelivering, message: "r", now: t0 + 0.25)
        r.markNotified(.remoteNotDelivering, now: t0 + 0.5)
        let s = CaptureStatusSnapshot(helperSessionId: h1, sequence: 7, isCapturing: true, alarms: r.sorted,
                                      tracks: [TrackHealthSnapshot(track: .system, expected: true, heartbeatAgeSeconds: 7.5, generation: 2)])
        let decoded = try #require(CaptureStatusSnapshot.decode(s.encoded()))
        #expect(decoded == s)
        #expect(decoded.alarms.first?.raisedAt == t0 + 0.25)
    }

    /// F2 fix round 1: a non-finite heartbeat age must never turn the snapshot into 0 bytes.
    @Test func aNonFiniteHeartbeatAgeCannotBreakTheSnapshot() throws {
        let tracks = [
            TrackHealthSnapshot(track: .system, expected: true, heartbeatAgeSeconds: .infinity, generation: 1),
            TrackHealthSnapshot(track: .mic, expected: true, heartbeatAgeSeconds: .nan, generation: 1),
        ]
        #expect(tracks.allSatisfy { $0.heartbeatAgeSeconds == nil })
        let s = CaptureStatusSnapshot(helperSessionId: h1, sequence: 1, isCapturing: true, alarms: [], tracks: tracks)
        let data = s.encoded()
        #expect(!data.isEmpty)
        #expect(CaptureStatusSnapshot.decode(data) == s)
    }

    /// Review focus 2: a newer helper may send a kind this app does not know. It is skipped, and
    /// recorded, and the known ones survive.
    @Test func snapshotWithUnknownKindKeepsTheOthers() throws {
        let json = """
        {"helperSessionId":"1000-0","sequence":1,"isCapturing":true,"tracks":[],
         "alarms":[{"kind":"somethingNew","raisedAt":"2026-09-24T16:00:00Z","message":"x","episode":1},
                   {"kind":"micDigitalSilence","raisedAt":"2026-09-24T16:00:00Z","message":"y","episode":1}]}
        """
        let decoded = try #require(CaptureStatusSnapshot.decode(Data(json.utf8)))
        #expect(decoded.alarms.map(\.kind) == [.micDigitalSilence])
        #expect(decoded.unknownAlarmKinds == ["somethingNew"])
    }

    /// F2 fix round 1: any OTHER defect fails the whole snapshot. Dropping a malformed alarm would
    /// read as an all-clear on the next same-helper `apply`, silently clearing a live alarm.
    @Test func aMalformedKnownAlarmFailsTheWholeSnapshot() {
        let missingEpisode = """
        {"helperSessionId":"1000-0","sequence":1,"isCapturing":true,"tracks":[],
         "alarms":[{"kind":"remoteNotDelivering","raisedAt":"2026-09-24T16:00:00Z","message":"x"}]}
        """
        let missingKind = """
        {"helperSessionId":"1000-0","sequence":1,"isCapturing":true,"tracks":[],
         "alarms":[{"raisedAt":"2026-09-24T16:00:00Z","message":"x","episode":1}]}
        """
        #expect(CaptureStatusSnapshot.decode(Data(missingEpisode.utf8)) == nil)
        #expect(CaptureStatusSnapshot.decode(Data(missingKind.utf8)) == nil)
    }

    @Test func aFailedDecodeLeavesTheLiveAlarmsInPlace() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0)]))
        let broken = #"{"helperSessionId":"1000-0","sequence":99,"isCapturing":true,"tracks":[],"alarms":[{"kind":"remoteNotDelivering","message":"x","episode":1}]}"#
        if let s = CaptureStatusSnapshot.decode(Data(broken.utf8)) { r.apply(s) }
        #expect(r.alarms[.remoteNotDelivering] != nil)
    }

    @Test func renotifyEveryTwoMinutesWhileActive() {
        var a = ActiveAlarm(kind: .remoteNotDelivering, raisedAt: t0, lastNotifiedAt: t0, message: "m", episode: 1)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 119) == false)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 120))
        a.lastNotifiedAt = nil
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0), "never notified: notify now")
    }

    @Test func windowReopensAfterTheSnooze() {
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: nil, now: t0))
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: t0, now: t0 + 60) == false)
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: t0, now: t0 + CaptureReadiness.repairSnooze))
    }

    @Test func kindsKnowTheirTrackAndOwner() {
        #expect(AlarmKind.micNotDelivering.track == .mic)
        #expect(AlarmKind.remotePermissionDenied.track == .system)
        #expect(AlarmKind.crashProtectionOff.track == nil)
        #expect(AlarmKind.micNotDelivering.isHelperOwned)
        #expect(AlarmKind.sessionWriteFailed.isHelperOwned == false)
        #expect(AlarmKind.recordingStopped.isAcknowledgeable)
        #expect(AlarmKind.recordingStopped.outlivesRecording)
        #expect(AlarmKind.crashProtectionOff.outlivesRecording)
        #expect(AlarmKind.diskLow.outlivesRecording == false)
    }

    // MARK: - F2 fix round 2: ordered helper ids, snapshot sequence, one-off events

    @Test func helperSessionIdsAreOrderedAndStrictlyParsed() throws {
        let id = try #require(HelperSessionId("1790000000123-4"))
        #expect(id == HelperSessionId(processStartMillis: 1_790_000_000_123, registryResets: 4))
        #expect(id.description == "1790000000123-4")
        #expect(HelperSessionId("1000-1")! < HelperSessionId("1000-2")!, "a registry reset is newer")
        #expect(HelperSessionId("1000-9")! < HelperSessionId("2000-0")!, "a later process is newer, whatever its counter")
        #expect(HelperSessionId("1000-1") == HelperSessionId("1000-1"))
        for bad in ["h1", "", "1000", "1000-", "-1", "1000-1-2", "a-1", "1000-x", "1000--1"] {
            #expect(HelperSessionId(bad) == nil, "\(bad) must not parse")
        }
    }

    /// The re-review's sequence: h1 current, h3 adopted, then a LATE h2 message. h2 is older than h3,
    /// so it must not displace h3 — otherwise every later h3 message would be dropped.
    @Test func aLateMessageFromAnOlderHelperNeverDisplacesTheNewestOne() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot(h3, [alarm(.micNotDelivering, at: t0 + 5)]))
        r.apply(snapshot(h2, []))
        r.noteFirstFrames(track: .mic, helperSessionId: h2)
        #expect(r.helperSessionId == HelperSessionId(h3))
        #expect(Set(r.alarms.keys) == [.remoteNotDelivering, .micNotDelivering])
        r.apply(snapshot(h3, []))   // h3 keeps being heard
        #expect(Set(r.alarms.keys) == [.remoteNotDelivering], "h3's own alarm follows h3's snapshot")
        r.noteFirstFrames(track: .system, helperSessionId: h3)
        #expect(r.isEmpty)
    }

    @Test func anEqualIdIsTheSameHelper() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("1000-1", [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot("1000-01", [alarm(.remoteNotDelivering, at: t0)]))   // same numbers, other spelling
        #expect(r.staleKinds.isEmpty)
        r.apply(snapshot("1000-1", []))
        #expect(r.isEmpty, "a same-helper snapshot is the truth for its kinds")
    }

    @Test func anUnparsableHelperIdIsIgnored() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot("garbage", []))
        r.noteFirstFrames(track: .system, helperSessionId: "garbage")
        #expect(r.helperSessionId == HelperSessionId(h1))
        #expect(Set(r.alarms.keys) == [.remoteNotDelivering])
        #expect(r.staleKinds.isEmpty)
    }

    /// Pull replies and pushes race: a same-helper snapshot that is not newer than the last applied
    /// one is stale news and must not overwrite it.
    @Test func aSameHelperSnapshotThatIsNotNewerIsIgnored() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.remoteNotDelivering, at: t0)], sequence: 5))
        r.apply(snapshot(h1, [], sequence: 4))
        #expect(r.alarms[.remoteNotDelivering] != nil, "an older snapshot arrived late")
        r.apply(snapshot(h1, [], sequence: 5))
        #expect(r.alarms[.remoteNotDelivering] != nil, "a duplicate is not newer")
        r.apply(snapshot(h1, [], sequence: 6))
        #expect(r.isEmpty)
        // A newer helper starts its own sequence.
        r.apply(snapshot(h2, [alarm(.micNotDelivering, at: t0)], sequence: 1))
        #expect(r.alarms[.micNotDelivering] != nil)
    }

    /// One-off past events are not a flapping condition: a new one notifies at once.
    @Test func acknowledgeableKindsAreExemptFromTheNotifyFloor() throws {
        for kind in [AlarmKind.recordingStopped, .recordingResumedWithGap] {
            var r = CaptureAlarmRegistry()
            r.raise(kind, message: "first", now: t0)
            r.markNotified(kind, now: t0)
            _ = r.clear(kind)   // acknowledged
            r.raise(kind, message: "second", now: t0 + 10)
            let a = try #require(r.alarms[kind])
            #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 10), "\(kind.rawValue)")
        }
    }

    // MARK: - H2 round 2 item 12: a failed mic follow is an acknowledgeable helper alarm

    @Test func micFollowFailedIsAnAcknowledgeableHelperAlarmScopedToTheRecording() {
        let kind = AlarmKind.micFollowFailed
        #expect(kind.isAcknowledgeable)
        #expect(kind.isHelperOwned, "the helper raises it and its snapshots carry it")
        #expect(kind.track == .mic)
        #expect(!kind.outlivesRecording, "per recording: it goes when the recording ends")
    }

    /// The helper keeps the alarm until a later follow succeeds; the user's acknowledgement must hold
    /// against the helper's next snapshots of that same episode, and a new episode shows again.
    @Test func anAcknowledgedHelperAlarmStaysAcknowledgedUntilItsNextEpisode() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.micFollowFailed, at: t0, episode: 1)]))
        #expect(r.alarms[.micFollowFailed] != nil)
        r.acknowledge(.micFollowFailed)
        #expect(r.alarms[.micFollowFailed] == nil)
        r.apply(snapshot(h1, [alarm(.micFollowFailed, at: t0, episode: 1)]))
        #expect(r.alarms[.micFollowFailed] == nil, "the same episode, already acknowledged")
        r.apply(snapshot(h1, [alarm(.micFollowFailed, at: t0 + 60, episode: 2)]))
        #expect(r.alarms[.micFollowFailed] != nil, "a new failure shows again")
    }

    /// Episodes count per helper registry: the next recording's first failure is episode 1 again.
    @Test func aNewHelperRegistryForgetsTheAcknowledgement() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.micFollowFailed, at: t0, episode: 1)]))
        r.acknowledge(.micFollowFailed)
        r.apply(snapshot(h2, [alarm(.micFollowFailed, at: t0 + 600, episode: 1)]))
        #expect(r.alarms[.micFollowFailed] != nil)
    }

    @Test func onlyAcknowledgeableKindsCanBeAcknowledged() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(.micNotDelivering, at: t0)]))
        r.acknowledge(.micNotDelivering)
        #expect(r.alarms[.micNotDelivering] != nil, "a live condition clears only when it clears")
    }

    // MARK: - Helpers

    /// `kind` raised by helper h1, then left stale by its replacement h2.
    private func staleRegistry(_ kind: AlarmKind) -> CaptureAlarmRegistry {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot(h1, [alarm(kind, at: t0)]))
        r.apply(snapshot(h2, []))
        return r
    }
    private func other(_ track: CaptureTrack) -> CaptureTrack { track == .mic ? .system : .mic }
}
