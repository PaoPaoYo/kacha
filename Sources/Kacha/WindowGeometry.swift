import CoreGraphics
import Foundation

/// CGWindow 全局坐标（左上原点）与屏幕局部坐标换算、悬停命中（纯逻辑，不依赖 AppKit）
enum WindowGeometry {
    /// 屏幕 CG 全局原点：AppKit frame（左下原点）→ CG 全局（左上原点）
    /// 公式：x = frame.minX，y = totalHeight - frame.maxY（totalHeight = 所有屏 frame.maxY 的最大值）
    static func screenOriginGlobalCG(frame: CGRect, totalHeight: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX, y: totalHeight - frame.maxY)
    }

    /// 窗口 CG 全局矩形 → 本屏局部矩形（左上原点）
    static func localRect(window: CGRect, screenFrame: CGRect, totalHeight: CGFloat) -> CGRect {
        let origin = screenOriginGlobalCG(frame: screenFrame, totalHeight: totalHeight)
        return window.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// Z 序命中：windows 为 front-to-back 顺序的局部坐标矩形，返回首个包含 point 的（= 最上层）
    static func hitTest(point: CGPoint, windows: [CGRect]) -> CGRect? {
        windows.first { $0.contains(point) }
    }

    /// 与屏幕求交集；不相交返回 nil
    static func clampedToScreen(_ rect: CGRect, screenBounds: CGRect) -> CGRect? {
        rect.intersection(screenBounds).isNull ? nil : rect.intersection(screenBounds)
    }
}
