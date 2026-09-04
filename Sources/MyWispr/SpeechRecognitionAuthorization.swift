import Foundation
import Speech

/// TCC terminates the process the first time it touches the Speech framework unless the
/// executable declares `NSSpeechRecognitionUsageDescription` *and* holds speech-recognition
/// authorization, so every Speech entry point has to clear this gate first.
enum SpeechRecognitionAuthorization {
    static func isAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
