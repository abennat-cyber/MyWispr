import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class InputInserter {
    func insert(_ text: String, targeting app: NSRunningApplication?) async -> InsertionResult {
        _ = app?.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(150))

        if AXIsProcessTrusted(), type(text) {
            return .typed
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if AXIsProcessTrusted(), paste() {
            return .pasted
        }

        return .clipboardOnly
    }

    private func type(_ text: String) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return false
        }

        var scalars = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: &scalars)
        keyUp.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: &scalars)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func paste() -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
