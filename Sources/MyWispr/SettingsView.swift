import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Text("Activation shortcut")
                    Spacer()
                    ShortcutRecorder(shortcut: $settingsStore.settings.shortcut)
                }

                Picker("Recording mode", selection: $settingsStore.settings.recordingMode) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Transcription") {
                Picker("Engine", selection: $settingsStore.settings.selectedEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }

                if settingsStore.settings.selectedEngine == .codexCLI {
                    TextField("Model", text: $settingsStore.settings.codexModel)
                    TextField("Codex command template", text: $settingsStore.settings.codexCommandTemplate, axis: .vertical)
                        .lineLimit(3...6)
                    Text("Use `{audio_path}` and `{model}` placeholders in the command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Custom command template", text: $settingsStore.settings.customCommandTemplate, axis: .vertical)
                        .lineLimit(3...6)
                    Text("Use `{audio_path}` as the audio file placeholder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                Text(model.status.title)
                if case .failed(let message) = model.status {
                    Text(message).foregroundStyle(.red)
                }
                if case .succeeded(let message) = model.status {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
    }
}
