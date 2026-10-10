import AppKit

/// 令牌由引用对象管理，避免 SwiftUI @State 的历史值留住已经移除的 observer。
/// handler 不应捕获拥有这个对象的视图；调用方只借用独立状态。
@MainActor
final class LocalEventMonitor {
    private var token: Any?
    var isActive: Bool { token != nil }

    func start(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        guard let token else { return }
        self.token = nil
        NSEvent.removeMonitor(token)
    }

    isolated deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}

@MainActor
enum CaptureWindowLifecycle {
    /// orderOut 只隐藏窗口；主动断开 first responder、宿主视图与图层的图片引用。
    static func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.makeFirstResponder(nil)
        panel.initialFirstResponder = nil
        if let content = panel.contentView { releaseImages(in: content) }
        panel.contentView = nil
        panel.close()
    }

    private static func releaseImages(in view: NSView) {
        (view as? CaptureBitmapView)?.image = nil
        (view as? CaptureAnnotationBitmapView)?.clear()
        view.layer?.contents = nil
        for child in view.subviews { releaseImages(in: child) }
    }
}
