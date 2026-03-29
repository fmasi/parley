import Foundation
import AudioCaptureProtocol

struct AudioPaths {
    let systemAudio: URL
    let micAudio: URL
}

final class AudioCaptureClient {
    private var connection: NSXPCConnection?

    func connect() {
        let conn = NSXPCConnection(serviceName: audioCaptureServiceName)
        conn.remoteObjectInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        conn.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        conn.resume()
        connection = conn
    }

    func start(outputDirectory: URL, baseName: String) async throws {
        let proxy = try proxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.startCapture(
                outputDirectory: outputDirectory.path,
                baseName: baseName
            ) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.startFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    func stop() async throws -> AudioPaths {
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.stopCapture { systemPath, micPath, errorMessage in
                if let sys = systemPath, let mic = micPath {
                    cont.resume(returning: AudioPaths(
                        systemAudio: URL(fileURLWithPath: sys),
                        micAudio: URL(fileURLWithPath: mic)
                    ))
                } else {
                    cont.resume(throwing: CaptureError.stopFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    private func proxy() throws -> AudioCaptureProtocol {
        if connection == nil { connect() }
        guard let conn = connection else {
            throw CaptureError.notConnected
        }
        guard let proxy = conn.remoteObjectProxy as? AudioCaptureProtocol else {
            throw CaptureError.notConnected
        }
        return proxy
    }
}

enum CaptureError: LocalizedError {
    case notConnected
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC connection not available"
        case .startFailed(let msg): return msg
        case .stopFailed(let msg): return msg
        }
    }
}
