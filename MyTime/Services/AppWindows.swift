import AppKit
import SwiftUI

extension Notification.Name {
    static let showMainWindow = Notification.Name("MyTime.showMainWindow")
}

/// MyTime lives in the menu bar; it only gets a Dock icon while the main window is open.
enum AppWindows {
    static let mainID = "main"

    static func requestMainWindow() {
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
    }

    @MainActor
    static func mainWindowDidAppear() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    @MainActor
    static func mainWindowDidDisappear() {
        NSApp.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launching MyTime again (Spotlight, Finder, `open`) shows the main window —
    /// a fallback for when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindows.requestMainWindow()
        return false
    }
}
