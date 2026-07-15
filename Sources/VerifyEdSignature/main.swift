import Foundation
import VerifyEdSignatureCore

// verify-ed-signature --pubkey <base64> --signature <base64> --file <path>
//   exit 0  signature valid
//   exit 1  signature invalid
//   exit 2  usage / IO error
// Public-key-only: used by scripts/verify-release-feed.sh (and CI) to validate a published
// release's `sparkle:edSignature` against the downloaded zip. No secret involved.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var pubkey: String?
var signature: String?
var file: String?

let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--pubkey": i += 1; pubkey = i < args.count ? args[i] : nil
    case "--signature": i += 1; signature = i < args.count ? args[i] : nil
    case "--file": i += 1; file = i < args.count ? args[i] : nil
    default: fail("unknown argument: \(args[i])")
    }
    i += 1
}

guard let pubkey, let signature, let file else {
    fail("usage: verify-ed-signature --pubkey <base64> --signature <base64> --file <path>")
}
guard let data = FileManager.default.contents(atPath: file) else {
    fail("error: cannot read file: \(file)")
}

exit(verifyEd25519(pubKeyBase64: pubkey, signatureBase64: signature, fileData: data) ? 0 : 1)
