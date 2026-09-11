import SwiftUI
import TranscriberCore

struct MicrophonePicker: View {
    @Binding var selectedDeviceId: String?
    /// Supplied when the host must control the meter — a dialog releases the mic before the capture
    /// helper opens it.
    private let externalMonitor: InputLevelMonitor?

    @State private var ownMonitor = InputLevelMonitor()
    private var levelMonitor: InputLevelMonitor { externalMonitor ?? ownMonitor }

    /// Live from the background-scanned catalog (#192), so a mic that appears after the dialog opened is
    /// listed, plus a row for the selection if the scan has not found it (yet).
    private var devices: [AudioInputDevice] {
        AudioDeviceEnumerator.listing(AudioDeviceCatalog.shared.devices, keeping: selectedDeviceId)
    }

    init(selectedDeviceId: Binding<String?>, levelMonitor: InputLevelMonitor? = nil) {
        self._selectedDeviceId = selectedDeviceId
        self.externalMonitor = levelMonitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // SectionHeader token (design-system-0.8.x.md) — was a third
            // distinct section-header style.
            Text("Microphone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("", selection: $selectedDeviceId) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()

                meter
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

extension MicrophonePicker {
    /// The level bar, or why there is none.
    @ViewBuilder fileprivate var meter: some View {
        switch levelMonitor.status {
        case .inUseByRecording:
            meterCaption("In use", color: .secondary)
                .help("This microphone is being recorded. Its level isn't shown here, so the two never compete for it.")
        case .notResponding:
            meterCaption("Not responding", color: .orange)
                .help("This microphone isn't responding. Pick another one.")
        case .unavailable:
            meterCaption("Unavailable", color: .secondary)
        case .off, .starting, .live:
            // Level meter — matches System Settings style
            LevelMeterView(level: levelMonitor.level)
                .frame(width: 80, height: 6)
        }
    }

    private func meterCaption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .frame(minWidth: 80, alignment: .leading)
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
