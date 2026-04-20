import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var lastTranscript: String = ""

    @Published private(set) var meetingStatus: MeetingStatus = .idle

    enum MeetingStatus: Equatable {
        case idle
        case recording(String)   // filename being recorded
        case transcribing
        case done(URL)           // URL of saved notes file
        case failed(String)
    }

    let settingsStore: SettingsStore

    private let recorder = AudioRecorder()
    private let meetingRecorder = MeetingRecorder()
    private let transcriptionService = TranscriptionService()
    private let inputInserter = InputInserter()
    private let hotkeyManager: HotkeyManager
    private var targetApplication: NSRunningApplication?
    private var isRecording = false
    private var isMeetingRecording = false
    private var meetingAudioURL: URL?

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

        Task { @MainActor [weak self] in
            self?.purgeExpiredRecordings()
        }
    }

    func startRecording() async {
        guard !isRecording else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication

        do {
            try await recorder.startRecording(in: settingsStore.settings.recordingDirectory)
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

            let transcript = try await transcriptionService.transcribe(
                audioURL: audioURL,
                settings: settingsStore.settings,
                openAIAPIKey: settingsStore.openAIAPIKey
            )

            applyRetentionPolicy(to: audioURL)

            lastTranscript = transcript
            let insertionResult = await inputInserter.insert(transcript, targeting: targetApplication)
            status = .succeeded(insertionResult.userMessage)
            scheduleStatusReset()
        } catch {
            status = .failed(error.localizedDescription)
            scheduleStatusReset()
        }
    }

    func resetStatus() {
        if case .succeeded = status { status = .idle }
        else if case .failed = status { status = .idle }
    }

    // MARK: - Meeting recording

    func startMeetingRecording() async {
        guard !isMeetingRecording, !isRecording else { return }
        do {
            let url = try await meetingRecorder.start(in: settingsStore.settings.recordingDirectory)
            meetingAudioURL = url
            isMeetingRecording = true
            meetingStatus = .recording(url.lastPathComponent)
        } catch {
            meetingStatus = .failed(error.localizedDescription)
        }
    }

    func stopMeetingRecordingAndTranscribe() async {
        guard isMeetingRecording else { return }
        isMeetingRecording = false
        meetingStatus = .transcribing

        do {
            let audioURL = try await meetingRecorder.stop()

            let transcript = try await transcriptionService.transcribe(
                audioURL: audioURL,
                settings: settingsStore.settings,
                openAIAPIKey: settingsStore.openAIAPIKey
            )

            // Save notes as a .txt file next to the audio file
            let notesURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
            let content = "Meeting Notes — \(dateStr)\n\n\(transcript)\n"
            try content.write(to: notesURL, atomically: true, encoding: .utf8)

            meetingAudioURL = nil
            meetingStatus = .done(notesURL)

            // Reveal the notes file in Finder
            NSWorkspace.shared.activateFileViewerSelecting([notesURL])

        } catch {
            meetingStatus = .failed(error.localizedDescription)
        }
    }

    func resetMeetingStatus() {
        meetingStatus = .idle
    }

    // MARK: - Recording retention

    private func applyRetentionPolicy(to url: URL) {
        guard settingsStore.settings.recordingRetention == .session else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func purgeExpiredRecordings() {
        let retention = settingsStore.settings.recordingRetention
        guard let maxAge = retention.maxAge, maxAge > 0 else { return }

        let dir = resolvedRecordingDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files where file.pathExtension == "m4a" {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func resolvedRecordingDirectory() -> URL {
        let path = settingsStore.settings.recordingDirectory
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst())
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Private

    private func scheduleStatusReset() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.resetStatus()
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
