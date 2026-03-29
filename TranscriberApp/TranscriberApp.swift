import SwiftUI

@main
struct TranscriberApp: App {
    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: "mic") {
            Text("Transcriber is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
