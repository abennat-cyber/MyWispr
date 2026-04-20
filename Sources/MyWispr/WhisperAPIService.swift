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

        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw WhisperAPIError.audioReadFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        body.appendFormField(name: "model", value: model, boundary: boundary)
        body.appendFormField(name: "response_format", value: "json", boundary: boundary)
        // Omit the language field when set to auto; the API auto-detects.
        if languageArg != "auto" {
            body.appendFormField(name: "language", value: languageArg, boundary: boundary)
        }
        // Inject vocabulary/language prompt to prime the decoder.
        if let prompt {
            body.appendFormField(name: "prompt", value: prompt, boundary: boundary)
        }
        body.appendFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: "audio/m4a",
            data: audioData,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

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
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data fileData: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}
