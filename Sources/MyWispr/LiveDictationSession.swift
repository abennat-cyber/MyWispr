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

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var finalizedText = ""
    private var isRunning = false

    private init() {}

    func start(locale: Locale = .current) async throws {
        guard !isRunning else { return }
        guard SpeechTranscriber.isAvailable else { return }
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        try await ensureModelInstalled(for: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else { return }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        finalizedText = ""
        hudState.transcript = ""
        hudState.isListening = true
        hudState.statusText = "Listening…"
        hudPanel.present()

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.audioEngine = engine
        self.isRunning = true

        resultTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.hudState.transcript = self.finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
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

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let level = Self.rmsLevel(buffer)
            Task { @MainActor [weak self] in
                self?.hudState.level = level
            }

            guard let converted = Self.convert(
                buffer,
                from: sourceFormat,
                to: targetFormat,
                using: converter
            ) else { return }

            continuation.yield(AnalyzerInput(buffer: converted))
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            reset()
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

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
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
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
        audioEngine = nil
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
            hudState.statusText = "Listening…"
        }
    }

    nonisolated private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        if formatsAreEquivalent(sourceFormat, targetFormat) {
            guard let copy = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: inputBuffer.frameLength
            ) else { return nil }
            copy.frameLength = inputBuffer.frameLength

            let audioBufferList = inputBuffer.audioBufferList.pointee
            let copyBufferList = copy.mutableAudioBufferList
            for index in 0..<Int(audioBufferList.mNumberBuffers) {
                let source = audioBufferList.mBuffers
                let destination = copyBufferList.pointee.mBuffers
                if index == 0,
                   let sourceData = source.mData,
                   let destinationData = destination.mData {
                    memcpy(destinationData, sourceData, Int(source.mDataByteSize))
                }
            }
            return copy
        }

        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = max(
            AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256,
            256
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

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

        guard conversionError == nil else { return nil }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    nonisolated private static func formatsAreEquivalent(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    nonisolated private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        return min(1, sqrt(sum / Float(count)) * 5)
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
