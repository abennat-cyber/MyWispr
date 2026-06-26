import AppKit
import Carbon
import Foundation
import MyWisprCore

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case toggle
    case holdToTalk

    var id: Self { self }

    var title: String {
        switch self {
        case .toggle:
            return "Press to toggle"
        case .holdToTalk:
            return "Hold to talk"
        }
    }
}

enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable {
    case localWhisper
    case whisperAPI
    case customCommand

    var id: Self { self }

    var title: String {
        switch self {
        case .localWhisper:
            return "Local Whisper (whisper.cpp)"
        case .whisperAPI:
            return "OpenAI Whisper API"
        case .customCommand:
            return "Custom command"
        }
    }
}

enum RecordingRetention: String, Codable, CaseIterable, Identifiable {
    case session   = "session"
    case oneDay    = "1day"
    case sevenDays = "7days"
    case thirtyDays = "30days"
    case forever   = "forever"

    var id: Self { self }

    var title: String {
        switch self {
        case .session:    return "Delete after transcription"
        case .oneDay:     return "1 day"
        case .sevenDays:  return "7 days"
        case .thirtyDays: return "30 days"
        case .forever:    return "Keep forever"
        }
    }

    var maxAge: TimeInterval? {
        switch self {
        case .session:    return 0
        case .oneDay:     return 86_400
        case .sevenDays:  return 604_800
        case .thirtyDays: return 2_592_000
        case .forever:    return nil
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_Semicolon),
        modifiers: UInt32(cmdKey | optionKey)
    )

    var carbonModifiers: UInt32 {
        modifiers
    }

    var displayText: String {
        let symbols = [
            (cmdKey, "⌘"),
            (optionKey, "⌥"),
            (controlKey, "⌃"),
            (shiftKey, "⇧")
        ]

        let modifierString = symbols.reduce(into: "") { result, item in
            if modifiers & UInt32(item.0) != 0 {
                result += item.1
            }
        }

        return modifierString + Self.label(for: UInt16(keyCode))
    }

    static func from(event: NSEvent) -> KeyboardShortcut? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { return nil }

        return KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: flags.carbonMask
        )
    }

    private static func label(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return:
            return "↩"
        case kVK_Space:
            return "Space"
        case kVK_Tab:
            return "⇥"
        case kVK_Delete:
            return "⌫"
        case kVK_Escape:
            return "⎋"
        case kVK_ANSI_Semicolon:
            return ";"
        case kVK_ANSI_Comma:
            return ","
        case kVK_ANSI_Period:
            return "."
        case kVK_ANSI_Slash:
            return "/"
        default:
            if let scalar = KeyMap.labels[Int(keyCode)] {
                return scalar
            }
            return "Key \(keyCode)"
        }
    }
}

struct LocalWhisperModel: Codable, CaseIterable, Equatable, Hashable, Identifiable {
    let rawValue: String

    static let tiny = LocalWhisperModel(rawValue: "tiny")
    static let tinyEnglish = LocalWhisperModel(rawValue: "tiny.en")
    static let base = LocalWhisperModel(rawValue: "base")
    static let baseEnglish = LocalWhisperModel(rawValue: "base.en")
    static let small = LocalWhisperModel(rawValue: "small")
    static let smallEnglish = LocalWhisperModel(rawValue: "small.en")
    static let medium = LocalWhisperModel(rawValue: "medium")
    static let mediumEnglish = LocalWhisperModel(rawValue: "medium.en")
    static let large = LocalWhisperModel(rawValue: "large")
    static let largeV1 = LocalWhisperModel(rawValue: "large-v1")
    static let largeV2 = LocalWhisperModel(rawValue: "large-v2")
    static let largeV3 = LocalWhisperModel(rawValue: "large-v3")
    static let largeV3Turbo = LocalWhisperModel(rawValue: "large-v3-turbo")

    static let allCases: [LocalWhisperModel] = [
        .tiny, .tinyEnglish,
        .base, .baseEnglish,
        .small, .smallEnglish,
        .medium, .mediumEnglish,
        .large, .largeV1, .largeV2, .largeV3, .largeV3Turbo
    ]

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch rawValue {
        case Self.tiny.rawValue:          return "Tiny (~75 MB, fastest)"
        case Self.tinyEnglish.rawValue:   return "Tiny English (~75 MB, fastest)"
        case Self.base.rawValue:          return "Base (~142 MB, fast)"
        case Self.baseEnglish.rawValue:   return "Base English (~142 MB, fast)"
        case Self.small.rawValue:         return "Small (~466 MB, balanced)"
        case Self.smallEnglish.rawValue:  return "Small English (~466 MB, balanced)"
        case Self.medium.rawValue:        return "Medium (~1.5 GB, accurate)"
        case Self.mediumEnglish.rawValue: return "Medium English (~1.5 GB, accurate)"
        case Self.large.rawValue:         return "Large (~2.9 GB, most accurate)"
        case Self.largeV1.rawValue:       return "Large v1 (~2.9 GB)"
        case Self.largeV2.rawValue:       return "Large v2 (~2.9 GB)"
        case Self.largeV3.rawValue:       return "Large v3 (~2.9 GB, most accurate)"
        case Self.largeV3Turbo.rawValue:  return "Large v3 Turbo (~1.5 GB, faster)"
        default:
            return rawValue
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: ".", with: " ")
                .capitalized
        }
    }

    var filename: String { "ggml-\(rawValue).bin" }

    var downloadSize: String {
        switch rawValue {
        case Self.tiny.rawValue, Self.tinyEnglish.rawValue:
            return "75 MB"
        case Self.base.rawValue, Self.baseEnglish.rawValue:
            return "142 MB"
        case Self.small.rawValue, Self.smallEnglish.rawValue:
            return "466 MB"
        case Self.medium.rawValue, Self.mediumEnglish.rawValue, Self.largeV3Turbo.rawValue:
            return "1.5 GB"
        case Self.large.rawValue, Self.largeV1.rawValue, Self.largeV2.rawValue, Self.largeV3.rawValue:
            return "2.9 GB"
        default:
            return "unknown size"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var shortcut: KeyboardShortcut = .default
    var recordingMode: RecordingMode = .toggle
    var selectedEngine: TranscriptionEngineKind = .localWhisper
    /// Ordered list of languages to detect (up to 5). Empty = auto-detect.
    var transcriptionLanguages: [WhisperLanguage] = []
    var recordingDirectory: String = "~/Library/Application Support/MyWispr/Recordings"
    var recordingRetention: RecordingRetention = .session
    var whisperModel: String = "whisper-1"
    var localWhisperModel: LocalWhisperModel = .base
    var localWhisperModelDir: String = "~/.local/share/whisper/models"
    var customCommandTemplate: String = ""
    var selectedCalendarIdentifier: String = ""
    /// User-defined words/phrases passed to Whisper to improve recognition of
    /// names, organization terms, and domain-specific vocabulary.
    var customVocabulary: [String] = []
    var muteSpeakerWhileRecording: Bool = false
    var customWhisperPrompt: String? = nil

    enum CodingKeys: String, CodingKey {
        case shortcut, recordingMode, selectedEngine, transcriptionLanguages,
             recordingDirectory, recordingRetention, whisperModel, localWhisperModel,
             localWhisperModelDir, customCommandTemplate, selectedCalendarIdentifier,
             customVocabulary, muteSpeakerWhileRecording, customWhisperPrompt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut) ?? .default
        recordingMode = try container.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .toggle
        selectedEngine = try container.decodeIfPresent(TranscriptionEngineKind.self, forKey: .selectedEngine) ?? .localWhisper
        transcriptionLanguages = try container.decodeIfPresent([WhisperLanguage].self, forKey: .transcriptionLanguages) ?? []
        recordingDirectory = try container.decodeIfPresent(String.self, forKey: .recordingDirectory) ?? "~/Library/Application Support/MyWispr/Recordings"
        recordingRetention = try container.decodeIfPresent(RecordingRetention.self, forKey: .recordingRetention) ?? .session
        whisperModel = try container.decodeIfPresent(String.self, forKey: .whisperModel) ?? "whisper-1"
        localWhisperModel = try container.decodeIfPresent(LocalWhisperModel.self, forKey: .localWhisperModel) ?? .base
        localWhisperModelDir = try container.decodeIfPresent(String.self, forKey: .localWhisperModelDir) ?? "~/.local/share/whisper/models"
        customCommandTemplate = try container.decodeIfPresent(String.self, forKey: .customCommandTemplate) ?? ""
        selectedCalendarIdentifier = try container.decodeIfPresent(String.self, forKey: .selectedCalendarIdentifier) ?? ""
        customVocabulary = try container.decodeIfPresent([String].self, forKey: .customVocabulary) ?? []
        muteSpeakerWhileRecording = try container.decodeIfPresent(Bool.self, forKey: .muteSpeakerWhileRecording) ?? false
        customWhisperPrompt = try container.decodeIfPresent(String.self, forKey: .customWhisperPrompt)
    }

    /// The single language code to pass to whisper-cli, or "auto".
    /// whisper-cli only supports one language at a time; when multiple are
    /// configured we use "auto" and rely on --prompt to bias detection.
    var effectiveLanguageArg: String {
        let langs = transcriptionLanguages.filter { $0 != .auto }
        return langs.count == 1 ? langs[0].whisperCode : "auto"
    }

    private var selectedTranscriptionLanguages: [WhisperLanguage] {
        transcriptionLanguages.filter { $0 != .auto }
    }

    private var selectedLanguageNames: [String] {
        selectedTranscriptionLanguages.map(\.displayName)
    }

    private var selectedLanguageScripts: [TranscriptionScript] {
        selectedTranscriptionLanguages.map(\.transcriptionScript)
    }

    var singleSelectedTranscriptionLanguage: WhisperLanguage? {
        let langs = selectedTranscriptionLanguages
        return langs.count == 1 ? langs[0] : nil
    }

    /// Combined prompt passed to both whisper-cli (--prompt) and the Whisper
    /// API (prompt field). Merges language hints and vocabulary hints.
    var fullPrompt: String? {
        whisperAPIPrompt
    }

    var whisperAPIPrompt: String? {
        TranscriptionPromptBuilder.apiPrompt(
            languageNames: selectedLanguageNames,
            vocabulary: customVocabulary
        )
    }

    var localWhisperPrompt: String? {
        if let custom = customWhisperPrompt {
            return custom.isEmpty ? nil : custom
        }
        return defaultLocalWhisperPrompt
    }

    var defaultLocalWhisperPrompt: String? {
        TranscriptionPromptBuilder.localPrompt(
            languageNames: selectedLanguageNames,
            languageScripts: selectedLanguageScripts,
            vocabulary: customVocabulary
        )
    }

    /// Human-readable summary for display.
    var languagesSummary: String {
        let langs = transcriptionLanguages.filter { $0 != .auto }
        if langs.isEmpty { return "Auto-detect" }
        return langs.map(\.displayName).joined(separator: ", ")
    }

    var preferredDictationRecordingFormat: RecordingAudioFormat {
        DictationRecordingFormatSelector.recordingFormat(forEngineRawValue: selectedEngine.rawValue)
    }
}

enum AppStatus: Equatable {
    case idle
    case recording
    case transcribing
    case succeeded(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .succeeded:
            return "Done"
        case .failed:
            return "Error"
        }
    }
}

extension AppStatus {
    static let silentTranscriptIgnored = AppStatus.succeeded("No speech detected.")
}

struct ActiveMeetingSession: Equatable {
    var title: String
    var participants: [MeetingParticipant]
    var personalNotes: String
    var recordingStartedAt: Date
    var audioURL: URL
}

struct CalendarSelection: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var sourceTitle: String

    var displayTitle: String {
        sourceTitle.isEmpty ? title : "\(title) - \(sourceTitle)"
    }
}

enum CalendarAccessState: Equatable {
    case notDetermined
    case requesting
    case granted
    case denied(String)

    var title: String {
        switch self {
        case .notDetermined:
            return "Not granted"
        case .requesting:
            return "Requesting access…"
        case .granted:
            return "Granted"
        case .denied:
            return "Access denied"
        }
    }

    var message: String? {
        switch self {
        case .denied(let message):
            return message
        case .notDetermined, .requesting, .granted:
            return nil
        }
    }
}

struct MeetingContextSuggestion: Equatable {
    var suggestedTitle: String?
    var participants: [MeetingParticipant]
    var calendarName: String?
    var eventStart: Date?
    var eventEnd: Date?
}

enum MeetingContextLookupState: Equatable {
    case idle
    case loading
    case suggested(MeetingContextSuggestion)
    case unavailable(String)

    var participants: [MeetingParticipant] {
        switch self {
        case .suggested(let suggestion):
            return suggestion.participants
        case .idle, .loading, .unavailable:
            return []
        }
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .loading:
            return "Looking up Apple Calendar event…"
        case .suggested(let suggestion):
            if let calendarName = suggestion.calendarName,
               let title = suggestion.suggestedTitle,
               !title.isEmpty {
                return "Autofilled from \(calendarName): \(title)"
            }
            if let calendarName = suggestion.calendarName {
                return "Participants autofilled from \(calendarName)"
            }
            return nil
        case .unavailable(let message):
            return message
        }
    }
}

protocol MeetingContextProvider: Sendable {
    func fetchContext(for draft: MeetingSessionDraft, during date: Date) async -> MeetingContextLookupState
}

enum InsertionResult: Equatable {
    case typed
    case pasted
    case clipboardOnly

    var userMessage: String {
        switch self {
        case .typed:
            return "Transcript inserted into the active app."
        case .pasted:
            return "Transcript pasted into the active app."
        case .clipboardOnly:
            return "Transcript copied to the clipboard."
        }
    }
}

private enum KeyMap {
    static let labels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9"
    ]
}

extension NSEvent.ModifierFlags {
    var carbonMask: UInt32 {
        var result: UInt32 = 0

        if contains(.command) {
            result |= UInt32(cmdKey)
        }
        if contains(.option) {
            result |= UInt32(optionKey)
        }
        if contains(.control) {
            result |= UInt32(controlKey)
        }
        if contains(.shift) {
            result |= UInt32(shiftKey)
        }

        return result
    }
}
