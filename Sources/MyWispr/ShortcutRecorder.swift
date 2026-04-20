import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: KeyboardShortcut

    @State private var isCapturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(isCapturing ? "Press shortcut…" : shortcut.displayText) {
            beginCapture()
        }
        .monospacedDigit()
        .onDisappear {
            endCapture()
        }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let captured = KeyboardShortcut.from(event: event) else {
                return nil
            }

            shortcut = captured
            endCapture()
            return nil
        }
    }

    private func endCapture() {
        isCapturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
