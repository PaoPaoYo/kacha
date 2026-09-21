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
        window.minSize = NSSize(
            width: SettingsLayout.minimumWidth,
            height: SettingsLayout.minimumHeight
        )
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
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        let contentView = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayout.minimumWidth,
                height: SettingsLayout.minimumHeight
            )
        )
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.contentView = contentView
        window.minSize = NSSize(
            width: SettingsLayout.minimumWidth,
            height: SettingsLayout.minimumHeight
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
