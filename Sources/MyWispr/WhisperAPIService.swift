import Foundation

enum WhisperAPIError: Error, LocalizedError {
    case missingAPIKey
    case audioReadFailed
    case httpError(Int, String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key is configured. Add one in Settings → Transcription."
        case .audioReadFailed:
            return "Could not read the recorded audio file."
        case .httpError(let code, let body):
            return "Whisper API returned \(code): \(body)"
        case .decodingFailed:
            return "Could not decode the Whisper API response."
        }
    }
}

struct WhisperAPIService {
    private struct Response: Decodable {
        let text: String
    }

    func transcribe(audioURL: URL, apiKey: String, model: String, languageArg: String, prompt: String? = nil) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WhisperAPIError.missingAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let bodyURL = try multipartBodyFile(
            audioURL: audioURL,
            boundary: boundary,
            model: model,
            languageArg: languageArg,
            prompt: prompt
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WhisperAPIError.httpError(http.statusCode, body)
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw WhisperAPIError.decodingFailed
        }

        // Whisper API can return multi-line text with leading spaces per line.
        let transcript = decoded.text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return transcript
    }

    private func multipartBodyFile(
        audioURL: URL,
        boundary: String,
        model: String,
        languageArg: String,
        prompt: String?
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("multipart")

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw WhisperAPIError.audioReadFailed
        }

        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }

            try output.writeUTF8FormField(name: "model", value: model, boundary: boundary)
            try output.writeUTF8FormField(name: "response_format", value: "json", boundary: boundary)
            if languageArg != "auto" {
                try output.writeUTF8FormField(name: "language", value: languageArg, boundary: boundary)
            }
            if let prompt {
                try output.writeUTF8FormField(name: "prompt", value: prompt, boundary: boundary)
            }
            try output.writeFilePart(
                name: "file",
                filename: audioURL.lastPathComponent,
                mimeType: mimeType(for: audioURL),
                fileURL: audioURL,
                boundary: boundary
            )
            try output.writeUTF8("--\(boundary)--\r\n")
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw WhisperAPIError.audioReadFailed
        }

        return bodyURL
    }

    private func mimeType(for audioURL: URL) -> String {
        switch audioURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "ogg":
            return "audio/ogg"
        default:
            return "audio/m4a"
        }
    }
}

private extension FileHandle {
    func writeUTF8(_ string: String) throws {
        try write(contentsOf: Data(string.utf8))
    }

    func writeUTF8FormField(name: String, value: String, boundary: String) throws {
        try writeUTF8("--\(boundary)\r\n")
        try writeUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        try writeUTF8("\(value)\r\n")
    }

    func writeFilePart(name: String, filename: String, mimeType: String, fileURL: URL, boundary: String) throws {
        try writeUTF8("--\(boundary)\r\n")
        try writeUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        try writeUTF8("Content-Type: \(mimeType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        while true {
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            try write(contentsOf: data)
        }

        try writeUTF8("\r\n")
    }
}
