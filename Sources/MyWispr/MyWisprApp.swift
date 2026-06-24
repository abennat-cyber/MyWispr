import AppKit
import Combine
import SwiftUI

private final class MyWisprUtilityWindow: NSWindow {
    var zoomShortcutHandler: ((CGFloat) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let character = event.charactersIgnoringModifiers
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch character {
        case "+", "=":
            zoomShortcutHandler?(1.12)
            return true
        case "-":
            zoomShortcutHandler?(0.88)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static weak var sharedDelegate: AppDelegate?
    private static var sharedObjects: (settingsStore: SettingsStore, model: AppModel)?

    private var statusItem: NSStatusItem?
    private var menuWindow: NSWindow?
    private var meetingSetupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuHostingController: NSHostingController<AnyView>?
    private var meetingSetupHostingController: NSHostingController<AnyView>?
    private var settingsHostingController: NSHostingController<AnyView>?
    private var statusObservation: AnyCancellable?

    private var settingsStore: SettingsStore?
    private var model: AppModel?
    private var windowObserver: NSObjectProtocol?

    static func installSharedObjects(settingsStore: SettingsStore, model: AppModel) {
        sharedObjects = (settingsStore, model)
        sharedDelegate?.configureSharedObjects(settingsStore: settingsStore, model: model)
    }

    static func showMeetingSetupWindow() {
        sharedDelegate?.presentMeetingSetupWindow()
    }

    static func closeMeetingSetupWindow() {
        sharedDelegate?.meetingSetupWindow?.close()
    }

    static func showSettingsWindow() {
        sharedDelegate?.presentSettingsWindow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.sharedDelegate = self
        NSApplication.shared.setActivationPolicy(.accessory)
        if let sharedObjects = Self.sharedObjects {
            configureSharedObjects(settingsStore: sharedObjects.settingsStore, model: sharedObjects.model)
        } else {
            configureStatusItem(symbolName: "waveform.badge.mic")
        }
        showOnboardingIfNeeded()
        observeUtilityWindows()
    }

    private func configureSharedObjects(settingsStore: SettingsStore, model: AppModel) {
        self.settingsStore = settingsStore
        self.model = model
        configureStatusItem(symbolName: symbolName(for: model.status, meetingStatus: model.meetingStatus))
        refreshHostedWindowContent()

        statusObservation = Publishers.CombineLatest(model.$status, model.$meetingStatus)
            .sink { [weak self] status, meetingStatus in
                self?.updateStatusItemIcon(symbolName: self?.symbolName(for: status, meetingStatus: meetingStatus) ?? "waveform.badge.mic")
            }
    }

    private func refreshHostedWindowContent() {
        guard let settingsStore, let model else { return }

        if let menuWindow {
            let rootView = AnyView(
                MenuBarView()
                    .environmentObject(settingsStore)
                    .environmentObject(model)
            )
            if let menuHostingController {
                menuHostingController.rootView = rootView
            } else {
                let hostingController = NSHostingController(rootView: rootView)
                if #available(macOS 13.0, *) {
                    hostingController.sizingOptions = [.minSize]
                }
                menuHostingController = hostingController
                menuWindow.contentViewController = hostingController
            }
        }

        if let meetingSetupWindow {
            let rootView = AnyView(
                MeetingSetupView()
                    .environmentObject(model)
            )
            if let meetingSetupHostingController {
                meetingSetupHostingController.rootView = rootView
            } else {
                let hostingController = NSHostingController(rootView: rootView)
                if #available(macOS 13.0, *) {
                    hostingController.sizingOptions = [.minSize]
                }
                meetingSetupHostingController = hostingController
                meetingSetupWindow.contentViewController = hostingController
            }
        }

        if let settingsWindow {
            let rootView = AnyView(
                SettingsView()
                    .environmentObject(settingsStore)
                    .environmentObject(model)
            )
            if let settingsHostingController {
                settingsHostingController.rootView = rootView
            } else {
                let hostingController = NSHostingController(rootView: rootView)
                if #available(macOS 13.0, *) {
                    hostingController.sizingOptions = [.minSize]
                }
                settingsHostingController = hostingController
                settingsWindow.contentViewController = hostingController
            }
        }
    }

    private func configureStatusItem(symbolName: String) {
        if statusItem == nil {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.target = self
            statusItem.button?.action = #selector(toggleMenuWindow(_:))
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem.button?.toolTip = "MyWispr"
            self.statusItem = statusItem
        }

        updateStatusItemIcon(symbolName: symbolName)
    }

    private func updateStatusItemIcon(symbolName: String) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "MyWispr"
        )
    }

    @objc
    private func toggleMenuWindow(_ sender: Any?) {
        if let menuWindow, menuWindow.isVisible {
            menuWindow.orderOut(nil)
            return
        }

        presentMenuWindow()
    }

    private func presentMenuWindow() {
        let window = makeMenuWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentMeetingSetupWindow() {
        let window = makeMeetingSetupWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentSettingsWindow() {
        let window = makeSettingsWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMenuWindowIfNeeded() -> NSWindow {
        if let menuWindow {
            return menuWindow
        }

        let window = MyWisprUtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyWispr"
        window.identifier = NSUserInterfaceItemIdentifier("com.abennat.mywispr.menu-window")
        window.delegate = self
        window.minSize = NSSize(width: 320, height: 360)
        configureUtilityDefaults(window)
        if !window.setFrameUsingName("MyWisprMenuWindow") {
            positionWindowNearStatusItem(window)
        }
        window.setFrameAutosaveName("MyWisprMenuWindow")

        menuWindow = window
        refreshHostedWindowContent()
        return window
    }

    private func makeMeetingSetupWindowIfNeeded() -> NSWindow {
        if let meetingSetupWindow {
            return meetingSetupWindow
        }

        let window = MyWisprUtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Record Meeting"
        window.identifier = NSUserInterfaceItemIdentifier("com.abennat.mywispr.meeting-setup")
        window.delegate = self
        window.minSize = NSSize(width: 380, height: 360)
        configureUtilityDefaults(window)
        window.center()

        meetingSetupWindow = window
        refreshHostedWindowContent()
        return window
    }

    private func makeSettingsWindowIfNeeded() -> NSWindow {
        if let settingsWindow {
            return settingsWindow
        }

        let window = MyWisprUtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyWispr Settings"
        window.identifier = NSUserInterfaceItemIdentifier("com.abennat.mywispr.settings")
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 520)
        configureUtilityDefaults(window)
        if !window.setFrameUsingName("MyWisprSettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MyWisprSettingsWindow")

        settingsWindow = window
        refreshHostedWindowContent()
        return window
    }

    private func configureUtilityDefaults(_ window: MyWisprUtilityWindow) {
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.zoomShortcutHandler = { [weak self, weak window] scale in
            guard let window else { return }
            self?.model?.adjustUtilityWindowZoom(by: scale)
            Self.resize(window, by: scale)
        }
    }

    private func positionWindowNearStatusItem(_ window: NSWindow) {
        guard
            let button = statusItem?.button,
            let buttonWindow = button.window
        else {
            window.center()
            return
        }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        let width = window.frame.width
        let height = window.frame.height
        let x = max(screenFrame.maxX - width, 16)
        let y = screenFrame.minY - height - 8
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func resize(_ window: NSWindow, by scale: CGFloat) {
        let currentFrame = window.frame
        let minSize = window.minSize
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        let maxWidth = screenFrame?.width ?? 1_200
        let maxHeight = screenFrame?.height ?? 900
        let targetWidth = min(max(currentFrame.width * scale, minSize.width), maxWidth)
        let targetHeight = min(max(currentFrame.height * scale, minSize.height), maxHeight)

        let deltaWidth = targetWidth - currentFrame.width
        let deltaHeight = targetHeight - currentFrame.height
        var targetFrame = NSRect(
            x: currentFrame.origin.x - deltaWidth / 2,
            y: currentFrame.origin.y - deltaHeight / 2,
            width: targetWidth,
            height: targetHeight
        )

        if let screenFrame {
            targetFrame.origin.x = min(max(targetFrame.origin.x, screenFrame.minX), screenFrame.maxX - targetFrame.width)
            targetFrame.origin.y = min(max(targetFrame.origin.y, screenFrame.minY), screenFrame.maxY - targetFrame.height)
        }

        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func observeUtilityWindows() {
        let center = NotificationCenter.default
        let mainQueue = OperationQueue.main

        let handler: @Sendable (Notification) -> Void = { notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                Self.configureUtilityWindow(window)
            }
        }

        windowObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: mainQueue,
            using: handler
        )
    }

    @MainActor
    private static func configureUtilityWindow(_ window: NSWindow) {
        let title = window.title
        let identifier = window.identifier?.rawValue ?? ""
        let isUtilityWindow = title == "MyWispr"
            || title == "Settings"
            || title == "Record Meeting"
            || identifier == "com.apple.SwiftUI.Settings"
        guard isUtilityWindow else { return }

        if window.level != .floating {
            window.level = .floating
        }

        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !window.collectionBehavior.isSuperset(of: behavior) {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === meetingSetupWindow {
            model?.cancelMeetingSetup()
        }
    }

    private func symbolName(for status: AppStatus, meetingStatus: AppModel.MeetingStatus) -> String {
        let meetingIsRecording: Bool
        switch meetingStatus {
        case .recording:
            meetingIsRecording = true
        default:
            meetingIsRecording = false
        }

        let meetingIsTranscribing: Bool
        switch meetingStatus {
        case .transcribing:
            meetingIsTranscribing = true
        default:
            meetingIsTranscribing = false
        }

        if status == .recording || meetingIsRecording {
            return "record.circle.fill"
        }

        if status == .transcribing || meetingIsTranscribing {
            return "ellipsis.circle"
        }

        switch status {
        case .idle:
            return "waveform.badge.mic"
        case .succeeded:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .recording, .transcribing:
            return "waveform.badge.mic"
        }
    }

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

@MainActor
@main
struct MyWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var model: AppModel

    init() {
        let settingsStore = SettingsStore()
        let model = AppModel(settingsStore: settingsStore)
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _model = StateObject(wrappedValue: model)
        AppDelegate.installSharedObjects(settingsStore: settingsStore, model: model)
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(settingsStore)
                .environmentObject(model)
        }
    }
}
