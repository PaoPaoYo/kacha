import CoreGraphics
import Foundation

/// 标注颜色（RGBA 分量，0-1）
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let red = RGBA(r: 1, g: 0.231, b: 0.188, a: 1)        // #FF3B30
    static let orange = RGBA(r: 1, g: 0.584, b: 0, a: 1)         // #FF9500
    static let yellow = RGBA(r: 1, g: 0.8, b: 0, a: 1)           // #FFCC00
    static let green = RGBA(r: 0.204, g: 0.78, b: 0.349, a: 1)   // #34C759
    static let blue = RGBA(r: 0, g: 0.478, b: 1, a: 1)           // #007AFF
    static let purple = RGBA(r: 0.686, g: 0.322, b: 0.871, a: 1) // #AF52DE
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

/// 标注工具；非 select 激活时接管选区内拖动为绘制
enum AnnotationTool: Equatable {
    case select, arrow, rect, ellipse, pen, mosaic
    var takesOverDrag: Bool { self != .select }
}

/// 粗细三档（pt）
enum AnnotationWidth: CaseIterable {
    case thin, medium, thick
    var pt: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 8
        }
    }
    /// 工具栏示意圆点直径
    var dotDiameter: CGFloat {
        switch self {
        case .thin: 4
        case .medium: 6
        case .thick: 9
        }
    }
}

/// 一笔标注。几何为归一化坐标（0-1，相对选区）：选区移动/缩放时标注跟随；
/// lineWidth 为绝对 pt，不随选区缩放。
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow(start: CGPoint, end: CGPoint)  // 归一化
        case rect(CGRect)                         // 归一化
        case ellipse(CGRect)                      // 归一化
        case pen(points: [CGPoint])               // 归一化
        case mosaic(points: [CGPoint])            // 归一化（复用 pen 采样/去重/有效性；颜色不参与渲染）
    }

    let id: UUID
    var kind: Kind
    var color: RGBA
    var lineWidth: CGFloat

    init(kind: Kind, color: RGBA, lineWidth: CGFloat) {
        self.id = UUID()
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// 标注几何（纯逻辑，单测覆盖；预览与像素合成共用）
enum AnnotationGeometry {
    /// 局部 point → 归一化（clamp 到 [0,1]）
    static func normalizedPoint(_ p: CGPoint, in selection: CGRect) -> CGPoint {
        guard selection.width > 0, selection.height > 0 else { return .zero }
        let x = max(0, min((p.x - selection.minX) / selection.width, 1))
        let y = max(0, min((p.y - selection.minY) / selection.height, 1))
        return CGPoint(x: x, y: y)
    }

    /// 归一化 → 局部 point（按目标选区）
    static func localPoint(_ n: CGPoint, in selection: CGRect) -> CGPoint {
        CGPoint(x: selection.minX + n.x * selection.width,
                y: selection.minY + n.y * selection.height)
    }

    /// 箭头头长（pt）：max(3 × lineWidth, 10)；头半角 15°
    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(3 * lineWidth, 10)
    }

    /// pen 采样去重：与上一点距离 > 1pt 才记录（首点恒记录）
    static func shouldAppendPenPoint(_ p: CGPoint, after last: CGPoint?) -> Bool {
        guard let last else { return true }
        return hypot(p.x - last.x, p.y - last.y) > 1
    }

    /// 标注 CGPath（选区局部坐标）。箭头含线段与实心头三角两个子路径；
    /// rect/ellipse 以归一化矩形直接构建（stroke 中心线语义，由渲染层 stroke）。
    static func path(for kind: Annotation.Kind, in selection: CGRect, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case let .arrow(start, end):
            let s = localPoint(start, in: selection)
            let e = localPoint(end, in: selection)
            path.move(to: s)
            path.addLine(to: e)
            // 头三角：end 为顶点，方向沿 (e-s)，两翼张开 15°
            let dx = e.x - s.x, dy = e.y - s.y
            let len = hypot(dx, dy)
            let head = arrowHeadLength(lineWidth: lineWidth)
            if len > 1 {
                let ux = dx / len, uy = dy / len          // 单位方向
                let nx = -uy, ny = ux                      // 单位法向
                let tan15 = tan(CGFloat.pi / 12)
                let base = CGPoint(x: e.x - ux * head, y: e.y - uy * head)
                let w1 = CGPoint(x: base.x + nx * head * tan15, y: base.y + ny * head * tan15)
                let w2 = CGPoint(x: base.x - nx * head * tan15, y: base.y - ny * head * tan15)
                path.move(to: e)
                path.addLine(to: w1)
                path.addLine(to: w2)
                path.closeSubpath()
            }
        case let .rect(n):
            path.addRect(CGRect(x: selection.minX + n.minX * selection.width,
                                y: selection.minY + n.minY * selection.height,
                                width: n.width * selection.width,
                                height: n.height * selection.height))
        case let .ellipse(n):
            path.addEllipse(in: CGRect(x: selection.minX + n.minX * selection.width,
                                       y: selection.minY + n.minY * selection.height,
                                       width: n.width * selection.width,
                                       height: n.height * selection.height))
        case let .pen(points), let .mosaic(points):
            // 同构折线（stroke 语义）；mosaic 的展宽与像素块化由渲染层处理
            guard let first = points.first else { break }
            path.move(to: localPoint(first, in: selection))
            for p in points.dropFirst() {
                path.addLine(to: localPoint(p, in: selection))
            }
        }
        return path
    }

    /// 松开时有效性：太小的标注丢弃（arrow/rect/ellipse 局部最长边 < 4pt；pen/mosaic < 2 点）
    static func isValid(_ kind: Annotation.Kind, selectionSize: CGSize) -> Bool {
        let minimum: CGFloat = 4
        switch kind {
        case let .arrow(start, end):
            let dx = (end.x - start.x) * selectionSize.width
            let dy = (end.y - start.y) * selectionSize.height
            return max(abs(dx), abs(dy)) >= minimum
        case let .rect(n):
            return max(n.width * selectionSize.width, n.height * selectionSize.height) >= minimum
        case let .ellipse(n):
            return max(n.width * selectionSize.width, n.height * selectionSize.height) >= minimum
        case let .pen(points), let .mosaic(points):
            return points.count >= 2
        }
    }
}
