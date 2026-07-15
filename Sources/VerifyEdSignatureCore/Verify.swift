import CryptoKit
import Foundation

/// Verify a Sparkle EdDSA (`sparkle:edSignature`) signature against a file's bytes, using only the
/// public key (`SUPublicEDKey`). Sparkle's EdDSA is Ed25519 (RFC 8032); CryptoKit's
/// `Curve25519.Signing` is the same scheme, so this validates a real Sparkle-signed release with
/// no Sparkle-internal API and no secret — exactly what a CI feed guard needs.
///
/// Fails closed: any malformed input (bad base64, wrong key length, tampered file) returns false.
public func verifyEd25519(pubKeyBase64: String, signatureBase64: String, fileData: Data) -> Bool {
    guard let pub = Data(base64Encoded: pubKeyBase64),
          let sig = Data(base64Encoded: signatureBase64),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub)
    else { return false }
    return key.isValidSignature(sig, for: fileData)
}
