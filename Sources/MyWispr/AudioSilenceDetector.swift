import AVFoundation
import Foundation
import MyWisprCore

struct AudioSilenceDetector {
    func hasSpeech(audioURL: URL) async -> Bool {
        do {
            let metrics = try await audioMetrics(audioURL: audioURL)
            return AudioSilencePolicy.hasSpeech(
                duration: metrics.duration,
                rootMeanSquare: metrics.rootMeanSquare,
                peakAmplitude: metrics.peakAmplitude
            )
        } catch {
            return true
        }
    }

    private func audioMetrics(audioURL: URL) async throws -> (duration: TimeInterval, rootMeanSquare: Double, peakAmplitude: Double) {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: audioURL)
            let format = file.processingFormat
            let duration = Double(file.length) / format.sampleRate

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                return (duration, 1.0, 1.0)
            }

            var sumSquares = 0.0
            var sampleCount = 0
            var peak = 0.0

            while file.framePosition < file.length {
                try file.read(into: buffer)
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0, let channelData = buffer.floatChannelData else { break }

                let channelCount = Int(format.channelCount)
                for channelIndex in 0..<channelCount {
                    let samples = channelData[channelIndex]
                    for frameIndex in 0..<frameLength {
                        let value = Double(samples[frameIndex])
                        let absoluteValue = abs(value)
                        peak = max(peak, absoluteValue)
                        sumSquares += value * value
                        sampleCount += 1
                    }
                }
            }

            guard sampleCount > 0 else {
                return (duration, 0.0, 0.0)
            }

            return (duration, sqrt(sumSquares / Double(sampleCount)), peak)
        }.value
    }
}
