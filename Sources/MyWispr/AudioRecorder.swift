import AVFoundation
import Foundation

enum RecordingError: Error, LocalizedError {
    case microphoneDenied
    case recorderCreationFailed
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access was denied."
        case .recorderCreationFailed:
            return "Unable to start the microphone recorder."
        case .outputMissing:
            return "The recording stopped without creating an audio file."
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func startRecording() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw RecordingError.microphoneDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

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
}
