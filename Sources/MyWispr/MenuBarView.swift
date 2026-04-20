import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MyWispr")
                .font(.headline)

            LabeledContent("Shortcut", value: settingsStore.settings.shortcut.displayText)
            LabeledContent("Mode", value: settingsStore.settings.recordingMode.title)
            LabeledContent("Status", value: model.status.title)

            if case .failed(let message) = model.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .succeeded(let message) = model.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.lastTranscript.isEmpty {
                Divider()
                Text("Last transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.lastTranscript)
                    .font(.caption)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }

            Divider()

            Button(model.status == .recording ? "Stop and transcribe" : "Start recording") {
                Task {
                    if model.status == .recording {
                        await model.stopRecordingAndTranscribe()
                    } else {
                        await model.startRecording()
                    }
                }
            }

            Button("Settings…") {
                openSettings()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
