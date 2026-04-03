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
