import Foundation

public enum TranscriptPostProcessor {
    private static let silenceHallucinations: Set<String> = [
        "thank you",
        "thanks for watching",
        "you",
        "bye",
        "goodbye",
        "okay",
        "ok",
        "blank audio",
    ]

    public static func shouldInsert(_ transcript: String) -> Bool {
        let normalized = normalizedForSilenceCheck(transcript)
        guard !normalized.isEmpty else { return false }
        return !silenceHallucinations.contains(normalized)
    }

    private static func normalizedForSilenceCheck(_ transcript: String) -> String {
        transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct InsertionTextContext: Equatable, Sendable {
    public var previousCharacter: Character?
    public var nextCharacter: Character?

    public init(previousCharacter: Character? = nil, nextCharacter: Character? = nil) {
        self.previousCharacter = previousCharacter
        self.nextCharacter = nextCharacter
    }
}

public enum InsertionTextFormatter {
    public static func formattedTranscript(_ transcript: String, context: InsertionTextContext) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let touchesPreviousWord = context.previousCharacter?.isWordLike == true
        let touchesNextWord = context.nextCharacter?.isWordLike == true
        let shouldAddLeadingSpace = touchesPreviousWord || touchesNextWord
        let shouldLowercaseFirstLetter = touchesPreviousWord || touchesNextWord

        let cased = shouldLowercaseFirstLetter ? lowercasingFirstCasedCharacter(in: trimmed) : trimmed
        return shouldAddLeadingSpace ? " " + cased : cased
    }

    private static func lowercasingFirstCasedCharacter(in text: String) -> String {
        var result = ""
        var changed = false

        for character in text {
            if !changed, character.isUppercaseLetter {
                result.append(String(character).lowercased())
                changed = true
            } else {
                result.append(character)
            }
        }

        return result
    }
}

public enum AudioSilencePolicy {
    public static func hasSpeech(duration: TimeInterval, rootMeanSquare: Double, peakAmplitude: Double) -> Bool {
        guard duration >= 0.25 else { return false }
        return rootMeanSquare >= 0.003 || peakAmplitude >= 0.02
    }
}

private extension Character {
    var isWordLike: Bool {
        unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    var isUppercaseLetter: Bool {
        let string = String(self)
        return string.rangeOfCharacter(from: .uppercaseLetters) != nil && string.lowercased() != string
    }
}
