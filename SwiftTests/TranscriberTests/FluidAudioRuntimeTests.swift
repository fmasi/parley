import Foundation
import os
import Testing
import FluidAudio
@testable import TranscriberCore

/// Records every value the gate gives its switch.
private final class SwitchLog: Sendable {
    private let values = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    var all: [Bool] { values.withLock { $0 } }
    var last: Bool? { all.last }
    func record(_ offline: Bool) { values.withLock { $0.append(offline) } }
}

@Suite struct ModelDownloadGateTests {
    private func makeGate() -> (ModelDownloadGate, SwitchLog) {
        let log = SwitchLog()
        return (ModelDownloadGate { log.record($0) }, log)
    }

    @Test func withNoDownloadInProgressTheSwitchIsOffline() {
        let (gate, log) = makeGate()
        gate.enforce()
        #expect(log.all == [true])
        #expect(!gate.isAllowing)
    }

    @Test func aDownloadScopeIsOnlineAndOfflineAgainOnceItEnds() async {
        let (gate, log) = makeGate()
        let inside: Bool? = await gate.allowing { log.last }
        #expect(inside == false)
        #expect(log.last == true)
        #expect(!gate.isAllowing)
    }

    @Test func aThrowingDownloadStillLeavesTheSwitchOffline() async {
        struct Boom: Error {}
        let (gate, log) = makeGate()
        await #expect(throws: Boom.self) {
            try await gate.allowing { () async throws -> Void in throw Boom() }
        }
        #expect(log.last == true)
        #expect(!gate.isAllowing)
    }

    @Test func aNestedScopeKeepsTheOuterOneOnline() async {
        let (gate, log) = makeGate()
        let afterInner: Bool? = await gate.allowing {
            await gate.allowing {}
            return log.last
        }
        #expect(afterInner == false)
        #expect(log.last == true)
    }

    @Test func overlappingScopesGoOfflineOnlyWhenTheLastEnds() async {
        let (gate, log) = makeGate()
        let (firstEntered, firstEnteredCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        let first = Task {
            await gate.allowing {
                firstEnteredCont.yield()
                for await _ in release { break }
            }
        }
        for await _ in firstEntered { break }
        await gate.allowing {}
        // The second scope ended while the first is still open: still online.
        #expect(log.last == false)
        #expect(gate.isAllowing)
        releaseCont.yield()
        await first.value
        #expect(log.last == true)
        #expect(!gate.isAllowing)
    }

    @Test func enforceDuringAScopeKeepsItOnline() async {
        let (gate, log) = makeGate()
        await gate.allowing { gate.enforce() }
        #expect(log.all == [false, false, true])
    }
}

@Suite struct ModelRevisionMarkerTests {
    private func makeRepo(marker: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("revision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let marker {
            try Data(marker.utf8).write(to: dir.appendingPathComponent(ModelRevisionMarker.fileName))
        }
        return dir
    }

    @Test func aMainFolderWithoutAMarkerIsCurrent() throws {
        let dir = try makeRepo(marker: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelRevisionMarker.matches(repoDir: dir, revision: "main"))
    }

    @Test func aPinnedRevisionWithoutAMarkerIsNotCurrent() throws {
        let dir = try makeRepo(marker: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelRevisionMarker.matches(repoDir: dir, revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232"))
    }

    @Test func theMatchingMarkerWithItsTrailingNewlineIsCurrent() throws {
        let dir = try makeRepo(marker: "df2625ac79a7ac6b65ad868fee6d80f320da4232\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelRevisionMarker.matches(repoDir: dir, revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232"))
    }

    @Test func anotherRevisionsMarkerIsNotCurrent() throws {
        let dir = try makeRepo(marker: "0000000000000000000000000000000000000000\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelRevisionMarker.matches(repoDir: dir, revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232"))
    }

    @Test func aMarkerAlsoBindsAMainFolder() throws {
        let dir = try makeRepo(marker: "abc\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelRevisionMarker.matches(repoDir: dir, revision: "main"))
    }
}

@Suite(.serialized) struct FluidAudioRuntimeTests {
    @Test func configureTurnsFluidAudioOfflineAndOffTheConsole() {
        let saved = (ModelHub.offlineMode, AppLogger.mirrorsToConsole, AppLogger.minimumLevel)
        defer {
            ModelHub.offlineMode = saved.0
            AppLogger.mirrorsToConsole = saved.1
            AppLogger.minimumLevel = saved.2
        }
        ModelHub.offlineMode = false
        AppLogger.mirrorsToConsole = true
        AppLogger.minimumLevel = .debug

        FluidAudioRuntime.configure()

        #expect(ModelHub.offlineMode)
        #expect(!AppLogger.mirrorsToConsole)
        #expect(AppLogger.minimumLevel == .info)
    }

    @Test func allowingDownloadsIsOnlineOnlyForItsBody() async {
        let saved = ModelHub.offlineMode
        defer { ModelHub.offlineMode = saved }
        let inside = await FluidAudioRuntime.allowingDownloads { ModelHub.offlineMode }
        #expect(inside == false)
        #expect(ModelHub.offlineMode)
    }

    /// The pinned diarizer revision Parley checks is the one FluidAudio downloads; a bump of the pin in a
    /// FluidAudio update makes the cached model "not cached", so Setup fetches the new one (#351).
    @Test func theDiarizerIsCachedOnlyWithItsPinnedRevisionMarker() async throws {
        guard try await TestModels.ensureDiarization() else { return }  // on CI a missing model fails, never skips
        let repoDir = OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent(Repo.diarizer.folderName)
        let fm = FileManager.default
        let marker = repoDir.appendingPathComponent(ModelRevisionMarker.fileName)
        let saved = try? Data(contentsOf: marker)
        defer {
            if let saved { try? saved.write(to: marker) } else { try? fm.removeItem(at: marker) }
        }
        try Data("0000000000000000000000000000000000000000\n".utf8).write(to: marker)
        #expect(!FluidAudioDiarizer.isDiarizationCached())
    }
}
