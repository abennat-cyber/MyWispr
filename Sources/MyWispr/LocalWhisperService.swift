import Foundation

enum LocalWhisperError: Error, LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String, String)
    case conversionFailed(String)
    case commandFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "whisper-cli not found at \(path). Install with: brew install whisper-cpp"
        case .modelNotFound(let file, let dir):
            return "Model file '\(file)' not found in \(dir). See Settings for the download command."
        case .conversionFailed(let detail):
            return "Audio conversion to WAV failed: \(detail)"
        case .commandFailed(let details):
            return details
        case .emptyOutput:
            return "whisper-cli produced no transcript output."
        }
    }
}

struct LocalWhisperService {
    static func resolveBinaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func resolveModelPath(model: LocalWhisperModel, modelDir: String) -> String {
        let expanded = modelDir.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + modelDir.dropFirst()
            : modelDir
        return (expanded as NSString).appendingPathComponent(model.filename)
    }

    /// Default model directory used across the app.
    static let defaultModelDir = "~/.local/share/whisper/models"

    /// Returns true if the medium model exists in the default directory.
    static var mediumModelReady: Bool {
        let path = resolveModelPath(model: .medium, modelDir: defaultModelDir)
        return FileManager.default.fileExists(atPath: path)
    }

    /// Full path to the medium model file.
    static var mediumModelPath: String {
        resolveModelPath(model: .medium, modelDir: defaultModelDir)
    }

    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String {
        guard let binaryPath = Self.resolveBinaryPath() else {
            throw LocalWhisperError.binaryNotFound("/opt/homebrew/bin/whisper-cli")
        }

        let modelPath = Self.resolveModelPath(
            model: settings.localWhisperModel,
            modelDir: settings.localWhisperModelDir
        )
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LocalWhisperError.modelNotFound(
                settings.localWhisperModel.filename,
                settings.localWhisperModelDir
            )
        }

        // whisper-cli only accepts flac/mp3/ogg/wav — convert m4a → wav first
        let wavURL = try await convertToWAV(audioURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        var args = [
            "--model", modelPath,
            "--language", settings.effectiveLanguageArg,
            "--no-prints",
            "--output-txt",
            "--output-file", wavURL.deletingPathExtension().path,
        ]
        // Pass a combined prompt for multi-language biasing and/or custom vocabulary.
        if let prompt = settings.fullPrompt {
            args += ["--prompt", prompt]
        }
        args.append(wavURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        let stderr = Pipe()
        process.standardError = stderr

        try await runProcess(process)

        // whisper-cli appends .txt to the --output-file path
        let txtURL = wavURL.deletingPathExtension().appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }

        if process.terminationStatus != 0 {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = errOutput.isEmpty
                ? "whisper-cli exited with code \(process.terminationStatus)"
                : errOutput
            throw LocalWhisperError.commandFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let raw = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
        let transcript = normalizeTranscript(raw)

        guard !transcript.isEmpty else {
            throw LocalWhisperError.emptyOutput
        }

        return transcript
    }

    // Cleans whisper-cli .txt output:
    // - Removes [BLANK_AUDIO] and timestamp tags like [00:00:00.000 --> 00:00:05.000]
    // - Strips leading/trailing whitespace from each line (whisper prepends a space token)
    // - Joins non-empty lines with a single space to form a clean paragraph
    private func normalizeTranscript(_ raw: String) -> String {
        let timestampPattern = #"\[\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}\]"#
        let lines = raw.components(separatedBy: "\n").compactMap { line -> String? in
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { return nil }
            if l == "[BLANK_AUDIO]" { return nil }
            // Strip timestamp lines
            if l.range(of: timestampPattern, options: .regularExpression) != nil { return nil }
            return l
        }
        return lines.joined(separator: " ")
    }

    // Uses afconvert (built-in macOS) to convert m4a → 16kHz mono WAV,
    // which is what whisper models expect.
    private func convertToWAV(_ inputURL: URL) async throws -> URL {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            inputURL.path,
            wavURL.path,
            "-d", "LEI16@16000",  // 16-bit little-endian PCM at 16 kHz
            "-c", "1",            // mono
            "-f", "WAVE"
        ]

        let stderr = Pipe()
        process.standardError = stderr

        try await runProcess(process)

        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LocalWhisperError.conversionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return wavURL
    }
}
