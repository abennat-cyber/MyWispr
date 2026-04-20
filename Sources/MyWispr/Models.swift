import AppKit
import Carbon
import Foundation

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
    case codexCLI
    case customCommand

    var id: Self { self }

    var title: String {
        switch self {
        case .codexCLI:
            return "Codex CLI"
        case .customCommand:
            return "Custom command"
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

struct AppSettings: Codable {
    var shortcut: KeyboardShortcut = .default
    var recordingMode: RecordingMode = .toggle
    var selectedEngine: TranscriptionEngineKind = .codexCLI
    var codexModel: String = "gpt-5"
    var codexCommandTemplate: String =
        #"codex exec -m "{model}" "Transcribe the spoken content from the audio file at {audio_path}. Return only the transcript text.""#
    var customCommandTemplate: String = ""
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
