import Foundation
import AudioCaptureProtocol
import TranscriberCore
import os

struct AudioPaths {
    let systemAudio: URL
    let micAudio: URL
}

@MainActor
final class AudioCaptureClient {
    private var connection: NSXPCConnection?

    /// Invoked when the XPC connection is invalidated (e.g. service crash).
    var onServiceCrash: (@Sendable () -> Void)?

    func connect() {
        let conn = NSXPCConnection(serviceName: audioCaptureServiceName)
        conn.remoteObjectInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                Logger.audio.warning("XPC connection invalidated")
                self?.connection = nil
                self?.onServiceCrash?()
            }
        }
        conn.resume()
        Logger.audio.debug("XPC connection established")
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

    func updateMicrophone(deviceId: String?) async throws {
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

    /// Pings the XPC service to check whether a capture session is currently active.
    /// Attempts to reconnect if the connection is nil. Returns false if the service
    /// is unreachable (used for crash-recovery Flow A re-attach on launch).
    func isCapturing() async -> Bool {
        guard let conn = connection else {
            connect()
            guard let conn = connection else { return false }
            let result = await pingStatus(conn)
            Logger.audio.debug("XPC status ping: \(result)")
            return result
        }
        let result = await pingStatus(conn)
        Logger.audio.debug("XPC status ping: \(result)")
        return result
    }

    private func pingStatus(_ conn: NSXPCConnection) async -> Bool {
        await withCheckedContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                cont.resume(returning: false)
            } as! AudioCaptureProtocol
            proxy.status { isCapturing, _ in
                cont.resume(returning: isCapturing)
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
