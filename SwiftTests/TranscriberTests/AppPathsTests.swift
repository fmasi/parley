import Testing
import Foundation
@testable import TranscriberCore

struct AppPathsTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("apppaths-\(UUID().uuidString)")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func migratesLegacyDirectoryWhenPreferredAbsent() throws {
        let root = tempRoot(); defer { cleanup(root) }
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(".audio-transcribe")
        let preferred = root.appendingPathComponent("Application Support/Parley")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "x".write(to: legacy.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let result = AppPaths.resolveDataDirectory(preferred: preferred, legacy: legacy, fileManager: fm)

        #expect(result == preferred)
        #expect(fm.fileExists(atPath: preferred.appendingPathComponent("config.json").path))
        #expect(!fm.fileExists(atPath: legacy.path))  // moved, not copied
    }

    @Test func keepsExistingPreferredAndLeavesLegacyUntouched() throws {
        let root = tempRoot(); defer { cleanup(root) }
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(".audio-transcribe")
        let preferred = root.appendingPathComponent("Application Support/Parley")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: preferred, withIntermediateDirectories: true)
        try "new".write(to: preferred.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let result = AppPaths.resolveDataDirectory(preferred: preferred, legacy: legacy, fileManager: fm)

        #expect(result == preferred)
        // Preferred config is preserved (not overwritten by legacy) and legacy is left alone.
        #expect(try String(contentsOf: preferred.appendingPathComponent("config.json"), encoding: .utf8) == "new")
        #expect(fm.fileExists(atPath: legacy.path))
    }

    @Test func createsPreferredWhenNeitherExists() throws {
        let root = tempRoot(); defer { cleanup(root) }
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(".audio-transcribe")
        let preferred = root.appendingPathComponent("Application Support/Parley")

        let result = AppPaths.resolveDataDirectory(preferred: preferred, legacy: legacy, fileManager: fm)

        #expect(result == preferred)
        #expect(fm.fileExists(atPath: preferred.path))
    }
}
