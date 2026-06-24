import AVFoundation
import Foundation
import MyWisprCore
import ScreenCaptureKit

/// Records microphone and system audio (speakers/apps) simultaneously.
/// Mic is captured via AVAudioRecorder. System audio is captured via
/// ScreenCaptureKit and written to a separate temp file. On stop, both
/// files are mixed into a single .m4a using AVMutableComposition.
@MainActor
final class MeetingRecorder: NSObject {

    // MARK: - State

    private var micRecorder: AVAudioRecorder?
    private var micTempURL: URL?

    private var scStream: SCStream?
    private var systemAudioHandler: SystemAudioHandler?  // strong ref — prevents dealloc mid-stream
    nonisolated(unsafe) private var systemWriter: AVAssetWriter?
    nonisolated(unsafe) private var systemInput: AVAssetWriterInput?
    private var systemTempURL: URL?
    private let systemQueue = DispatchQueue(label: "com.abennat.mywispr.system-audio", qos: .userInitiated)
    nonisolated(unsafe) private var systemWriterStarted = false

    private var outputURL: URL?
    private var isCapturingSystem = false

    // MARK: - Errors

    enum MeetingError: Error, LocalizedError {
        case notRecording
        case microphoneDenied
        case mixFailed(String)
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRecording:      return "Meeting recording is not active."
            case .microphoneDenied:  return "Microphone access was denied."
            case .mixFailed(let m):  return "Failed to mix audio: \(m)"
            case .setupFailed(let m): return "Meeting recorder setup failed: \(m)"
            }
        }
    }

    // MARK: - Public API

    func start(in directory: String) async throws -> URL {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw MeetingError.microphoneDenied }

        guard Self.canCaptureSystemAudio else {
            _ = CGRequestScreenCaptureAccess()
            throw MeetingError.setupFailed(Self.systemAudioPermissionMessage)
        }

        let dir = resolve(directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = dir.appendingPathComponent("Meeting-\(ts).m4a")
        outputURL = dest

        do {
            try startMic()
            try await startSystemAudio()
        } catch {
            micRecorder?.stop()
            micRecorder = nil
            [micTempURL, systemTempURL].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
            micTempURL = nil
            systemTempURL = nil
            outputURL = nil
            systemAudioHandler = nil
            systemWriter = nil
            systemInput = nil
            systemWriterStarted = false
            throw error
        }

        return dest
    }

    func stop() async throws -> URL {
        guard let dest = outputURL else { throw MeetingError.notRecording }

        micRecorder?.stop()
        micRecorder = nil

        if isCapturingSystem {
            try? await scStream?.stopCapture()
            scStream = nil
        }

        // Finish the AVAssetWriter for system audio on its dedicated queue,
        // with a 5-second safety timeout to prevent the app hanging.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let alreadyResumed = AlreadyResumed()
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                if alreadyResumed.markDone() { cont.resume() }
            }

            systemQueue.async { [weak self] in
                guard let self else {
                    timeout.cancel()
                    if alreadyResumed.markDone() { cont.resume() }
                    return
                }
                self.systemInput?.markAsFinished()
                if self.systemWriterStarted {
                    self.systemWriter?.finishWriting {
                        timeout.cancel()
                        if alreadyResumed.markDone() { cont.resume() }
                    }
                } else {
                    timeout.cancel()
                    if alreadyResumed.markDone() { cont.resume() }
                }
            }
        }

        systemAudioHandler = nil
        systemWriter = nil
        systemInput  = nil

        let micURL = micTempURL
        let sysURL = systemTempURL

        defer {
            [micURL, sysURL].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
            outputURL         = nil
            micTempURL        = nil
            systemTempURL     = nil
            isCapturingSystem = false
            systemWriterStarted = false
        }

        try await mix(mic: micURL, system: sysURL, into: dest)
        return dest
    }

    func exportMicChunk(startTime: TimeInterval, duration: TimeInterval) async throws -> URL? {
        guard let micURL = micTempURL, let micRecorder else { throw MeetingError.notRecording }

        guard MeetingLiveTranscriptionSupport.isChunkReady(
            elapsed: micRecorder.currentTime,
            start: startTime,
            duration: duration
        ) else {
            return nil
        }

        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-meeting-live-chunk.m4a")
        let asset = AVURLAsset(url: micURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.mixFailed("AVAssetExportSession unavailable.")
        }

        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let chunkDuration = CMTime(seconds: duration, preferredTimescale: 600)
        exporter.outputURL = chunkURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(start: start, duration: chunkDuration)

        await exporter.export()
        if let error = exporter.error {
            try? FileManager.default.removeItem(at: chunkURL)
            throw MeetingError.mixFailed(error.localizedDescription)
        }
        return chunkURL
    }

    // MARK: - Mic

    private func startMic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-mic.m4a")
        micTempURL = url

        let settings: [String: Any] = [
            AVFormatIDKey:          Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:        44100,
            AVNumberOfChannelsKey:  1,
            AVEncoderBitRateKey:    96_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        micRecorder = recorder
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-system.m4a")
        systemTempURL = url

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw MeetingError.setupFailed("Could not create system audio writer: \(error.localizedDescription)")
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey:          Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:        44100,
            AVNumberOfChannelsKey:  2,
            AVEncoderBitRateKey:    96_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MeetingError.setupFailed("Could not attach the system audio writer input.")
        }
        writer.add(input)

        systemWriter = writer
        systemInput  = input

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                throw MeetingError.setupFailed("No display is available for system audio capture.")
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )

            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate   = 44100
            cfg.channelCount = 2
            // SCStream requires a video config even for audio-only use.
            // Use the absolute minimum to avoid wasting memory on video frames.
            cfg.width  = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps max

            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)

            // Keep a strong reference so the handler lives as long as the stream.
            let handler = SystemAudioHandler(
                writer: writer,
                input: input,
                queue: systemQueue
            ) { [weak self] in
                self?.systemWriterStarted = true
            }
            systemAudioHandler = handler

            // Register ONLY for audio output — video frames are never delivered to us
            // so the framework discards them after the minimum processing needed by SCStream.
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: systemQueue)
            try await stream.startCapture()

            scStream = stream
            isCapturingSystem = true

        } catch {
            systemTempURL    = nil
            systemWriter     = nil
            systemInput      = nil
            systemAudioHandler = nil
            throw MeetingError.setupFailed(systemAudioSetupMessage(for: error))
        }
    }

    private static var canCaptureSystemAudio: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static let systemAudioPermissionMessage =
        "Screen Recording permission is required to capture the default output device. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then restart MyWispr."

    private func systemAudioSetupMessage(for error: Error) -> String {
        if !Self.canCaptureSystemAudio {
            return Self.systemAudioPermissionMessage
        }
        return "Could not start default output capture: \(error.localizedDescription)"
    }

    // MARK: - Mixing

    private func mix(mic: URL?, system: URL?, into dest: URL) async throws {
        guard let micURL = mic else {
            throw MeetingError.setupFailed("Microphone recording file missing.")
        }

        // If system audio wasn't captured, just export mic directly.
        guard let sysURL = system,
              FileManager.default.fileExists(atPath: sysURL.path),
              (try? FileManager.default.attributesOfItem(atPath: sysURL.path))?[.size] as? Int ?? 0 > 4096
        else {
            try await exportAsM4A(from: micURL, to: dest)
            return
        }

        let composition = AVMutableComposition()
        let micAsset    = AVURLAsset(url: micURL)
        let sysAsset    = AVURLAsset(url: sysURL)

        let micDuration   = try await micAsset.load(.duration)
        let sysDuration   = try await sysAsset.load(.duration)
        let finalDuration = max(micDuration, sysDuration)

        // Insert mic track
        if let micTracks = try? await micAsset.loadTracks(withMediaType: .audio),
           let micTrack  = micTracks.first,
           let compTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: micDuration),
                of: micTrack, at: .zero
            )
        }

        // Insert system audio track alongside (not after) the mic track
        if let sysTracks = try? await sysAsset.loadTracks(withMediaType: .audio),
           let sysTrack  = sysTracks.first,
           let compTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: sysDuration),
                of: sysTrack, at: .zero
            )
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MeetingError.mixFailed("AVAssetExportSession unavailable.")
        }
        exporter.outputURL      = dest
        exporter.outputFileType = .m4a
        exporter.timeRange      = CMTimeRange(start: .zero, duration: finalDuration)

        await exporter.export()

        if let error = exporter.error {
            throw MeetingError.mixFailed(error.localizedDescription)
        }
    }

    private func exportAsM4A(from source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.mixFailed("AVAssetExportSession unavailable.")
        }
        exporter.outputURL      = dest
        exporter.outputFileType = .m4a
        await exporter.export()
        if let error = exporter.error {
            throw MeetingError.mixFailed(error.localizedDescription)
        }
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("~") {
            return URL(
                fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path
                    + path.dropFirst()
            )
        }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Thread-safe once-flag for continuation safety

/// Ensures a CheckedContinuation is resumed exactly once even with concurrent callers.
private final class AlreadyResumed: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    /// Returns true if this is the first call (caller should resume the continuation).
    func markDone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - SCStreamOutput handler

/// Receives audio sample buffers from SCStream on a dedicated background queue
/// and writes them into an AVAssetWriter.
private final class SystemAudioHandler: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let input:  AVAssetWriterInput
    private let queue:  DispatchQueue
    private var started = false
    private let onFirstSample: () -> Void

    init(
        writer: AVAssetWriter,
        input:  AVAssetWriterInput,
        queue:  DispatchQueue,
        onFirstSample: @escaping () -> Void
    ) {
        self.writer        = writer
        self.input         = input
        self.queue         = queue
        self.onFirstSample = onFirstSample
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if !started {
            writer.startWriting()
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            started = true
            onFirstSample()
        }

        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
