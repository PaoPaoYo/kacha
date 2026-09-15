import AppKit
import SwiftUI

@main
struct KachaApp: App {
    var body: some Scene {
        MenuBarExtra("咔嚓", systemImage: "camera.viewfinder") {
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
    }
}
