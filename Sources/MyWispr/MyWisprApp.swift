import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct MyWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var model: AppModel

    init() {
        let settingsStore = SettingsStore()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _model = StateObject(wrappedValue: AppModel(settingsStore: settingsStore))
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(settingsStore)
                .environmentObject(model)
        }

        MenuBarExtra("MyWispr", systemImage: symbolName) {
            MenuBarView()
                .environmentObject(settingsStore)
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }

    private var symbolName: String {
        switch model.status {
        case .idle:
            return "waveform.badge.mic"
        case .recording:
            return "record.circle.fill"
        case .transcribing:
            return "ellipsis.circle"
        case .succeeded:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}
