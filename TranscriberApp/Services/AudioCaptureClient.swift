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

    func start(outputDirectory: URL, baseName: String, microphoneDeviceId: String? = nil) async throws {
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.startFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.startCapture(
                outputDirectory: outputDirectory.path,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId
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
        let conn = try getConnection()
        return try await withCheckedThrowingContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.stopFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

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

    func updateMicrophone(deviceId: String) async throws {
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.micSwitchFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.updateMicrophone(deviceId: deviceId) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.micSwitchFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    private func getConnection() throws -> NSXPCConnection {
        if connection == nil { connect() }
        guard let conn = connection else {
            throw CaptureError.notConnected
        }
        return conn
    }
}

enum CaptureError: LocalizedError {
    case notConnected
    case startFailed(String)
    case stopFailed(String)
    case micSwitchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC connection not available — run as .app bundle"
        case .startFailed(let msg): return msg
        case .stopFailed(let msg): return msg
        case .micSwitchFailed(let msg): return msg
        }
    }
}
