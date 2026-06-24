import SwiftUI
import MyWisprCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var recordingSeconds: Int = 0
    @State private var meetingRecordingSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var meetingTimerTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            statusSection

            if !model.lastTranscript.isEmpty {
                Divider()
                lastTranscriptSection
            }

            Divider()

            meetingSection
                .layoutPriority(1)

            Divider()

            actionButtons
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.status) { _, newStatus in
            handleStatusChange(newStatus)
        }
        .onChange(of: meetingStatusKey) { _, newStatus in
            handleMeetingStatusChange(newStatus)
        }
        .onDisappear {
            timerTask?.cancel()
            meetingTimerTask?.cancel()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("MyWispr")
                .font(scaledFont(17, weight: .semibold))
            Spacer()
            Text(settingsStore.settings.shortcut.displayText)
                .font(scaledFont(11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 8) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.title)
                    .font(scaledFont(13))
                    .fontWeight(.medium)

                if model.status == .recording {
                    Text(formattedDuration)
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if case .failed(let message) = model.status {
                    Text(message)
                        .font(scaledFont(12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .succeeded(let message) = model.status {
                    Text(message)
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(settingsStore.settings.recordingMode.title)
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        ZStack {
            switch model.status {
            case .idle:
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(.red.opacity(0.4), lineWidth: 4)
                            .scaleEffect(1.5)
                    )
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.7)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var lastTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last transcript")
                .font(scaledFont(12))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.lastTranscript)
                    .font(scaledFont(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
        }
    }

    // MARK: - Meeting recording

    @ViewBuilder
    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                meetingStatusIndicator
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record Meeting")
                        .font(scaledFont(13))
                        .fontWeight(.medium)
                    meetingStatusLabel
                }
                Spacer()
                meetingButton
            }

            if case .recording = model.meetingStatus {
                MeetingNotesEditorView(model: model, durationText: formattedMeetingDuration)
            }
        }
    }

    @ViewBuilder
    private var meetingStatusIndicator: some View {
        ZStack {
            switch model.meetingStatus {
            case .idle:
                Image(systemName: "person.2.wave.2")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            case .recording:
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.orange.opacity(0.4), lineWidth: 4).scaleEffect(1.5))
            case .transcribing:
                ProgressView().scaleEffect(0.6)
            case .done:
                Image(systemName: "doc.text.fill").foregroundStyle(.green).imageScale(.small)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).imageScale(.small)
            }
        }
        .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var meetingStatusLabel: some View {
        switch model.meetingStatus {
        case .idle:
            Text("Mic + system audio")
                .font(scaledFont(12))
                .foregroundStyle(.secondary)
        case .recording:
            Text(model.meetingTitle.isEmpty ? "Recording meeting…" : model.meetingTitle)
                .font(scaledFont(12))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        case .transcribing:
            Text("Transcribing meeting…")
                .font(scaledFont(12))
                .foregroundStyle(.secondary)
        case .done(let url):
            Text("Notes saved — \(url.lastPathComponent)")
                .font(scaledFont(12))
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let msg):
            Text(msg)
                .font(scaledFont(12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var meetingButton: some View {
        switch model.meetingStatus {
        case .recording:
            Button("Stop") {
                Task { await model.stopMeetingRecordingAndTranscribe() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
        case .transcribing:
            EmptyView()
        case .done:
            Button("Dismiss") { model.resetMeetingStatus() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        case .failed:
            Button("Dismiss") { model.resetMeetingStatus() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        case .idle:
            Button("Start") {
                AppDelegate.showMeetingSetupWindow()
                Task { await model.presentMeetingSetup() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            Button(model.status == .recording ? "Stop" : "Record") {
                Task {
                    if model.status == .recording {
                        await model.stopRecordingAndTranscribe()
                    } else {
                        await model.startRecording()
                    }
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.status == .transcribing)

            Spacer()

            Button("Settings…") { AppDelegate.showSettingsWindow() }
                .buttonStyle(.borderless)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private var formattedDuration: String {
        let minutes = recordingSeconds / 60
        let seconds = recordingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var formattedMeetingDuration: String {
        let minutes = meetingRecordingSeconds / 60
        let seconds = meetingRecordingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var meetingStatusKey: String {
        switch model.meetingStatus {
        case .idle:
            return "idle"
        case .recording:
            return "recording"
        case .transcribing:
            return "transcribing"
        case .done:
            return "done"
        case .failed:
            return "failed"
        }
    }

    private func scaledFont(_ baseSize: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: baseSize * model.utilityWindowZoomScale, weight: weight)
    }

    private func handleStatusChange(_ status: AppStatus) {
        timerTask?.cancel()
        timerTask = nil

        if status == .recording {
            recordingSeconds = 0
            timerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled {
                        recordingSeconds += 1
                    }
                }
            }
        }
    }

    private func handleMeetingStatusChange(_ status: String) {
        meetingTimerTask?.cancel()
        meetingTimerTask = nil

        if status == "recording" {
            meetingRecordingSeconds = 0
            meetingTimerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled {
                        meetingRecordingSeconds += 1
                    }
                }
            }
        }
    }
}

struct MeetingSetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record Meeting")
                .font(scaledFont(17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Meeting title")
                    .font(scaledFont(13))
                    .fontWeight(.medium)
                TextField("Q2 roadmap sync", text: titleBinding)
                    .font(scaledFont(13))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Participants")
                    .font(scaledFont(13))
                    .fontWeight(.medium)
                MeetingParticipantsView(state: model.meetingContextLookupState, zoomScale: zoomScale)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Personal notes")
                    .font(scaledFont(13))
                    .fontWeight(.medium)
                Text("These notes will be sent alongside the transcript and should be treated as higher-priority context for MoM generation.")
                    .font(scaledFont(12))
                    .foregroundStyle(.secondary)
                TextEditor(text: notesBinding)
                    .font(scaledFont(14))
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }

            HStack {
                Button("Cancel") {
                    model.cancelMeetingSetup()
                    AppDelegate.closeMeetingSetupWindow()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Start Recording") {
                    Task {
                        await model.startMeetingRecording()
                        AppDelegate.closeMeetingSetupWindow()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStartMeetingRecording)
            }
        }
        .padding(18)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 430, maxHeight: .infinity)
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.meetingDraft.title },
            set: { model.updateMeetingTitle($0) }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { model.meetingDraft.personalNotes },
            set: { model.updateMeetingDraftNotes($0) }
        )
    }

    private var zoomScale: CGFloat {
        model.utilityWindowZoomScale
    }

    private func scaledFont(_ baseSize: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: baseSize * zoomScale, weight: weight)
    }
}

private struct MeetingParticipantsView: View {
    let state: MeetingContextLookupState
    let zoomScale: CGFloat

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking up Apple Calendar event…")
                    .font(scaledFont(12))
                    .foregroundStyle(.secondary)
            }
        case .suggested(let suggestion):
            VStack(alignment: .leading, spacing: 4) {
                if let message = state.message {
                    Text(message)
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                }

                if suggestion.participants.isEmpty {
                    Text("The matched event has no accepted or tentative human attendees.")
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestion.participants, id: \.self) { participant in
                        Text(participant.formattedValue)
                            .font(scaledFont(12))
                    }
                }
            }
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar autofill unavailable")
                    .font(scaledFont(12))
                    .fontWeight(.medium)
                Text(message)
                    .font(scaledFont(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scaledFont(_ baseSize: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: baseSize * zoomScale, weight: weight)
    }
}

private struct MeetingNotesEditorView: View {
    @ObservedObject var model: AppModel
    let durationText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Personal notes")
                    .font(scaledFont(12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(durationText)
                    .font(scaledFont(10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            TextEditor(text: notesBinding)
                .font(scaledFont(13))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 88, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.25))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Live transcript preview")
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("10 sec chunks")
                        .font(scaledFont(10))
                        .foregroundStyle(.secondary)
                }

                if model.liveMeetingTranscript.isEmpty {
                    Text(model.liveMeetingTranscriptionStatus)
                        .font(scaledFont(12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.18))
                        )
                } else {
                    ScrollView {
                        Text(model.liveMeetingTranscript)
                            .font(scaledFont(12))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 96, maxHeight: .infinity)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.18))
                    )

                    if !model.liveMeetingTranscriptionStatus.isEmpty {
                        Text(model.liveMeetingTranscriptionStatus)
                            .font(scaledFont(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { model.meetingNotes },
            set: { model.updateActiveMeetingNotes($0) }
        )
    }

    private func scaledFont(_ baseSize: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: baseSize * model.utilityWindowZoomScale, weight: weight)
    }
}
