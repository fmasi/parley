import Foundation
import Testing

/// #297: CI and development both build with the macOS 26 SDK (Swift 6.3+), so nothing needs a `#if compiler(...)`
/// branch any more. Such a branch is code no machine compiles: the old fallback `deinit` in `ChunkRotator` was one,
/// and a test behind one is a test an older toolchain silently drops (`scripts/toolchain-report.sh`, #272). An API
/// newer than the deployment target is guarded at run time with `#available` / `@available`, never at compile time.
///
/// A source scan, because a compile-time branch is invisible to the compiler that takes it.
@Suite struct ToolchainGuardTests {

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static let scanned = ["TranscriberCore", "TranscriberApp", "AudioCaptureHelper", "AudioCaptureProtocol", "SwiftTests"]

    static func swiftFiles(under directory: String) throws -> [String] {
        let base = root.appendingPathComponent(directory)
        let enumerator = try #require(FileManager.default.enumerator(atPath: base.path))
        return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { "\(directory)/\($0)" }.sorted()
    }

    static func lines(of file: String) throws -> [Substring] {
        try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    @Test func noSourceBranchesOnTheCompilerVersion() throws {
        var files: [String] = []
        for directory in Self.scanned { files += try Self.swiftFiles(under: directory) }
        #expect(files.count > 150, "the scan must see the whole tree, not a subset: \(files.count)")
        var offenders: [String] = []
        for file in files {
            for (offset, line) in try Self.lines(of: file).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#if") || trimmed.hasPrefix("#elseif") else { continue }
                if trimmed.contains("compiler(") { offenders.append("\(file):\(offset + 1) \(trimmed)") }
            }
        }
        #expect(offenders.isEmpty, "compile-time toolchain branches: \(offenders)")
    }

    /// The rotator's timer is invalidated by its `isolated deinit` alone, on the main actor that scheduled it — no
    /// fallback `deinit` that hops to the main queue by hand.
    @Test func theRotatorHasOnlyItsIsolatedDeinit() throws {
        let deinits = try Self.lines(of: "TranscriberCore/ChunkRotator.swift")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("deinit {") }
        #expect(deinits == ["isolated deinit {"], "\(deinits)")
    }
}
