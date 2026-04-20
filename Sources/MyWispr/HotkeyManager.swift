import Carbon
import Combine
import Foundation

@MainActor
final class HotkeyManager: ObservableObject {
    var onShortcutPressed: (() -> Void)?
    var onShortcutReleased: (() -> Void)?

    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4D595750), id: 1)

    init(currentShortcut: KeyboardShortcut, settingsPublisher: Published<AppSettings>.Publisher) {
        installHandler()
        register(shortcut: currentShortcut)

        settingsPublisher
            .map(\.shortcut)
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.register(shortcut: shortcut)
            }
            .store(in: &cancellables)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event: event)
            },
            2,
            &eventTypes,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )
    }

    private func handle(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.id == self.hotKeyID.id else {
            return noErr
        }

        let eventKind = GetEventKind(event)
        if eventKind == UInt32(kEventHotKeyPressed) {
            onShortcutPressed?()
        } else if eventKind == UInt32(kEventHotKeyReleased) {
            onShortcutReleased?()
        }

        return noErr
    }

    private func register(shortcut: KeyboardShortcut) {
        unregister()

        RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
