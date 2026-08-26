import AppKit
import AVFoundation
import Combine
import Foundation
import Speech
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class LiveDictationSession {
    static let shared = LiveDictationSession()

    private let hudState = LiveDictationHUDState()
    private lazy var hudPanel = LiveDictationHUDPanel(state: hudState)
    private let capture = LiveAudioCapture()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var finalizedText = ""
    private var isRunning = false

    private init() {}

    func start(locale: Locale = .current, vocabulary: [String] = []) async throws {
        guard !isRunning else { return }
        guard SpeechTranscriber.isAvailable else { return }
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }

        hudState.transcript = ""
        hudState.level = 0
        hudState.isListening = false
        hudState.statusText = "Preparing live transcription…"
        hudPanel.present()

        do {
            let transcriber = SpeechTranscriber(
                locale: resolvedLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            try await ensureModelInstalled(for: transcriber)
            try Task.checkCancellation()

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(vocabulary.prefix(100))
                try? await analyzer.setContext(context)
            }

            guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw LiveDictationError.unsupportedAudioFormat
            }

            let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            finalizedText = ""
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputContinuation = continuation

            resultTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.finalizedText += text
                            self.hudState.transcript = self.finalizedText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            self.hudState.transcript = (self.finalizedText + text)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                } catch {
                    if self.isRunning {
                        self.hudState.statusText = "Live preview unavailable"
                    }
                }
            }

            try await analyzer.start(inputSequence: inputStream)
            try Task.checkCancellation()

            try capture.start(
                outputFormat: targetFormat,
                onBuffer: { chunk in
                    continuation.yield(AnalyzerInput(buffer: chunk.buffer))
                },
                onLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.hudState.level = level
                    }
                }
            )

            isRunning = true
            hudState.isListening = true
            hudState.statusText = "Listening…"
        } catch {
            capture.stop()
            inputContinuation?.finish()
            inputContinuation = nil
            await analyzer?.cancelAndFinishNow()
            reset()
            hudPanel.dismiss()
            throw error
        }
    }

    func finish() {
        guard isRunning else {
            hudPanel.dismiss()
            return
        }

        isRunning = false
        hudState.isListening = false
        hudState.statusText = hudState.transcript.isEmpty ? "Transcribing…" : "Finishing…"

        capture.stop()
        inputContinuation?.finish()
        inputContinuation = nil

        let analyzer = self.analyzer
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer?.cancelAndFinishNow()
            }

            try? await Task.sleep(for: .milliseconds(450))
            self.hudPanel.dismiss()
            self.reset()
        }
    }

    private func reset() {
        capture.stop()
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
        finalizedText = ""
        hudState.level = 0
        hudState.isListening = false
        hudState.statusText = ""
        isRunning = false
    }

    private func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let selected = transcriber.selectedLocales
        let alreadyInstalled = selected.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard !alreadyInstalled else { return }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            hudState.statusText = "Downloading speech model…"
            try await request.downloadAndInstall()
            try Task.checkCancellation()
        }
    }
}

@available(macOS 26.0, *)
private enum LiveDictationError: Error, LocalizedError {
    case unsupportedAudioFormat

    var errorDescription: String? {
        "Live transcription could not negotiate a compatible microphone format."
    }
}

@available(macOS 26.0, *)
private struct LiveAudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

@available(macOS 26.0, *)
private final class LiveAudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var onBuffer: (@Sendable (LiveAudioChunk) -> Void)?
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    private var isRunning = false

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (LiveAudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        self.outputFormat = outputFormat
        self.onBuffer = onBuffer
        self.onLevel = onLevel

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw LiveDictationError.unsupportedAudioFormat
        }

        converter = nativeFormat == outputFormat
            ? nil
            : AVAudioConverter(from: nativeFormat, to: outputFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        outputFormat = nil
        onBuffer = nil
        onLevel = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: buffer))
        guard let outputFormat else { return }

        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(LiveAudioChunk(buffer: copy))
            }
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) let input = buffer
        let consumed = OneShotLatch()
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            guard !consumed.take() else {
                outputStatus.pointee = .noDataNow
                return nil
            }
            outputStatus.pointee = .haveData
            return input
        }

        guard conversionError == nil, status != .error, converted.frameLength > 0 else { return }
        onBuffer?(LiveAudioChunk(buffer: converted))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }

    private final class OneShotLatch: @unchecked Sendable {
        private var fired = false

        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class LiveDictationHUDState: ObservableObject {
    @Published var transcript = ""
    @Published var statusText = ""
    @Published var level: Float = 0
    @Published var isListening = false
}

@available(macOS 26.0, *)
@MainActor
private final class LiveDictationHUDPanel: NSPanel {
    init(state: LiveDictationHUDState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = NSHostingView(rootView: LiveDictationHUDView(state: state))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        reposition()
        guard !isVisible else { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
            }
        }
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.minY + 96
            )
        )
    }
}

@available(macOS 26.0, *)
private struct LiveDictationHUDView: View {
    @ObservedObject var state: LiveDictationHUDState

    var body: some View {
        HStack(spacing: 14) {
            LiveWaveform(level: state.level, isActive: state.isListening)
                .frame(width: 78, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.transcript.isEmpty ? state.statusText : state.transcript)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !state.transcript.isEmpty && !state.statusText.isEmpty {
                    Text(state.statusText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 360, height: 82)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }
}

@available(macOS 26.0, *)
private struct LiveWaveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(.tint)
                        .frame(width: 3, height: height(for: index, at: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let floorHeight: CGFloat = 3
        guard isActive else { return floorHeight }
        let phase = Double(index) * 0.618
        let wave = sin(time * 6 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.04, level))
        return floorHeight + max(0, amplitude * (0.55 + 0.45 * CGFloat(wave))) * 24
    }
}
