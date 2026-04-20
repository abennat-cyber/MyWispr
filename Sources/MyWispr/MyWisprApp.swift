import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        showOnboardingIfNeeded()
        observeSettingsWindow()
    }

    // Observes window visibility events and elevates the Settings window to
    // .floating level so it stays above other apps. We watch both
    // didBecomeKey (user opens settings) and willBeVisible (window shown
    // programmatically) and apply the level on the next run-loop tick to
    // ensure SwiftUI has finished constructing the window hierarchy.
    private func observeSettingsWindow() {
        let center = NotificationCenter.default
        let mainQueue = OperationQueue.main

        let handler: @Sendable (Notification) -> Void = { notification in
            guard let window = notification.object as? NSWindow else { return }
            // Run on main actor to safely access NSWindow properties
            Task { @MainActor in
                Self.elevateIfSettings(window)
            }
        }

        windowObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: mainQueue,
            using: handler
        )
        center.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: mainQueue,
            using: handler
        )
    }

    @MainActor
    private static func elevateIfSettings(_ window: NSWindow) {
        let title = window.title
        let identifier = window.identifier?.rawValue ?? ""
        let isSettings = title == "MyWispr"
            || title == "Settings"
            || identifier == "com.apple.SwiftUI.Settings"
        guard isSettings else { return }
        DispatchQueue.main.async {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @MainActor
    private func showOnboardingIfNeeded() {
        let done = UserDefaults.standard.bool(forKey: "onboardingComplete")
        let whisperReady = LocalWhisperService.resolveBinaryPath() != nil
        let modelReady = LocalWhisperService.mediumModelReady
        guard !done || !whisperReady || !modelReady else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Setup"
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        case .idle:          return "waveform.badge.mic"
        case .recording:     return "record.circle.fill"
        case .transcribing:  return "ellipsis.circle"
        case .succeeded:     return "checkmark.circle"
        case .failed:        return "exclamationmark.triangle"
        }
    }
}
