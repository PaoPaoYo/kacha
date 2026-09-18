import CoreGraphics
import Foundation

/// 钉图窗口的拖拽方位：四角 + 四边（边缘 hover 命中与等比缩放锚定共用）
enum PinEdge {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

extension PinEdge {
    /// 是否为角（两轴均为自由边；单边仅一轴自由）
    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }

    /// X 自由边符号：自由边在右 = +1（向右拖增大），在左 = -1，无 X 自由边 = 0
    var xSign: CGFloat {
        switch self {
        case .topRight, .right, .bottomRight: return 1
        case .topLeft, .left, .bottomLeft: return -1
        case .top, .bottom: return 0
        }
    }

    /// Y 自由边符号：自由边在下 = +1（向下拖增大），在上 = -1，无 Y 自由边 = 0
    var ySign: CGFloat {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: return 1
        case .topLeft, .top, .topRight: return -1
        case .left, .right: return 0
        }
    }
}

/// 钉图等比缩放几何（纯逻辑，仅 Foundation/CoreGraphics，不依赖 AppKit）。
/// 坐标系：左上原点，与 `WindowGeometry` 的 CG 坐标一致。
enum PinGeometry {
    /// 边缘命中容差：边缘 8pt 内为拖拽区
    static let edgeTolerance: CGFloat = 8

    /// 边缘命中：点在 rect 内、距某边 ≤ edgeTolerance 返回对应边/角；
    /// 两轴都在容差内优先判角（角区优先）；内部与 rect 外返回 nil
    static func edge(at point: CGPoint, in rect: CGRect) -> PinEdge? {
        guard rect.contains(point) else { return nil }
        let nearLeft = point.x - rect.minX <= edgeTolerance
        let nearRight = rect.maxX - point.x <= edgeTolerance
        let nearTop = point.y - rect.minY <= edgeTolerance
        let nearBottom = rect.maxY - point.y <= edgeTolerance
        switch (nearTop, nearBottom, nearLeft, nearRight) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .topRight
        case (_, true, true, _): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .top
        case (_, true, _, _): return .bottom
        case (_, _, true, _): return .left
        case (_, _, _, true): return .right
        default: return nil
        }
    }

    // MARK: - 轴锚定

    /// 单轴锚定：fixedMin = 该轴 min 侧固定（自由边在另一侧）；fixedMax = max 侧固定；
    /// fixedMid = 该轴无自由边，绕窗口中线对称生长
    private enum AxisAnchor { case fixedMin, fixedMax, fixedMid }

    private static func xAnchor(_ edge: PinEdge) -> AxisAnchor {
        switch edge {
        case .topRight, .right, .bottomRight: return .fixedMin
        case .topLeft, .left, .bottomLeft: return .fixedMax
        case .top, .bottom: return .fixedMid
        }
    }

    private static func yAnchor(_ edge: PinEdge) -> AxisAnchor {
        switch edge {
        case .bottomLeft, .bottom, .bottomRight: return .fixedMin
        case .topLeft, .top, .topRight: return .fixedMax
        case .left, .right: return .fixedMid
        }
    }

    /// 锚定坐标：窗口在该轴上保持不动的点
    private static func anchorCoordinate(_ anchor: AxisAnchor, lo: CGFloat, hi: CGFloat) -> CGFloat {
        switch anchor {
        case .fixedMin: return lo
        case .fixedMax: return hi
        case .fixedMid: return (lo + hi) / 2
        }
    }

    /// 锚定坐标 + 新跨度 → 该轴新 origin
    private static func anchoredOrigin(_ anchor: AxisAnchor, fixed: CGFloat, size: CGFloat) -> CGFloat {
        switch anchor {
        case .fixedMin: return fixed
        case .fixedMax: return fixed - size
        case .fixedMid: return fixed - size / 2
        }
    }

    /// 锚定后不越出 [lo, hi] 的最大跨度
    private static func maxSpan(_ anchor: AxisAnchor, fixed: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        switch anchor {
        case .fixedMin: return hi - fixed
        case .fixedMax: return fixed - lo
        case .fixedMid: return 2 * min(fixed - lo, hi - fixed)
        }
    }

    /// 等比缩放：以 edge 的对边/对角为锚点，主轴拖动量按 aspect（w/h）换算两轴新尺寸，
    /// clamp minSize 与 bounds（均保比例），返回新窗口 frame（锚点坐标不变）。
    /// - Parameters:
    ///   - from: 当前窗口 frame（与 bounds 同一坐标空间）
    ///   - by: 自由边拖动量（向外为正，向内为负）
    ///   - bounds: 屏幕尺寸（屏原点视为 0,0，与 from 同空间）
    ///
    /// 锚定规则：角 → 对角点固定；单边 → 对边固定、另一轴绕窗口中线对称生长。
    /// 主轴选择：单边取其唯一自由轴；角取相对拖动量（|drag|/边长）更大的轴，平局取宽。
    /// 比例恒等于 aspect：clamp 归结为对宽度的一元区间夹取，冲突时最小尺寸优先。
    static func resized(
        from: CGRect,
        by drag: CGSize,
        edge: PinEdge,
        aspect: CGFloat,
        minSize: CGSize,
        bounds: CGSize
    ) -> CGRect {
        precondition(aspect > 0, "aspect 必须为正")
        precondition(minSize.width > 0 && minSize.height > 0, "minSize 必须为正")
        precondition(from.width > 0 && from.height > 0, "from 必须为非空 frame")
        let screen = CGRect(origin: .zero, size: bounds)
        let xa = xAnchor(edge)
        let ya = yAnchor(edge)

        // 主轴驱动（保比例只需解宽度）
        let wCandidate = from.width + edge.xSign * drag.width
        let hCandidate = from.height + edge.ySign * drag.height
        let drivenW: CGFloat
        switch (edge.xSign == 0, edge.ySign == 0) {
        case (true, false):
            drivenW = hCandidate * aspect
        case (false, true):
            drivenW = wCandidate
        case (false, false):
            drivenW = abs(drag.height) / from.height > abs(drag.width) / from.width
                ? hCandidate * aspect
                : wCandidate
        case (true, true):
            preconditionFailure("PinEdge 必须至少一轴自由")
        }

        // 保比例 clamp：解 W ∈ [wMin, wMax]
        // wMin = max(minW, minH·aspect) 使两轴最小同时满足；wMax = min(maxW, maxH·aspect) 使屏内同时满足
        let xFixed = anchorCoordinate(xa, lo: from.minX, hi: from.maxX)
        let yFixed = anchorCoordinate(ya, lo: from.minY, hi: from.maxY)
        let wMin = max(minSize.width, minSize.height * aspect)
        let wMax = min(
            maxSpan(xa, fixed: xFixed, lo: screen.minX, hi: screen.maxX),
            maxSpan(ya, fixed: yFixed, lo: screen.minY, hi: screen.maxY) * aspect
        )
        // 先夹上界再夹下界：屏内空间小于最小尺寸时保最小（钉图始终可拖）
        let w = max(min(drivenW, wMax), wMin)
        let h = w / aspect
        return CGRect(
            x: anchoredOrigin(xa, fixed: xFixed, size: w),
            y: anchoredOrigin(ya, fixed: yFixed, size: h),
            width: w,
            height: h
        )
    }
}
