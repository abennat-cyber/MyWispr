import Foundation

public enum MeetingLiveTranscriptionSupport {
    public static let chunkDuration: TimeInterval = 10
    public static let chunkReadinessTolerance: TimeInterval = 0.25

    public static func isChunkReady(
        elapsed: TimeInterval,
        start: TimeInterval,
        duration: TimeInterval = chunkDuration,
        tolerance: TimeInterval = chunkReadinessTolerance
    ) -> Bool {
        elapsed + tolerance >= start + duration
    }

    public static func appendedTranscript(existing: String, newText: String) -> String {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        guard !existing.isEmpty else { return trimmed }
        return existing + "\n" + trimmed
    }
}
