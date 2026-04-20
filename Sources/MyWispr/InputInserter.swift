import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class InputInserter {
    func insert(_ text: String, targeting app: NSRunningApplication?) async -> InsertionResult {
        _ = app?.activate(options: [])
        try? await Task.sleep(for: .milliseconds(150))

        let textToInsert = prependSpaceIfNeeded(applyBidiIfNeeded(text))

        if AXIsProcessTrusted(), type(textToInsert) {
            return .typed
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToInsert, forType: .string)

        if AXIsProcessTrusted(), paste() {
            return .pasted
        }

        return .clipboardOnly
    }

    // Detects whether the text is predominantly RTL (e.g. Hebrew, Arabic) and,
    // if so, wraps it in Unicode RLI/PDI isolate markers so that "weak"
    // punctuation characters (. ? ! ,) render on the correct (left) side.
    private func applyBidiIfNeeded(_ text: String) -> String {
        guard isRTLDominant(text) else { return text }
        // U+2067 RIGHT-TO-LEFT ISOLATE, U+2069 POP DIRECTIONAL ISOLATE
        // These are the safest modern bidi controls: they scope the effect to
        // this run only, without affecting surrounding text directionality.
        return "\u{2067}\(text)\u{2069}"
    }

    private func isRTLDominant(_ text: String) -> Bool {
        var rtlCount = 0
        var ltrCount = 0
        for scalar in text.unicodeScalars {
            if isRTLScalar(scalar) { rtlCount += 1 }
            else if isLTRScalar(scalar) { ltrCount += 1 }
        }
        return rtlCount > 0 && rtlCount >= ltrCount
    }

    private func isRTLScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0590 && v <= 0x05FF)   // Hebrew
            || (v >= 0x0600 && v <= 0x06FF)   // Arabic
            || (v >= 0x0700 && v <= 0x074F)   // Syriac
            || (v >= 0x0750 && v <= 0x077F)   // Arabic Supplement
            || (v >= 0x08A0 && v <= 0x08FF)   // Arabic Extended-A
            || (v >= 0xFB1D && v <= 0xFDFF)   // Hebrew/Arabic Presentation Forms
            || (v >= 0xFE70 && v <= 0xFEFF)   // Arabic Presentation Forms-B
    }

    private func isLTRScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0041 && v <= 0x005A)   // A-Z
            || (v >= 0x0061 && v <= 0x007A)   // a-z
            || (v >= 0x00C0 && v <= 0x024F)   // Latin Extended
    }

    // Checks the focused element's selected text range via AX to determine
    // whether the character immediately before the cursor is a non-space.
    // If so, prepends a space so dictation doesn't run into existing text.
    private func prependSpaceIfNeeded(_ text: String) -> String {
        guard AXIsProcessTrusted() else { return text }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return text }

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let cfRange = rangeValue else { return text }

        var range = CFRange()
        AXValueGetValue(cfRange as! AXValue, .cfRange, &range)

        // If cursor is at position 0 there's nothing before it
        guard range.location > 0 else { return text }

        // Read the character just before the cursor
        var beforeRange = CFRangeMake(range.location - 1, 1)
        guard let axRange = AXValueCreate(.cfRange, &beforeRange) else { return text }

        var charValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element as! AXUIElement,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &charValue
        ) == .success,
              let char = charValue as? String,
              !char.isEmpty else { return text }

        // Only prepend a space if the preceding character is not whitespace
        let precedingChar = Character(char)
        if !precedingChar.isWhitespace {
            return " " + text
        }
        return text
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
