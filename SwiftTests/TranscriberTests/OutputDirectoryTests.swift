import Foundation
import Testing
@testable import TranscriberCore

/// #246: `Parley transcribe … --output-dir ./out` failed on a file inside `./out` when the
/// directory did not exist. `OutputDirectory.ensureExists` is what creates it (the split path and
/// the CLI both call it) and what turns "cannot create it" into an error naming the directory.
@Suite struct OutputDirectoryTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outdir-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsAMissingDirectoryWithIntermediates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("out/nested", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        try OutputDirectory.ensureExists(target)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    /// The default `--output-dir` is the input file's own folder, full of the user's recordings:
    /// ensuring a directory that is already there must not touch what is in it.
    @Test func leavesAnExistingDirectoryAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("transcript.json")
        try Data("kept".utf8).write(to: existing)

        try OutputDirectory.ensureExists(dir)

        #expect(try Data(contentsOf: existing) == Data("kept".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["transcript.json"])
    }

    /// A path occupied by a regular file can never become a directory. The error names that path,
    /// and the file standing in the way is not replaced.
    @Test func anUncreatablePathThrowsNamingTheDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocker)

        do {
            try OutputDirectory.ensureExists(blocker)
            Issue.record("a path occupied by a regular file must throw")
        } catch let error as OutputDirectoryError {
            #expect(error.directory.path == blocker.path)
            #expect(error.localizedDescription.contains(blocker.path),
                    "error must name the output directory: \(error.localizedDescription)")
        } catch {
            Issue.record("expected OutputDirectoryError, got \(error)")
        }
        #expect(try Data(contentsOf: blocker) == Data("occupied".utf8))
    }
}
