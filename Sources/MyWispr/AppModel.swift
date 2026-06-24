import AppKit
import Combine
import Foundation
import MyWisprCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var lastTranscript: String = ""

    @Published private(set) var meetingStatus: MeetingStatus = .idle
    @Published var meetingDraft = MeetingSessionDraft()
    @Published var isMeetingSetupPresented = false
    @Published private(set) var meetingContextLookupState: MeetingContextLookupState = .idle
    @Published private(set) var activeMeetingSession: ActiveMeetingSession?
    @Published private(set) var liveMeetingTranscript: String = ""
    @Published private(set) var liveMeetingTranscriptionStatus: String = ""
    @Published private(set) var calendarAccessState: CalendarAccessState = .notDetermined
    @Published private(set) var availableCalendars: [CalendarSelection] = []
    @Published private(set) var utilityWindowZoomScale: CGFloat = 1.0

    enum MeetingStatus {
        case idle
        case recording
        case transcribing
        case done(URL)
        case failed(String)
    }

    let settingsStore: SettingsStore

    private let recorder = AudioRecorder()
    private let meetingRecorder = MeetingRecorder()
    private let transcriptionService = TranscriptionService()
    private let audioSilenceDetector = AudioSilenceDetector()
    private let inputInserter = InputInserter()
    private let hotkeyManager: HotkeyManager
    private let localCalendarAccessService: LocalCalendarAccessService
    private let meetingContextProvider: MeetingContextProvider
    private var targetApplication: NSRunningApplication?
    private var isRecording = false
    private var isMeetingRecording = false
    private var liveMeetingTranscriptionTask: Task<Void, Never>?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let localCalendarAccessService = LocalCalendarAccessService()
        self.localCalendarAccessService = localCalendarAccessService
        self.meetingContextProvider = LocalCalendarMeetingContextProvider(
            accessService: localCalendarAccessService,
            selectedCalendarIdentifier: { [settingsStore] in
                await MainActor.run {
                    settingsStore.settings.selectedCalendarIdentifier
                }
            }
        )
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
            await self?.refreshCalendarAccessState()
        }
    }

    func adjustUtilityWindowZoom(by scale: CGFloat) {
        utilityWindowZoomScale = min(max(utilityWindowZoomScale * scale, 0.75), 1.8)
    }

    func startRecording() async {
        guard !isRecording else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication

        do {
            let format = settingsStore.settings.preferredDictationRecordingFormat
            try await recorder.startRecording(in: settingsStore.settings.recordingDirectory, format: format)
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

            guard await audioSilenceDetector.hasSpeech(audioURL: audioURL) else {
                applyRetentionPolicy(to: audioURL)
                status = .silentTranscriptIgnored
                scheduleStatusReset()
                return
            }

            let transcript = try await transcriptionService.transcribe(
                audioURL: audioURL,
                settings: settingsStore.settings,
                openAIAPIKey: settingsStore.openAIAPIKey
            )

            applyRetentionPolicy(to: audioURL)

            guard TranscriptPostProcessor.shouldInsert(transcript) else {
                status = .silentTranscriptIgnored
                scheduleStatusReset()
                return
            }

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

    func presentMeetingSetup() async {
        guard !isMeetingRecording, !isRecording else { return }
        isMeetingSetupPresented = true
        meetingContextLookupState = .loading

        let lookupState = await meetingContextProvider.fetchContext(
            for: meetingDraft,
            during: Date()
        )
        meetingContextLookupState = lookupState
        await refreshCalendarAccessState()

        if case .suggested(let suggestion) = lookupState {
            if meetingDraft.trimmedTitle.isEmpty {
                meetingDraft.title = suggestion.suggestedTitle ?? ""
            }
            meetingDraft.participants = suggestion.participants
        }
    }

    func cancelMeetingSetup() {
        isMeetingSetupPresented = false
    }

    func updateMeetingTitle(_ title: String) {
        meetingDraft.title = title
    }

    func updateMeetingDraftNotes(_ notes: String) {
        meetingDraft.personalNotes = notes
    }

    func updateActiveMeetingNotes(_ notes: String) {
        meetingDraft.personalNotes = notes
        activeMeetingSession?.personalNotes = notes
    }

    var canStartMeetingRecording: Bool {
        !meetingDraft.trimmedTitle.isEmpty && !isMeetingRecording && !isRecording
    }

    func startMeetingRecording() async {
        guard !isMeetingRecording, !isRecording else { return }
        let draft = meetingDraft
        let title = draft.trimmedTitle
        guard !title.isEmpty else { return }
        do {
            let url = try await meetingRecorder.start(in: settingsStore.settings.recordingDirectory)
            let session = ActiveMeetingSession(
                title: title,
                participants: draft.participants,
                personalNotes: draft.personalNotes,
                recordingStartedAt: Date(),
                audioURL: url
            )
            activeMeetingSession = session
            isMeetingRecording = true
            meetingStatus = .recording
            isMeetingSetupPresented = false
            startLiveMeetingTranscription()
        } catch {
            meetingStatus = .failed(error.localizedDescription)
        }
    }

    func stopMeetingRecordingAndTranscribe() async {
        guard isMeetingRecording, let session = activeMeetingSession else { return }
        isMeetingRecording = false
        stopLiveMeetingTranscription()
        meetingStatus = .transcribing

        do {
            let audioURL = try await meetingRecorder.stop()

            let transcript = try await transcriptionService.transcribe(
                audioURL: audioURL,
                settings: settingsStore.settings,
                openAIAPIKey: settingsStore.openAIAPIKey
            )

            let endedAt = Date()
            let bundle = RecordedMeetingBundle(
                title: session.title,
                participants: session.participants,
                personalNotes: session.personalNotes,
                personalNotesPriority: .higherThanTranscriptWhenConflictExists,
                transcript: transcript,
                recordingStartedAt: session.recordingStartedAt,
                recordingEndedAt: endedAt,
                audioFileName: audioURL.lastPathComponent,
                audioFilePath: audioURL.path
            )

            let bundleURL = audioURL.deletingPathExtension().appendingPathExtension("json")
            let notesURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            let jsonContent = try MeetingBundleFormatter.prettyJSONString(for: bundle)
            let textContent = MeetingBundleFormatter.humanReadableSummary(for: bundle) + "\n"
            try jsonContent.write(to: bundleURL, atomically: true, encoding: .utf8)
            try textContent.write(to: notesURL, atomically: true, encoding: .utf8)

            meetingStatus = .done(bundleURL)
            activeMeetingSession = nil
            meetingDraft = MeetingSessionDraft()
            liveMeetingTranscriptionStatus = ""
            meetingContextLookupState = .idle

            NSWorkspace.shared.activateFileViewerSelecting([bundleURL, notesURL])

        } catch {
            meetingStatus = .failed(error.localizedDescription)
        }
    }

    func resetMeetingStatus() {
        meetingStatus = .idle
        if !isMeetingRecording {
            activeMeetingSession = nil
            liveMeetingTranscript = ""
            liveMeetingTranscriptionStatus = ""
        }
    }

    var meetingTitle: String {
        activeMeetingSession?.title ?? meetingDraft.trimmedTitle
    }

    var meetingNotes: String {
        activeMeetingSession?.personalNotes ?? meetingDraft.personalNotes
    }

    var meetingParticipants: [MeetingParticipant] {
        let sessionParticipants = activeMeetingSession?.participants ?? []
        return sessionParticipants.isEmpty ? meetingDraft.participants : sessionParticipants
    }

    func requestCalendarAccess() async {
        calendarAccessState = .requesting
        calendarAccessState = await localCalendarAccessService.requestAccess()
        await refreshAvailableCalendars()
    }

    func refreshCalendarAccessState() async {
        calendarAccessState = await localCalendarAccessService.accessState()
        await refreshAvailableCalendars()
    }

    func selectCalendar(_ calendarIdentifier: String) {
        settingsStore.settings.selectedCalendarIdentifier = calendarIdentifier
    }

    func refreshAvailableCalendars() async {
        availableCalendars = await localCalendarAccessService.availableCalendars()
        let selected = settingsStore.settings.selectedCalendarIdentifier
        if !selected.isEmpty,
           !availableCalendars.contains(where: { $0.id == selected }) {
            settingsStore.settings.selectedCalendarIdentifier = ""
        }
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
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        for file in files {
            let values = try? file.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isRegularFileKey
            ])
            guard values?.isRegularFile == true else { continue }

            if RecordingRetentionPolicy.shouldPurge(
                fileName: file.lastPathComponent,
                creationDate: values?.creationDate,
                contentModificationDate: values?.contentModificationDate,
                now: now,
                maxAge: maxAge
            ) {
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

    private func startLiveMeetingTranscription() {
        stopLiveMeetingTranscription()
        liveMeetingTranscript = ""
        liveMeetingTranscriptionStatus = "Live transcription starts after the first 10-second chunk."

        liveMeetingTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var chunkStart: TimeInterval = 0
            let chunkDuration = MeetingLiveTranscriptionSupport.chunkDuration

            while !Task.isCancelled && self.isMeetingRecording {
                try? await Task.sleep(for: .seconds(chunkDuration))
                guard !Task.isCancelled && self.isMeetingRecording else { break }

                self.liveMeetingTranscriptionStatus = "Transcribing latest 10-second chunk…"

                do {
                    guard let chunkURL = try await self.meetingRecorder.exportMicChunk(
                        startTime: chunkStart,
                        duration: chunkDuration
                    ) else {
                        self.liveMeetingTranscriptionStatus = "Waiting for enough audio for the next chunk…"
                        continue
                    }
                    chunkStart += chunkDuration

                    defer { try? FileManager.default.removeItem(at: chunkURL) }

                    guard await self.audioSilenceDetector.hasSpeech(audioURL: chunkURL) else {
                        guard !Task.isCancelled && self.isMeetingRecording else { break }
                        self.liveMeetingTranscriptionStatus = "Last chunk was silent."
                        continue
                    }

                    let transcript = try await self.transcriptionService.transcribe(
                        audioURL: chunkURL,
                        settings: self.settingsStore.settings,
                        openAIAPIKey: self.settingsStore.openAIAPIKey
                    )
                    guard !Task.isCancelled && self.isMeetingRecording else { break }

                    if TranscriptPostProcessor.shouldInsert(transcript) {
                        self.liveMeetingTranscript = MeetingLiveTranscriptionSupport.appendedTranscript(
                            existing: self.liveMeetingTranscript,
                            newText: transcript
                        )
                        self.liveMeetingTranscriptionStatus = "Live transcript updated."
                    } else {
                        self.liveMeetingTranscriptionStatus = "Last chunk did not contain usable speech."
                    }
                } catch {
                    self.liveMeetingTranscriptionStatus = "Live transcription skipped a chunk: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopLiveMeetingTranscription() {
        liveMeetingTranscriptionTask?.cancel()
        liveMeetingTranscriptionTask = nil
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
