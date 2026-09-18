import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appDelegate: AppDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var isRecording = false
    @State private var recordingMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            form
        }
        .frame(minWidth: 620, minHeight: 390)
        .onDisappear(perform: cancelRecording)
    }

    private var tabBar: some View {
        HStack {
            VStack(spacing: 5) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                Text("基础")
                    .font(.caption)
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 70, height: 54)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.quaternary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingRow("启动") {
                Toggle(
                    "在开机时启动",
                    isOn: Binding(
                        get: { appDelegate.launchAtLogin },
                        set: { appDelegate.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.checkbox)
            }

            settingRow("状态栏图标", alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(
                        "隐藏状态栏图标",
                        isOn: Binding(
                            get: { !showMenuBarIcon },
                            set: { showMenuBarIcon = !$0 }
                        )
                    )
                    .toggleStyle(.checkbox)
                    Text("再次运行咔嚓以显示状态栏图标")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingRow("快捷键") {
                HStack(spacing: 10) {
                    Text(isRecording ? "按下新组合…" : appDelegate.hotKeyPreferences.displayString)
                        .frame(minWidth: 86, alignment: .leading)
                    Button(isRecording ? "取消" : "录制") {
                        isRecording ? cancelRecording() : beginRecording()
                    }
                    Button("恢复默认") {
                        cancelRecording()
                        appDelegate.updateHotKey(.defaultHotKey)
                    }
                }
            }
        }
        .padding(.horizontal, 124)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func settingRow<Content: View>(
        _ title: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 18) {
            Text(title)
                .frame(width: 100, alignment: .trailing)
            content()
        }
    }

    private func beginRecording() {
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                cancelRecording()
            } else if let preferences = HotKeyRecording.combination(
                keyCode: event.keyCode,
                eventFlags: event.modifierFlags
            ) {
                appDelegate.updateHotKey(preferences)
                cancelRecording()
            }
            return nil
        }
    }

    private func cancelRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        isRecording = false
    }
}

enum HotKeyRecording {
    static func carbonModifiers(from eventFlags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if eventFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if eventFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if eventFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if eventFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    static func combination(
        keyCode: UInt16,
        eventFlags: NSEvent.ModifierFlags
    ) -> HotKeyPreferences? {
        let modifiers = carbonModifiers(from: eventFlags)
        guard HotKeyPreferences.isValidCombination(modifiers: modifiers) else { return nil }
        return HotKeyPreferences(keyCode: UInt32(keyCode), modifiers: modifiers)
    }
}
