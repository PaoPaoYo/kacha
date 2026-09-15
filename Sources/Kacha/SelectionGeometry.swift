import CoreGraphics
import Foundation

/// 框选的纯几何换算：屏幕局部 point ↔ 截图帧像素。
/// 不依赖 AppKit（可单元测试）；坐标系约定：左上原点。
enum SelectionGeometry {
    /// 有效选区最小边长（point）
    static let minimumSize: CGFloat = 4

    /// 任意方向拖拽归一化为正宽高矩形
    static func normalize(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// 选区是否有效（宽高均 ≥ minimumSize）
    static func isValid(_ rect: CGRect) -> Bool {
        rect.width >= minimumSize && rect.height >= minimumSize
    }

    /// 屏幕局部 point 矩形 → 截图帧像素矩形。
    /// 各轴独立缩放（不假设正方形像素/整数 scale），并 clamp 到图像边界，
    /// 保证 CGImage.cropping(to:) 不会因越界返回 nil。
    static func pixelRect(pointRect: CGRect, screenPointSize: CGSize, imagePixelSize: CGSize) -> CGRect {
        guard screenPointSize.width > 0, screenPointSize.height > 0 else { return .zero }
        let scaleX = imagePixelSize.width / screenPointSize.width
        let scaleY = imagePixelSize.height / screenPointSize.height
        let x = max(0, min(pointRect.minX * scaleX, imagePixelSize.width))
        let y = max(0, min(pointRect.minY * scaleY, imagePixelSize.height))
        let maxX = max(x, min(pointRect.maxX * scaleX, imagePixelSize.width))
        let maxY = max(y, min(pointRect.maxY * scaleY, imagePixelSize.height))
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }
}
