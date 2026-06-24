import AVFoundation
import ApplicationServices
import SwiftUI

/// Shown on first launch (or whenever prerequisites are not met).
struct OnboardingView: View {
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()
    @State private var whisperInstalled: Bool = LocalWhisperService.resolveBinaryPath() != nil
    @State private var modelReady: Bool = LocalWhisperService.mediumModelReady
    @State private var downloadState: DownloadState = .idle
    @State private var checkTimer: Timer?

    enum DownloadState {
        case idle, downloading(Double), done, failed(String)
    }

    var allMet: Bool {
        micStatus == .authorized && whisperInstalled && modelReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            VStack(alignment: .leading, spacing: 16) {
                micRow
                accessibilityRow
                whisperRow
                if whisperInstalled {
                    modelRow
                }
            }

            footer
        }
        .padding(28)
        .frame(width: 520)
        .onAppear { startPolling() }
        .onDisappear { checkTimer?.invalidate() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to MyWispr")
                .font(.title2).fontWeight(.bold)
            Text("Complete the steps below to start dictating.")
                .foregroundStyle(.secondary)
        }
    }

    private var micRow: some View {
        requirementRow(
            icon: "mic.fill", color: .blue,
            title: "Microphone Access",
            description: micStatus == .authorized
                ? "Granted — MyWispr can record audio."
                : "Required to record your voice.",
            status: micStatus == .authorized ? .done : .action,
            buttonTitle: micStatus == .notDetermined ? "Grant Access"
                : micStatus == .authorized ? nil : "Open Settings",
            action: requestMic
        )
    }

    private var accessibilityRow: some View {
        requirementRow(
            icon: "accessibility", color: .purple,
            title: "Accessibility (optional)",
            description: accessibilityGranted
                ? "Granted — text will be typed directly into apps."
                : "Without this, transcripts are copied to your clipboard instead.",
            status: accessibilityGranted ? .done : .optional,
            buttonTitle: accessibilityGranted ? nil : "Open Settings",
            action: openAccessibility
        )
    }

    private var whisperRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            requirementRow(
                icon: "waveform", color: .orange,
                title: "whisper-cli",
                description: whisperInstalled
                    ? "Found — local transcription engine is ready."
                    : "Install via Homebrew for free on-device transcription.",
                status: whisperInstalled ? .done : .action,
                buttonTitle: nil, action: {}
            )
            if !whisperInstalled {
                codeBlock("brew install whisper-cpp")
                    .padding(.leading, 48)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "brain")
                        .foregroundStyle(.green)
                        .imageScale(.medium)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Whisper Medium Model").fontWeight(.medium)
                        switch downloadState {
                        case .done where modelReady:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .idle where modelReady:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .downloading:
                            EmptyView()
                        default:
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        }
                    }

                    Group {
                        switch downloadState {
                        case .idle where modelReady:
                            Text("Ready — higher-accuracy transcription enabled.")
                        case .idle:
                            Text("~1.5 GB download. Recommended for best accuracy across all languages.")
                        case .downloading(let progress):
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: progress)
                                    .frame(width: 260)
                                Text("Downloading… \(Int(progress * 100))%")
                            }
                        case .done:
                            Text("Download complete.")
                        case .failed(let msg):
                            Text("Failed: \(msg)").foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if !modelReady {
                    switch downloadState {
                    case .idle, .failed:
                        Button("Download") { startModelDownload() }
                            .controlSize(.small)
                    case .downloading:
                        Button("Cancel") { cancelDownload() }
                            .controlSize(.small)
                    case .done:
                        EmptyView()
                    }
                }
            }

            if !modelReady, case .idle = downloadState {
                Text("Or run manually:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                codeBlock(
                    "curl -L --progress-bar -o ~/.local/share/whisper/models/ggml-medium.bin \\\n  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
                )
                .padding(.leading, 48)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if !allMet {
                Button("Continue without model") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button(allMet ? "Get Started" : "Continue anyway") { finish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(isDownloading)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    // MARK: - Download

    private func startModelDownload() {
        let dir = LocalWhisperService.resolveModelPath(
            model: .medium, modelDir: LocalWhisperService.defaultModelDir
        )
        let destDir = URL(fileURLWithPath: dir).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!
        let destPath = LocalWhisperService.mediumModelPath

        downloadState = .downloading(0)

        Task {
            do {
                try await downloadWithProgress(from: url, to: URL(fileURLWithPath: destPath))
                await MainActor.run {
                    downloadState = .done
                    modelReady = true
                }
            } catch {
                await MainActor.run {
                    downloadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func cancelDownload() {
        // Cancellation is handled by task cancellation; reset state
        downloadState = .idle
    }

    private func downloadWithProgress(from url: URL, to dest: URL) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength

        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 1_600_000_000)

        var received: Int64 = 0
        for try await byte in asyncBytes {
            data.append(byte)
            received += 1
            if received % 1_048_576 == 0 { // update every 1 MB
                let progress = total > 0 ? Double(received) / Double(total) : 0
                let p = progress
                await MainActor.run { downloadState = .downloading(p) }
            }
        }

        try data.write(to: dest)
    }

    // MARK: - Actions

    private func requestMic() {
        if micStatus == .notDetermined {
            Task {
                await AVCaptureDevice.requestAccess(for: .audio)
                await MainActor.run {
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
        }
    }

    private func openAccessibility() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        NSApp.windows.first(where: { $0.title == "Setup" })?.close()
    }

    private func startPolling() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let newMic = AVCaptureDevice.authorizationStatus(for: .audio)
                let newAX = AXIsProcessTrusted()
                let newWhisper = LocalWhisperService.resolveBinaryPath() != nil
                let newModel = LocalWhisperService.mediumModelReady
                let axChanged = !accessibilityGranted && newAX

                micStatus = newMic
                accessibilityGranted = newAX
                whisperInstalled = newWhisper
                if newModel && !modelReady { modelReady = true }

                if axChanged { restartApp() }
            }
        }
    }

    // MARK: - Helpers

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
    }
}

// MARK: - Restart

@MainActor
func restartApp() {
    let url = Bundle.main.bundleURL
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = [url.path]
    try? task.run()
    NSApp.terminate(nil)
}

// MARK: - Row helpers

private enum RequirementStatus { case done, action, optional }

private struct requirementRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    let status: RequirementStatus
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .imageScale(.medium)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    switch status {
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .action:
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    case .optional:
                        Text("optional").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}
