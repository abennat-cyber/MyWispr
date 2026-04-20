import Foundation

enum TranscriptionError: Error, LocalizedError {
    case missingCommand
    case commandFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "No transcription command is configured."
        case .commandFailed(let details):
            return details
        case .emptyOutput:
            return "The transcription command completed but returned no text."
        }
    }
}

struct TranscriptionService {
    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String {
        let template: String
        switch settings.selectedEngine {
        case .codexCLI:
            template = settings.codexCommandTemplate
        case .customCommand:
            template = settings.customCommandTemplate
        }

        let command = template
            .replacingOccurrences(of: "{audio_path}", with: shellQuoted(audioURL.path))
            .replacingOccurrences(of: "{model}", with: settings.codexModel)
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

        try process.run()
        process.waitUntilExit()

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
