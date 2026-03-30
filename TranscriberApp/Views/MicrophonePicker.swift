import SwiftUI
import TranscriberCore

struct MicrophonePicker: View {
    @Binding var selectedDeviceId: String?
    let devices: [AudioInputDevice]

    @State private var levelMonitor = InputLevelMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Microphone")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("", selection: $selectedDeviceId) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()

                // Level meter — matches System Settings style
                LevelMeterView(level: levelMonitor.level)
                    .frame(width: 80, height: 6)
            }
        }
        .onAppear {
            levelMonitor.start(deviceId: selectedDeviceId)
        }
        .onDisappear {
            levelMonitor.stop()
        }
        .onChange(of: selectedDeviceId) { _, newValue in
            levelMonitor.start(deviceId: newValue)
        }
    }
}

/// A simple horizontal level meter bar.
struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private var meterColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}
