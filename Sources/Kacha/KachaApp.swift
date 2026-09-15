import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct KachaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("咔嚓", systemImage: "camera.viewfinder") {
            Button("截屏  ⌃⌘A") {
                Task { await CaptureCoordinator.shared.start() }
            }
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(controlKey | cmdKey)
        ) {
            Task { await CaptureCoordinator.shared.start() }
        }
    }
}
