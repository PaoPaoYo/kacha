import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct KachaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("咔嚓", systemImage: "camera.viewfinder") {
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
        Toggle(
            "开机自启",
            isOn: Binding(
                get: { appDelegate.launchAtLogin },
                set: { appDelegate.setLaunchAtLogin($0) }
            )
        )
        Divider()
        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// 唯一事实源是 SMAppService.mainApp.status；此属性仅为菜单渲染镜像
    @Published private(set) var launchAtLogin: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(controlKey | cmdKey)
        ) {
            Task { await CaptureCoordinator.shared.start() }
        }
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
}
