import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var lastTranscript: String = ""

    let settingsStore: SettingsStore

    private let recorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let inputInserter = InputInserter()
    private let hotkeyManager: HotkeyManager
    private var targetApplication: NSRunningApplication?
    private var isRecording = false

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.hotkeyManager = HotkeyManager(
            currentShortcut: settingsStore.settings.shortcut,
            settingsPublisher: settingsStore.$settings
        )

        hotkeyManager.onShortcutPressed = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleShortcutPressed()
            }
        }

        hotkeyManager.onShortcutReleased = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleShortcutReleased()
            }
        }
    }

    func startRecording() async {
        guard !isRecording else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication

        do {
            try await recorder.startRecording()
            isRecording = true
            status = .recording
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording else { return }
        status = .transcribing
        isRecording = false

        do {
            let audioURL = try recorder.stopRecording()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let transcript = try await transcriptionService.transcribe(
                audioURL: audioURL,
                settings: settingsStore.settings
            )

            lastTranscript = transcript
            let insertionResult = await inputInserter.insert(transcript, targeting: targetApplication)
            status = .succeeded(insertionResult.userMessage)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func resetStatus() {
        if case .succeeded = status {
            status = .idle
        }
    }

    private func handleShortcutPressed() async {
        switch settingsStore.settings.recordingMode {
        case .toggle:
            if isRecording {
                await stopRecordingAndTranscribe()
            } else {
                await startRecording()
            }
        case .holdToTalk:
            if !isRecording {
                await startRecording()
            }
        }
    }

    private func handleShortcutReleased() async {
        guard settingsStore.settings.recordingMode == .holdToTalk, isRecording else { return }
        await stopRecordingAndTranscribe()
    }
}
