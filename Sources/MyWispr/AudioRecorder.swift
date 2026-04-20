import AVFoundation
import Foundation

enum RecordingError: Error, LocalizedError {
    case microphoneDenied
    case recorderCreationFailed
    case outputMissing
    case directoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access was denied."
        case .recorderCreationFailed:
            return "Unable to start the microphone recorder."
        case .outputMissing:
            return "The recording stopped without creating an audio file."
        case .directoryCreationFailed(let path):
            return "Could not create recordings directory at \(path)."
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func startRecording(in directory: String) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw RecordingError.microphoneDenied
        }

        let dir = resolvedURL(for: directory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw RecordingError.directoryCreationFailed(dir.path)
        }

        let filename = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent(filename).appendingPathExtension("m4a")

        let config: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: config)
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw RecordingError.recorderCreationFailed
        }

        self.recorder = recorder
        self.outputURL = url
    }

    func stopRecording() throws -> URL {
        recorder?.stop()
        recorder = nil

        guard let outputURL, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecordingError.outputMissing
        }

        self.outputURL = nil
        return outputURL
    }

    private func resolvedURL(for path: String) -> URL {
        if path.hasPrefix("~") {
            let expanded = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: path)
    }
}
