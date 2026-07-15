import CryptoKit
import Foundation
import Testing
@testable import VerifyEdSignatureCore

/// The signature verifier the release-feed guard relies on. Ed25519 keypairs are generated at test
/// time (CryptoKit == Sparkle's EdDSA scheme); cross-compatibility with Sparkle's own `sign_update`
/// is exercised separately by scripts/sparkle-dryrun.sh and the first real release.
@Suite struct EdSignatureVerifyTests {

    @Test func validSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let message = Data("release bytes".utf8)
        let sig = try key.signature(for: message)
        #expect(verifyEd25519(
            pubKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            signatureBase64: sig.base64EncodedString(),
            fileData: message) == true)
    }

    @Test func tamperedFileFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try key.signature(for: Data("original".utf8))
        #expect(verifyEd25519(
            pubKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            signatureBase64: sig.base64EncodedString(),
            fileData: Data("tampered".utf8)) == false)
    }

    @Test func wrongKeyFails() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let message = Data("release bytes".utf8)
        let sig = try signer.signature(for: message)
        #expect(verifyEd25519(
            pubKeyBase64: other.publicKey.rawRepresentation.base64EncodedString(),
            signatureBase64: sig.base64EncodedString(),
            fileData: message) == false)
    }

    @Test func garbageInputsFailClosed() {
        #expect(verifyEd25519(pubKeyBase64: "!!!", signatureBase64: "!!!", fileData: Data()) == false)
    }
}
