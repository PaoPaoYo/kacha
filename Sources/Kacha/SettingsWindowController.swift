import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let appDelegate: AppDelegate
    private(set) var window: NSWindow?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(appDelegate: appDelegate)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayout.minimumWidth,
                height: SettingsLayout.minimumHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(
            width: SettingsLayout.minimumWidth,
            height: SettingsLayout.minimumHeight
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
