import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var recordingSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?

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

            Divider()

            actionButtons
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: model.status) { _, newStatus in
            handleStatusChange(newStatus)
        }
        .onDisappear {
            timerTask?.cancel()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("MyWispr")
                .font(.headline)
            Spacer()
            Text(settingsStore.settings.shortcut.displayText)
                .font(.caption)
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
                    .fontWeight(.medium)

                if model.status == .recording {
                    Text(formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if case .failed(let message) = model.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .succeeded(let message) = model.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(settingsStore.settings.recordingMode.title)
                        .font(.caption)
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
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.lastTranscript)
                    .font(.caption)
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
                        .font(.subheadline)
                        .fontWeight(.medium)
                    meetingStatusLabel
                }
                Spacer()
                meetingButton
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
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording(let name):
            Text(name)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        case .transcribing:
            Text("Transcribing meeting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done(let url):
            Text("Notes saved — \(url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
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
                Task { await model.startMeetingRecording() }
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

            Button("Settings…") { openSettings() }
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
}
