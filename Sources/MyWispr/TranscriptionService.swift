import Foundation

enum TranscriptionError: Error, LocalizedError {
    case missingCommand
    case commandFailed(String)
    case emptyOutput
    case appleSpeechRequiresMacOS26

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "No transcription command is configured."
        case .commandFailed(let details):
            return details
        case .emptyOutput:
            return "The transcription command completed but returned no text."
        case .appleSpeechRequiresMacOS26:
            return "Apple Speech requires macOS 26 or later. Select Local Whisper for older macOS versions."
        }
    }
}

struct TranscriptionService {
    private let whisperAPI = WhisperAPIService()
    private let localWhisper = LocalWhisperService()

    func transcribe(audioURL: URL, settings: AppSettings, openAIAPIKey: String) async throws -> String {
        switch settings.selectedEngine {
        case .appleSpeech:
            guard #available(macOS 26.0, *) else {
                throw TranscriptionError.appleSpeechRequiresMacOS26
            }
            let locale = settings.singleSelectedTranscriptionLanguage
                .map { Locale(identifier: $0.whisperCode) }
                ?? Locale.current
            return try await AppleSpeechService().transcribe(
                audioURL: audioURL,
                locale: locale,
                vocabulary: settings.customVocabulary
            )
        case .localWhisper:
            return try await localWhisper.transcribe(audioURL: audioURL, settings: settings)
        case .whisperAPI:
            return try await whisperAPI.transcribe(
                audioURL: audioURL,
                apiKey: openAIAPIKey,
                model: settings.whisperModel,
                languageArg: settings.effectiveLanguageArg,
                prompt: settings.whisperAPIPrompt
            )
        case .customCommand:
            return try await runShellCommand(
                template: settings.customCommandTemplate,
                audioURL: audioURL
            )
        }
    }

    private func runShellCommand(template: String, audioURL: URL) async throws -> String {
        let command = template
            .replacingOccurrences(of: "{audio_path}", with: shellQuoted(audioURL.path))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !command.isEmpty else {
            throw TranscriptionError.missingCommand
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try await runProcess(process)

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errors.isEmpty ? "Transcription command failed." : errors
            throw TranscriptionError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let transcript = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw TranscriptionError.emptyOutput
        }

        return transcript
    }

    private func shellQuoted(_ input: String) -> String {
        "'" + input.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
