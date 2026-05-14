import Testing
import Foundation
@testable import TranscriberCore

struct AppVersionTests {

    // -- parseCommitHash --

    @Test func parseCommitHashFromFullDescribe() {
        let hash = AppVersion.parseCommitHash(from: "v0.6.1-12-ga3f9c12")
        #expect(hash == "a3f9c12")
    }

    @Test func parseCommitHashFromDirtyDescribe() {
        let hash = AppVersion.parseCommitHash(from: "v0.6.1-3-gabcdef0-dirty")
        #expect(hash == "abcdef0")
    }

    @Test func parseCommitHashFromTagOnly() {
        let hash = AppVersion.parseCommitHash(from: "v0.7.0")
        #expect(hash == nil)
    }

    @Test func parseCommitHashFromHashOnly() {
        let hash = AppVersion.parseCommitHash(from: "a3f9c12")
        #expect(hash == "a3f9c12")
    }

    @Test func parseCommitHashFromHashOnlyDirty() {
        let hash = AppVersion.parseCommitHash(from: "a3f9c12-dirty")
        #expect(hash == "a3f9c12")
    }

    // -- parseCommitDistance --

    @Test func parseCommitDistanceFromFullDescribe() {
        let distance = AppVersion.parseCommitDistance(from: "v0.6.1-12-ga3f9c12")
        #expect(distance == 12)
    }

    @Test func parseCommitDistanceFromTagOnly() {
        let distance = AppVersion.parseCommitDistance(from: "v0.7.0")
        #expect(distance == 0)
    }

    @Test func parseCommitDistanceFromHashOnly() {
        let distance = AppVersion.parseCommitDistance(from: "a3f9c12")
        #expect(distance == nil)
    }

    // -- displayString --

    @Test func displayStringWithHashAndVersion() {
        let display = AppVersion.formatDisplay(version: "0.6.1", gitDescription: "v0.6.1-12-ga3f9c12")
        #expect(display == "0.6.1 (a3f9c12)")
    }

    @Test func displayStringOnTag() {
        let display = AppVersion.formatDisplay(version: "0.7.0", gitDescription: "v0.7.0")
        #expect(display == "0.7.0")
    }

    @Test func displayStringDirty() {
        let display = AppVersion.formatDisplay(version: "0.6.1", gitDescription: "v0.6.1-3-gabcdef0-dirty")
        #expect(display == "0.6.1 (abcdef0-dirty)")
    }

    @Test func displayStringDevFallback() {
        let display = AppVersion.formatDisplay(version: "dev", gitDescription: "unknown")
        #expect(display == "dev")
    }
}
