import AppKit
import SwiftUI

final class LaunchHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct LaunchHUDPresentation: Equatable {
    let title: String
    let message: String
    let isWarning: Bool
}

@MainActor
final class LaunchHUDController {
    private let panel = makePanel()
    private var dismissTask: Task<Void, Never>?

    static func makePanel() -> LaunchHUDPanel {
        let panel = LaunchHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    static func frame(in visibleFrame: CGRect, panelSize: CGSize) -> CGRect {
        CGRect(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - 56 - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    static func presentation(
        hotKey: HotKeyPreferences,
        hotKeyErrorMessage: String?
    ) -> LaunchHUDPresentation {
        if hotKeyErrorMessage != nil {
            return LaunchHUDPresentation(
                title: "咔嚓已启动",
                message: "快捷键注册失败，请打开设置",
                isWarning: true
            )
        }
        return LaunchHUDPresentation(
            title: "咔嚓已启动",
            message: "按 \(hotKey.displayString) 开始截图",
            isWarning: false
        )
    }

    func show(hotKey: HotKeyPreferences, hotKeyErrorMessage: String?) {
        dismissTask?.cancel()
        let size = CGSize(width: 280, height: 72)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        panel.contentView = NSHostingView(rootView: LaunchHUDView(
            presentation: Self.presentation(hotKey: hotKey, hotKeyErrorMessage: hotKeyErrorMessage)
        ))
        panel.setFrame(Self.frame(in: screen.visibleFrame, panelSize: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    self.panel.orderOut(nil)
                }
            }
        }
    }
}

private struct LaunchHUDView: View {
    let presentation: LaunchHUDPresentation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presentation.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(presentation.isWarning ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(presentation.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 280, height: 72)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14))
    }
}
