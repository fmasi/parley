import Foundation
import AudioCaptureProtocol
import os
import TranscriberCore

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let service = AudioCaptureService()
    /// ONE serial queue for every reverse-channel call. The app then receives them in the order the
    /// helper sent them (from a concurrent queue a newer alarm push could overtake an older one), and
    /// no XPC send ever runs on the real-time audio queue or a write path already in a degraded I/O state.
    private let reverseQueue = DispatchQueue(label: "audio-capture.reverse-channel", qos: .utility)

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        newConnection.exportedObject = service

        // Reverse channel (#86): let the service call back into the app to report an in-place
        // restart or a fatal failure. The app sets a matching exported object on its side.
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: AudioCaptureClientProtocol.self
        )
        let client = newConnection.remoteObjectProxyWithErrorHandler { error in
            Logger.audio.debug("Reverse-channel proxy error: \(error.localizedDescription, privacy: .public)")
        } as? AudioCaptureClientProtocol
        let send = reverseQueue
        service.onRestartInPlace = { send.async { client?.captureDidRestartInPlace() } }
        service.onFailFatally = { reason in send.async { client?.captureDidFailFatally(reason: reason) } }
        service.onMicDeviceChanged = { deviceId in send.async { client?.micDeviceChanged?(to: deviceId) } }
        service.onSystemAudioUnrecoverable = { reason in send.async { client?.captureSystemAudioUnrecoverable(reason: reason) } }
        // `onQualityAnomaly` can be invoked directly from the real-time audio queue (exact-zero mic
        // detection) or from a write-failure path already in a degraded I/O state: the hop to
        // `reverseQueue` keeps the audio callback path from ever blocking on IPC scheduling.
        service.onQualityAnomaly = { kind, message in
            send.async { client?.captureQualityAnomaly?(kind: kind, message: message) }
        }
        service.onFirstFrames = { track, helperSessionId in
            send.async { client?.captureDidDeliverFirstFrames?(track: track.rawValue, helperSessionId: helperSessionId) }
        }
        service.onAlarmsChanged = { data in
            send.async { client?.captureAlarmsChanged?(snapshot: data) }
        }
        service.onRealAudio = { track, helperSessionId in
            send.async { client?.captureDidDeliverRealAudio?(track: track.rawValue, helperSessionId: helperSessionId) }
        }
        service.onWriteSucceeded = { helperSessionId in
            send.async { client?.captureDidWriteSuccessfully?(helperSessionId: helperSessionId) }
        }

        newConnection.invalidationHandler = { [weak self] in
            guard let self else { return }
            Logger.audio.warning("XPC client disconnected — stopping capture and finalizing")
            self.service.stopAndFinalize()
        }

        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
