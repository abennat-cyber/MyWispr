import AVFoundation
import ApplicationServices
import AppKit
import EventKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenCapturePermission: Bool = CGPreflightScreenCaptureAccess()
    @State private var accessibilityTrusted: Bool = AXIsProcessTrusted()
    @State private var apiKeyVisible: Bool = false
    @State private var showLanguagePicker: Bool = false
    @State private var settingsChanged: Bool = false
    @State private var newVocabWord: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if settingsChanged {
                restartBanner
            }
            Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(contentsOfFile: logoPath) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MyWispr")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Speech to text for your Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

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

            Section("Recording") {
                HStack {
                    TextField("Save recordings to", text: $settingsStore.settings.recordingDirectory)
                        .help("Folder where audio recordings are saved. Use ~ for your home directory.")
                    Button("Choose…") { chooseDirectory() }
                        .buttonStyle(.borderless)
                }

                Picker("Keep recordings for", selection: $settingsStore.settings.recordingRetention) {
                    ForEach(RecordingRetention.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }

                if settingsStore.settings.recordingRetention != .session {
                    Button("Purge expired recordings now") {
                        model.purgeExpiredRecordings()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                }

                Toggle("Mute system audio while recording", isOn: $settingsStore.settings.muteSpeakerWhileRecording)
                    .help("Mutes output volume of the default speaker while recording is active, restoring it afterward.")
            }

            Section("Transcription") {
                Picker("Engine", selection: $settingsStore.settings.selectedEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }

                if settingsStore.settings.selectedEngine != .customCommand {
                    languagePickerRow
                }

                switch settingsStore.settings.selectedEngine {
                case .localWhisper:
                    localWhisperFields
                case .whisperAPI:
                    whisperAPIFields
                case .customCommand:
                    customCommandFields
                }
            }

            Section("Calendar") {
                calendarSection
            }

            Section("Dictionary") {
                dictionarySection
            }

            Section("Permissions") {
                permissionRow(
                    label: "Microphone",
                    granted: micPermission == .authorized,
                    description: micPermission == .authorized
                        ? "Granted"
                        : micPermission == .notDetermined
                            ? "Not yet requested"
                            : "Denied — open System Settings → Privacy & Security → Microphone",
                    buttonTitle: micPermission == .notDetermined ? "Request" : nil,
                    action: requestMicPermission
                )

                permissionRow(
                    label: "System audio",
                    granted: screenCapturePermission,
                    description: screenCapturePermission
                        ? "Granted — meeting recording can capture the default output device"
                        : "Required for meeting recording — grant Screen & System Audio Recording access, then restart MyWispr",
                    buttonTitle: screenCapturePermission ? nil : "Request",
                    action: requestScreenCapturePermission
                )

                permissionRow(
                    label: "Accessibility",
                    granted: accessibilityTrusted,
                    description: accessibilityTrusted
                        ? "Granted — text will be typed directly"
                        : "Not granted — text will fall back to clipboard",
                    buttonTitle: accessibilityTrusted ? nil : "Open Settings",
                    action: openAccessibilitySettings
                )
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
            .onAppear {
                micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
                screenCapturePermission = CGPreflightScreenCaptureAccess()
                accessibilityTrusted = AXIsProcessTrusted()
            }
            .onChange(of: settingsStore.settings) { _, _ in
                settingsChanged = true
            }
            .onChange(of: settingsStore.openAIAPIKey) { _, _ in
                settingsChanged = true
            }
        } // end VStack
    }

    private var restartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.white)
            Text("Restart MyWispr to apply changes.")
                .font(.callout)
                .foregroundStyle(.white)
            Spacer()
            Button("Restart Now") {
                restartApp()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Language picker

    @ViewBuilder
    private var languagePickerRow: some View {
        let langs = settingsStore.settings.transcriptionLanguages.filter { $0 != .auto }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Languages")
                    .fontWeight(.medium)
                Spacer()
                Text(langs.isEmpty ? "Auto-detect" : langs.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            ForEach(Array(langs.enumerated()), id: \.offset) { index, lang in
                HStack {
                    Text(lang.displayName)
                        .font(.callout)
                    Spacer()
                    Button {
                        settingsStore.settings.transcriptionLanguages.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            if langs.count < 5 {
                Button {
                    showLanguagePicker = true
                } label: {
                    Label("Add language", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .sheet(isPresented: $showLanguagePicker) {
                    LanguageAddView(
                        existing: settingsStore.settings.transcriptionLanguages,
                        onAdd: { lang in
                            if !settingsStore.settings.transcriptionLanguages.contains(lang) {
                                settingsStore.settings.transcriptionLanguages.append(lang)
                            }
                        },
                        isPresented: $showLanguagePicker
                    )
                }
            }

            if !langs.isEmpty {
                Text("Whisper will detect between these languages. Fewer languages = faster, more accurate detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No languages set — Whisper auto-detects from all supported languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Dictionary

    @ViewBuilder
    private var dictionarySection: some View {
        HStack(spacing: 6) {
            TextField("Word or phrase", text: $newVocabWord)
                .onSubmit { addVocabWord() }
            Button("Add") { addVocabWord() }
                .buttonStyle(.borderless)
                .disabled(newVocabWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        ForEach(Array(settingsStore.settings.customVocabulary.enumerated()), id: \.offset) { index, word in
            HStack {
                Text(word)
                    .font(.callout)
                Spacer()
                Button {
                    settingsStore.settings.customVocabulary.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }

        Text("These words are passed to Whisper to improve recognition of names, places, and domain-specific terms.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func addVocabWord() {
        let word = newVocabWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty,
              !settingsStore.settings.customVocabulary.contains(word) else { return }
        settingsStore.settings.customVocabulary.append(word)
        newVocabWord = ""
    }

    private var logoPath: String {
        // Look next to the binary first (installed app), then in the project source tree.
        let candidates = [
            Bundle.main.path(forResource: "MyWisprLogo", ofType: "png"),
            "/Applications/MyWispr.app/Contents/Resources/MyWisprLogo.png",
            "/Users/abennat/Documents/MyWispr/MyWisprLogo.png",
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? ""
    }

    // MARK: - Engine fields

    @ViewBuilder
    private var calendarSection: some View {
        if model.calendarAccessState == .granted {
            Picker(
                "Calendar",
                selection: Binding(
                    get: { settingsStore.settings.selectedCalendarIdentifier },
                    set: { model.selectCalendar($0) }
                )
            ) {
                Text("All calendars").tag("")
                ForEach(model.availableCalendars) { calendar in
                    Text(calendar.displayTitle).tag(calendar.id)
                }
            }
            .pickerStyle(.menu)

            Text("Choose the Apple Calendar source MyWispr should use for meeting autofill. Select the Google calendar account that contains your meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.calendarAccessState.title)
                    .fontWeight(.medium)
                if case .denied(let message) = model.calendarAccessState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("MyWispr reads meetings from the local Apple Calendar store, including Google calendars synced to the Calendar app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            switch model.calendarAccessState {
            case .requesting:
                ProgressView()
                    .controlSize(.small)
            case .granted:
                Button("Refresh") {
                    Task {
                        await model.refreshCalendarAccessState()
                        await model.refreshAvailableCalendars()
                    }
                }
                .buttonStyle(.borderless)
            case .notDetermined, .denied:
                Button("Grant Access") {
                    Task { await model.requestCalendarAccess() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var localWhisperFields: some View {
        let binaryFound = LocalWhisperService.resolveBinaryPath() != nil
        let modelPath = LocalWhisperService.resolveModelPath(
            model: settingsStore.settings.localWhisperModel,
            modelDir: settingsStore.settings.localWhisperModelDir
        )
        let modelFound = FileManager.default.fileExists(atPath: modelPath)
        let availableModels = LocalWhisperService.availableModels(in: settingsStore.settings.localWhisperModelDir)
        let displayedModels = availableModels.contains(settingsStore.settings.localWhisperModel)
            ? availableModels
            : [settingsStore.settings.localWhisperModel] + availableModels

        if !binaryFound {
            VStack(alignment: .leading, spacing: 6) {
                Label("whisper-cli not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
                Text("Install whisper.cpp via Homebrew, then reopen Settings:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("brew install whisper-cpp")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        } else {
            Label("whisper-cli found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }

        Picker("Model size", selection: $settingsStore.settings.localWhisperModel) {
            ForEach(displayedModels) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.menu)

        TextField("Models directory", text: $settingsStore.settings.localWhisperModelDir)
            .help("Directory where ggml-*.bin model files are stored.")

        if binaryFound && !modelFound {
            VStack(alignment: .leading, spacing: 6) {
                Label("Model file not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
                Text("Download the \(settingsStore.settings.localWhisperModel.rawValue) model (~\(settingsStore.settings.localWhisperModel.downloadSize)):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("curl -L -o \(settingsStore.settings.localWhisperModelDir)/\(settingsStore.settings.localWhisperModel.filename) https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(settingsStore.settings.localWhisperModel.filename)")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        } else if binaryFound && modelFound {
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var whisperAPIFields: some View {
        HStack {
            if apiKeyVisible {
                TextField("API key", text: $settingsStore.openAIAPIKey)
                    .textContentType(.password)
            } else {
                SecureField("API key", text: $settingsStore.openAIAPIKey)
            }
            Button(apiKeyVisible ? "Hide" : "Show") {
                apiKeyVisible.toggle()
            }
            .buttonStyle(.borderless)
        }

        if settingsStore.openAIAPIKey.isEmpty {
            Text("An OpenAI API key is required. Get one at platform.openai.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Picker("Whisper model", selection: $settingsStore.settings.whisperModel) {
            Text("whisper-1").tag("whisper-1")
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var customCommandFields: some View {
        TextField("Command template", text: $settingsStore.settings.customCommandTemplate, axis: .vertical)
            .lineLimit(3...6)
        Text("Use `{audio_path}` as the audio file placeholder.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Permissions

    @ViewBuilder
    private func permissionRow(
        label: String,
        granted: Bool,
        description: String,
        buttonTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .imageScale(.medium)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func requestMicPermission() {
        Task {
            await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private func requestScreenCapturePermission() {
        screenCapturePermission = CGRequestScreenCaptureAccess()
        if !screenCapturePermission {
            openScreenCaptureSettings()
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Directory picker

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose folder to save recordings"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.recordingDirectory = url.path
        }
    }
}
