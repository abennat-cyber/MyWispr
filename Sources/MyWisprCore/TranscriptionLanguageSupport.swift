import Foundation

public enum TranscriptionScript: Equatable {
    case latin
    case hebrew

    public var isRightToLeft: Bool {
        switch self {
        case .latin:
            return false
        case .hebrew:
            return true
        }
    }
}

public enum TranscriptionPromptBuilder {
    public static func apiPrompt(languageNames: [String], vocabulary: [String]) -> String? {
        combinedPrompt(
            languageNames: languageNames,
            vocabulary: vocabulary,
            vocabularyPrefix: "Custom vocabulary"
        )
    }

    public static func localPrompt(languageNames: [String], languageScripts: [TranscriptionScript], vocabulary: [String]) -> String? {
        if languageScripts.count == 1, languageScripts[0] == .hebrew {
            let words = trimmedVocabulary(vocabulary)
            guard !words.isEmpty else { return nil }
            return "מילים חשובות: \(words.joined(separator: ", "))."
        }

        return combinedPrompt(
            languageNames: languageNames,
            vocabulary: vocabulary,
            vocabularyPrefix: "Custom vocabulary"
        )
    }

    private static func combinedPrompt(languageNames: [String], vocabulary: [String], vocabularyPrefix: String) -> String? {
        var parts: [String] = []

        if languageNames.count > 1 {
            parts.append("The audio may be in any of these languages: \(languageNames.joined(separator: ", ")).")
        }

        let words = trimmedVocabulary(vocabulary)
        if !words.isEmpty {
            parts.append("\(vocabularyPrefix): \(words.joined(separator: ", ")).")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func trimmedVocabulary(_ vocabulary: [String]) -> [String] {
        vocabulary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum TranscriptScriptValidator {
    public static func shouldRetryWithoutPrompt(_ transcript: String, expectedScript: TranscriptionScript?) -> Bool {
        guard expectedScript == .hebrew else { return false }

        let counts = scriptCounts(in: transcript)
        return counts.hebrew == 0 && counts.latin > 0
    }

    public static func containsExpectedScript(_ transcript: String, expectedScript: TranscriptionScript?) -> Bool {
        guard let expectedScript else { return true }

        switch expectedScript {
        case .hebrew:
            return scriptCounts(in: transcript).hebrew > 0
        case .latin:
            return true
        }
    }

    private static func scriptCounts(in text: String) -> (hebrew: Int, latin: Int) {
        var hebrew = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            if scalar.isHebrew {
                hebrew += 1
            } else if scalar.isLatin {
                latin += 1
            }
        }

        return (hebrew, latin)
    }
}

private extension Unicode.Scalar {
    var isHebrew: Bool {
        value >= 0x0590 && value <= 0x05FF
    }

    var isLatin: Bool {
        (value >= 0x0041 && value <= 0x005A)
            || (value >= 0x0061 && value <= 0x007A)
            || (value >= 0x00C0 && value <= 0x024F)
    }
}
