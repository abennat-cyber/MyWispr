import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records microphone and system audio (speakers/apps) simultaneously.
/// The two streams are saved to separate temporary files, then mixed
/// into a single .m4a in the user's recordings folder via AVMutableComposition.
@MainActor
final class MeetingRecorder: NSObject {
    private var micRecorder: AVAudioRecorder?
    private var micTempURL: URL?

    private var scStream: SCStream?
    // These are written on main actor but read on systemQueue via [weak self] captures.
    // Access from the background queue only happens after the main-actor write completes.
    nonisolated(unsafe) private var systemWriter: AVAssetWriter?
    nonisolated(unsafe) private var systemInput: AVAssetWriterInput?
    private var systemTempURL: URL?
    private let systemQueue = DispatchQueue(label: "com.abennat.mywispr.system-audio")
    nonisolated(unsafe) private var systemWriterStarted = false

    private var outputURL: URL?
    private var isCapturingSystem = false

    enum MeetingError: Error, LocalizedError {
        case notRecording
        case mixFailed(String)
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRecording: return "Meeting recording is not active."
            case .mixFailed(let m): return "Failed to mix audio: \(m)"
            case .setupFailed(let m): return "Meeting recorder setup failed: \(m)"
            }
        }
    }

    // MARK: - Public

    /// Returns the destination URL (recording hasn't started yet — call start()).
    func start(in directory: String) async throws -> URL {
        let dir = resolve(directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = dir.appendingPathComponent("Meeting-\(ts).m4a")
        outputURL = dest

        try startMic()
        await startSystemAudio()   // best-effort; proceeds without if permission missing

        return dest
    }

    func stop() async throws -> URL {
        guard let dest = outputURL else { throw MeetingError.notRecording }

        // Stop mic
        micRecorder?.stop()

        // Stop system audio
        if isCapturingSystem {
            try? await scStream?.stopCapture()
            scStream = nil
        }

        // Finish the asset writer
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            systemQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.systemInput?.markAsFinished()
                if self.systemWriterStarted {
                    self.systemWriter?.finishWriting { cont.resume() }
                } else {
                    cont.resume()
                }
            }
        }

        // Mix mic + system into the destination file
        let micURL  = micTempURL
        let sysURL  = systemTempURL

        try await mix(mic: micURL, system: sysURL, into: dest)

        // Cleanup temps
        [micURL, sysURL].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }

        outputURL       = nil
        micTempURL      = nil
        systemTempURL   = nil
        systemWriter    = nil
        systemInput     = nil
        isCapturingSystem = false
        systemWriterStarted = false

        return dest
    }

    // MARK: - Mic recording

    private func startMic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-mic.m4a")
        micTempURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        micRecorder = try AVAudioRecorder(url: url, settings: settings)
        micRecorder?.record()
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-system.m4a")
        systemTempURL = url

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        systemWriter = writer
        systemInput  = input

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 44100
            cfg.channelCount = 2
            // Minimal video (required by SCStream even when only capturing audio)
            cfg.width  = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            let handler = SystemAudioHandler(writer: writer, input: input, queue: systemQueue) { [weak self] in
                self?.systemWriterStarted = true
            }
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: systemQueue)
            try await stream.startCapture()

            scStream = stream
            isCapturingSystem = true
        } catch {
            // Screen Recording permission not granted or no display — mic only
            systemTempURL = nil
        }
    }

    // MARK: - Mixing

    private func mix(mic: URL?, system: URL?, into dest: URL) async throws {
        // If we only have mic (system capture failed), just move the mic file
        guard let micURL = mic else {
            throw MeetingError.setupFailed("Microphone recording file missing.")
        }

        guard let sysURL = system, FileManager.default.fileExists(atPath: sysURL.path) else {
            // System audio unavailable — use mic only, convert to destination
            try await convertToM4A(from: micURL, to: dest)
            return
        }

        // Mix mic + system using AVMutableComposition
        let composition = AVMutableComposition()

        let micAsset = AVURLAsset(url: micURL)
        let sysAsset = AVURLAsset(url: sysURL)

        let micDuration  = try await micAsset.load(.duration)
        let sysDuration  = try await sysAsset.load(.duration)
        let finalDuration = max(micDuration, sysDuration)

        if let micTracks = try? await micAsset.loadTracks(withMediaType: .audio),
           let micTrack  = micTracks.first,
           let compMicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compMicTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: micDuration),
                of: micTrack, at: .zero
            )
        }

        if let sysTracks = try? await sysAsset.loadTracks(withMediaType: .audio),
           let sysTrack  = sysTracks.first,
           let compSysTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compSysTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: sysDuration),
                of: sysTrack, at: .zero
            )
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.mixFailed("AVAssetExportSession unavailable.")
        }
        exporter.outputURL = dest
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(start: .zero, duration: finalDuration)

        await exporter.export()

        if let error = exporter.error {
            throw MeetingError.mixFailed(error.localizedDescription)
        }
    }

    private func convertToM4A(from source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.mixFailed("AVAssetExportSession unavailable.")
        }
        exporter.outputURL = dest
        exporter.outputFileType = .m4a
        await exporter.export()
        if let error = exporter.error {
            throw MeetingError.mixFailed(error.localizedDescription)
        }
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst())
        }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - System audio SCStreamOutput helper

/// Handles SCStream audio callbacks on a background queue.
private final class SystemAudioHandler: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    private var started = false
    private var onFirstSample: () -> Void

    init(writer: AVAssetWriter, input: AVAssetWriterInput, queue: DispatchQueue, onFirstSample: @escaping () -> Void) {
        self.writer = writer
        self.input  = input
        self.queue  = queue
        self.onFirstSample = onFirstSample
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
