import Foundation

public struct MeetingParticipant: Codable, Equatable, Hashable, Sendable {
    public var displayName: String
    public var email: String?

    public init(displayName: String, email: String? = nil) {
        self.displayName = displayName
        self.email = email
    }

    public var formattedValue: String {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmail, !trimmedEmail.isEmpty {
            return "\(displayName) <\(trimmedEmail)>"
        }
        return displayName
    }
}

public struct MeetingSessionDraft: Codable, Equatable, Sendable {
    public var title: String
    public var participants: [MeetingParticipant]
    public var personalNotes: String

    public init(title: String = "", participants: [MeetingParticipant] = [], personalNotes: String = "") {
        self.title = title
        self.participants = participants
        self.personalNotes = personalNotes
    }

    public var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PersonalNotesPriority: String, Codable, Equatable, Sendable {
    case higherThanTranscriptWhenConflictExists = "higher_than_transcript_when_conflict_exists"
}

public struct RecordedMeetingBundle: Codable, Equatable, Sendable {
    public var title: String
    public var participants: [MeetingParticipant]
    public var personalNotes: String
    public var personalNotesPriority: PersonalNotesPriority
    public var transcript: String
    public var recordingStartedAt: Date
    public var recordingEndedAt: Date
    public var audioFileName: String
    public var audioFilePath: String

    public init(
        title: String,
        participants: [MeetingParticipant],
        personalNotes: String,
        personalNotesPriority: PersonalNotesPriority,
        transcript: String,
        recordingStartedAt: Date,
        recordingEndedAt: Date,
        audioFileName: String,
        audioFilePath: String
    ) {
        self.title = title
        self.participants = participants
        self.personalNotes = personalNotes
        self.personalNotesPriority = personalNotesPriority
        self.transcript = transcript
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
        self.audioFileName = audioFileName
        self.audioFilePath = audioFilePath
    }
}

public enum MeetingBundleFormatter {
    public static func prettyJSONString(for bundle: RecordedMeetingBundle) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string + "\n"
    }

    public static func humanReadableSummary(for bundle: RecordedMeetingBundle) -> String {
        let formatter = ISO8601DateFormatter()
        let participants = bundle.participants.isEmpty
            ? "Unavailable"
            : bundle.participants.map(\.formattedValue).joined(separator: ", ")
        let notes = normalizedBlock(bundle.personalNotes, emptyFallback: "None")
        let transcript = normalizedBlock(bundle.transcript, emptyFallback: "None")

        return """
        Meeting Notes

        Title: \(bundle.title)
        Participants: \(participants)
        Recording started: \(formatter.string(from: bundle.recordingStartedAt))
        Recording ended: \(formatter.string(from: bundle.recordingEndedAt))
        Source audio: \(bundle.audioFileName)
        Personal notes priority: \(bundle.personalNotesPriority.rawValue)

        Personal notes:
        \(notes)

        Transcript:
        \(transcript)
        """
    }

    private static func normalizedBlock(_ text: String, emptyFallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? emptyFallback : trimmed
    }
}
