import Foundation

/// The one capability ChunkRotator needs from the XPC audio client. Defined in Core so the
/// pipeline can live in Core (and be unit-tested with a fake) while the concrete NSXPC client
/// stays in the app target. AudioCaptureClient already has this exact signature.
@MainActor
public protocol ChunkRotationClient: AnyObject {
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws
        -> (systemPath: String, micPath: String)
}
