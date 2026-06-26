import Foundation
import AudioCaptureProtocol
import os
import TranscriberCore

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let service = AudioCaptureService()

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
        service.onRestartInPlace = { client?.captureDidRestartInPlace() }
        service.onFailFatally = { reason in client?.captureDidFailFatally(reason: reason) }
        service.onMicDeviceChanged = { deviceId in client?.micDeviceChanged?(to: deviceId) }

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
