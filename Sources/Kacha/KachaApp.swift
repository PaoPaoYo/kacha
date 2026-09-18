import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct KachaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Settings {
            SettingsView(appDelegate: appDelegate)
        }

        MenuBarExtra("咔嚓", systemImage: "camera.viewfinder", isInserted: $showMenuBarIcon) {
            MenuContent(appDelegate: appDelegate)
        }
    }
}

/// 菜单内容独立成子视图：以 @ObservedObject 订阅 AppDelegate，
/// 开机自启开关回读修正后菜单项能即时刷新
private struct MenuContent: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        Button("截屏  ⌃⌘A") {
            Task { await CaptureCoordinator.shared.start() }
        }
        Divider()
        SettingsLink {
            Text("设置…")
        }
        Divider()
        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// 唯一事实源是 SMAppService.mainApp.status；此属性仅为设置视图渲染镜像
    @Published private(set) var launchAtLogin = false
    @Published private(set) var hotKeyPreferences = HotKeyPreferences.defaultHotKey

    override init() {
        UserDefaults.standard.register(defaults: ["showMenuBarIcon": true])
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        hotKeyPreferences = HotKeyPreferences.load()
        registerHotKey()

        if !UserDefaults.standard.bool(forKey: "hasLaunchedOnce") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedOnce")
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !UserDefaults.standard.bool(forKey: "showMenuBarIcon") else { return true }
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// app 终止全清钉图窗（orderOut + 释放引用）
    func applicationWillTerminate(_ notification: Notification) {
        PinWindowController.shared.closeAll()
    }

    /// 开关开机自启：register/unregister 失败被吞掉后必须回读系统 status 修正镜像，避免静默错位
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        if enabled {
            try? service.register()
        } else {
            try? service.unregister()
        }
        launchAtLogin = (service.status == .enabled)
    }

    func updateHotKey(_ preferences: HotKeyPreferences) {
        preferences.save()
        hotKeyPreferences = preferences
        registerHotKey()
    }

    private func registerHotKey() {
        HotKeyCenter.shared.register(
            keyCode: hotKeyPreferences.keyCode,
            modifiers: hotKeyPreferences.modifiers
        ) {
            Task { await CaptureCoordinator.shared.start() }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
