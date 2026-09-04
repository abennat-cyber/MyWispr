import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
actor AppleSpeechService {
    enum AppleSpeechError: Error, LocalizedError {
        case unavailable
        case notAuthorized
        case unsupportedLocale(String)
        case unsupportedAudioFormat
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple on-device speech transcription is unavailable on this Mac."
            case .notAuthorized:
                return "MyWispr needs Speech Recognition access. Enable it in System Settings › Privacy & Security › Speech Recognition."
            case .unsupportedLocale(let locale):
                return "Apple on-device speech transcription does not support \(locale)."
            case .unsupportedAudioFormat:
                return "Apple Speech could not determine a compatible audio format."
            case .emptyTranscript:
                return "Apple Speech completed but returned no text."
            }
        }
    }

    func transcribe(audioURL: URL, locale: Locale, vocabulary: [String]) async throws -> String {
        guard await SpeechRecognitionAuthorization.isAuthorized() else {
            throw AppleSpeechError.notAuthorized
        }

        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unavailable
        }

        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        try await ensureModelInstalled(for: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(context)
        }

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.unsupportedAudioFormat
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let resultTask = Task<String, Error> {
            var finalized = ""
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                finalized += String(result.text.characters)
            }
            return finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        try await analyzer.start(inputSequence: inputStream)

        do {
            try feedAudioFile(audioURL, targetFormat: targetFormat, continuation: continuation)
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            throw error
        }

        let transcript = try await resultTask.value
        guard !transcript.isEmpty else {
            throw AppleSpeechError.emptyTranscript
        }
        return transcript
    }

    private func feedAudioFile(
        _ audioURL: URL,
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let file = try AVAudioFile(forReading: audioURL)
        let sourceFormat = file.processingFormat
        let frameCapacity: AVAudioFrameCount = 4_096

        if formatsAreEquivalent(sourceFormat, targetFormat) {
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
                    throw AppleSpeechError.unsupportedAudioFormat
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            return
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AppleSpeechError.unsupportedAudioFormat
        }

        while file.framePosition < file.length {
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
                throw AppleSpeechError.unsupportedAudioFormat
            }
            try file.read(into: inputBuffer)
            guard inputBuffer.frameLength > 0 else { break }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputCapacity = max(
                AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256,
                256
            )
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw AppleSpeechError.unsupportedAudioFormat
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                if outputBuffer.frameLength > 0 {
                    continuation.yield(AnalyzerInput(buffer: outputBuffer))
                }
            case .error:
                throw AppleSpeechError.unsupportedAudioFormat
            @unknown default:
                throw AppleSpeechError.unsupportedAudioFormat
            }
        }
    }

    private func formatsAreEquivalent(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let selected = transcriber.selectedLocales
        let alreadyInstalled = selected.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard !alreadyInstalled else { return }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}
