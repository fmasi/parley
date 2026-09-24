import Foundation
import Testing
@testable import TranscriberCore

/// H3/H9/L5 (§6): alarms are state, per track, sticky until the condition clears, re-notified
/// periodically. Incident A's watchdog fired once and stayed silent for 51 minutes.
@Suite struct CaptureAlarmTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func snapshot(_ id: String, _ alarms: [ActiveAlarm]) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, isCapturing: true, alarms: alarms, tracks: [])
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
        r.apply(snapshot("h1", [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot("h1", [alarm(.micDigitalSilence, at: t0 + 5)]))
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .micDigitalSilence])
        #expect(r.staleKinds.isEmpty)
    }

    /// Spec §6.3 (scan C7): the 5 s poll must not reset the 2-minute notify clock.
    @Test func pollingDoesNotResetTheNotifyClock() {
        var r = CaptureAlarmRegistry()
        let fromHelper = alarm(.remoteNotDelivering, at: t0)
        r.apply(snapshot("h1", [fromHelper]))
        r.markNotified(.remoteNotDelivering, now: t0 + 1)
        r.apply(snapshot("h1", [fromHelper]))   // the next poll, same episode
        #expect(r.alarms[.remoteNotDelivering]?.lastNotifiedAt == t0 + 1)
        #expect(AlarmRealarmPolicy.shouldRenotify(r.alarms[.remoteNotDelivering]!, now: t0 + 6) == false)
    }

    @Test func aNewEpisodeOfTheSameKindNotifiesAgain() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("h1", [alarm(.remoteNotDelivering, at: t0, episode: 1)]))
        r.markNotified(.remoteNotDelivering, now: t0 + 1)
        r.apply(snapshot("h1", [alarm(.remoteNotDelivering, at: t0 + 30, episode: 2)]))
        #expect(r.alarms[.remoteNotDelivering]?.lastNotifiedAt == nil)
    }

    /// Spec §6.2 (scan C6): a restarted helper starts empty; the app keeps the old set until the
    /// new helper's first frames on that track prove the condition gone.
    @Test func aNewHelperKeepsTheOldAlarmsAsStaleUntilItsFirstFrames() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("h1", [alarm(.remotePermissionDenied, at: t0), alarm(.micDigitalSilence, at: t0)]))
        r.apply(snapshot("h2", []))   // crash restart: the new helper's registry is empty
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micDigitalSilence])
        #expect(r.staleKinds == [.remotePermissionDenied, .micDigitalSilence])
        r.apply(snapshot("h2", []))   // the next poll must not wipe them either
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micDigitalSilence])
        r.noteFirstFrames(track: "system")
        #expect(Set(r.alarms.keys) == [.micDigitalSilence], "mic frames have not arrived yet")
        r.noteFirstFrames(track: "mic")
        #expect(r.isEmpty)
    }

    @Test func aNewHelperReRaisingAKindMakesItCurrentAgain() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("h1", [alarm(.remotePermissionDenied, at: t0)]))
        r.apply(snapshot("h2", [alarm(.remotePermissionDenied, at: t0 + 20)]))
        #expect(r.staleKinds.isEmpty)
        #expect(r.alarms[.remotePermissionDenied]?.raisedAt == t0 + 20)
    }

    @Test func recordingEndClearsPerRecordingKindsOnly() {
        var r = CaptureAlarmRegistry()
        r.raise(.crashProtectionOff, message: "c", now: t0)
        r.raise(.recordingStopped, message: "s", now: t0)
        r.raise(.diskLow, message: "d", now: t0)
        r.apply(snapshot("h1", [alarm(.micDigitalSilence, at: t0)]))
        r.recordingEnded()
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .recordingStopped])
    }

    @Test func snapshotRoundTrips() throws {
        var r = CaptureAlarmRegistry()
        r.raise(.remoteNotDelivering, message: "r", now: t0)
        let s = CaptureStatusSnapshot(helperSessionId: "h1", isCapturing: true, alarms: r.sorted,
                                      tracks: [TrackHealthSnapshot(track: "system", expected: true, heartbeatAgeSeconds: 7.5, generation: 2)])
        let decoded = try #require(CaptureStatusSnapshot.decode(s.encoded()))
        #expect(decoded == s)
    }

    /// Review focus 2: a newer helper may send a kind this app does not know.
    @Test func snapshotWithUnknownKindKeepsTheOthers() throws {
        let json = """
        {"helperSessionId":"h","isCapturing":true,"tracks":[],
         "alarms":[{"kind":"somethingNew","raisedAt":"2026-09-24T16:00:00Z","message":"x","episode":1},
                   {"kind":"micDigitalSilence","raisedAt":"2026-09-24T16:00:00Z","message":"y","episode":1}]}
        """
        let decoded = try #require(CaptureStatusSnapshot.decode(Data(json.utf8)))
        #expect(decoded.alarms.map(\.kind) == [.micDigitalSilence])
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
        #expect(AlarmKind.micNotDelivering.track == "mic")
        #expect(AlarmKind.remotePermissionDenied.track == "system")
        #expect(AlarmKind.crashProtectionOff.track == nil)
        #expect(AlarmKind.micNotDelivering.isHelperOwned)
        #expect(AlarmKind.sessionWriteFailed.isHelperOwned == false)
        #expect(AlarmKind.recordingStopped.isAcknowledgeable)
        #expect(AlarmKind.recordingStopped.outlivesRecording && AlarmKind.crashProtectionOff.outlivesRecording)
        #expect(AlarmKind.diskLow.outlivesRecording == false)
    }
}
