import Foundation

public enum RecordingAudioFormat: String, Codable, Equatable, Sendable {
    case m4a
    case wav

    public var fileExtension: String {
        rawValue
    }
}

public enum DictationRecordingFormatSelector {
    public static func recordingFormat(forEngineRawValue rawValue: String) -> RecordingAudioFormat {
        rawValue == "localWhisper" ? .wav : .m4a
    }
}

public enum LocalWhisperConversionPolicy {
    public static func requiresConversion(fileExtension: String) -> Bool {
        fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "wav"
    }
}

public enum ActivationWaitPolicy {
    public static func shouldKeepWaiting(elapsedMilliseconds: Int, maxMilliseconds: Int, targetIsFrontmost: Bool) -> Bool {
        !targetIsFrontmost && elapsedMilliseconds < maxMilliseconds
    }
}

public enum RecordingRetentionPolicy {
    private static let audioExtensions: Set<String> = ["m4a", "wav"]
    private static let sidecarExtensions: Set<String> = ["json", "txt"]

    public static func shouldPurge(
        fileName: String,
        creationDate: Date?,
        contentModificationDate: Date?,
        now: Date,
        maxAge: TimeInterval
    ) -> Bool {
        guard maxAge > 0 else { return false }

        let fileExtension = normalizedExtension(for: fileName)
        let cutoff = now.addingTimeInterval(-maxAge)
        let timestamp = recordingTimestamp(from: fileName)

        if audioExtensions.contains(fileExtension) {
            guard let referenceDate = timestamp ?? contentModificationDate ?? creationDate else {
                return false
            }
            return referenceDate < cutoff
        }

        if sidecarExtensions.contains(fileExtension) {
            guard let timestamp else { return false }
            return timestamp < cutoff
        }

        return false
    }

    private static func normalizedExtension(for fileName: String) -> String {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dotIndex = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dotIndex)...]).lowercased()
    }

    private static func recordingTimestamp(from fileName: String) -> Date? {
        let baseName = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .dropLast()
            .joined(separator: ".")

        let timestamp = baseName.hasPrefix("Meeting-")
            ? String(baseName.dropFirst("Meeting-".count))
            : baseName

        guard let normalized = normalizedISO8601Timestamp(timestamp) else {
            return nil
        }
        return ISO8601DateFormatter().date(from: normalized)
    }

    private static func normalizedISO8601Timestamp(_ timestamp: String) -> String? {
        let parts = timestamp.split(separator: "T", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let datePart = parts[0]
        let timeAndZone = parts[1]
        guard timeAndZone.hasSuffix("Z") else { return nil }

        let timePart = timeAndZone.dropLast()
        let timeParts = timePart.split(separator: "-")
        guard timeParts.count == 3 else { return nil }

        return "\(datePart)T\(timeParts[0]):\(timeParts[1]):\(timeParts[2])Z"
    }
}
