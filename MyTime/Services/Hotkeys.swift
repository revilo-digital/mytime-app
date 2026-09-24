import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let showTimer = Self("showTimer", initial: .init(.t, modifiers: [.command, .option]))
    static let toggleTimer = Self("toggleTimer", initial: .init(.s, modifiers: [.command, .option]))
}

@MainActor
enum Hotkeys {
    static func register(timer: TimerService) {
        KeyboardShortcuts.onKeyUp(for: .showTimer) {
            MainActor.assumeIsolated { showTimerPopover() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleTimer) {
            MainActor.assumeIsolated { timer.toggleLast() }
        }
    }

    /// SwiftUI can't open a MenuBarExtra programmatically, so click its status item.
    /// If the icon is hidden (e.g. behind the notch), fall back to the main window.
    static func showTimerPopover() {
        let button = NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap { $0.contentView?.firstDescendant(of: NSStatusBarButton.self) }
            .first
        if let button, button.window?.isVisible == true, button.window?.occlusionState.contains(.visible) == true {
            button.performClick(nil)
        } else {
            AppWindows.requestMainWindow()
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for sub in subviews {
            if let match = sub.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
