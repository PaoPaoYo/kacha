import CoreGraphics
import Foundation

enum AnnotationEditTarget: Equatable {
    case move
    case arrowStart
    case arrowEnd
    case resize(AnnotationResizeHandle)
}

enum AnnotationResizeHandle: CaseIterable, Hashable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

struct AnnotationEditor {
    static func hitTest(
        annotations: [Annotation],
        point: CGPoint,
        selectionSize: CGSize
    ) -> Annotation.ID? {
        annotations.reversed().first { annotation in
            isEditable(annotation) && pathContains(
                annotation: annotation,
                point: point,
                selectionSize: selectionSize
            )
        }?.id
    }

    static func target(
        at point: CGPoint,
        annotation: Annotation,
        selectionSize: CGSize
    ) -> AnnotationEditTarget? {
        guard isEditable(annotation) else { return nil }

        switch annotation.kind {
        case let .arrow(start, end):
            if isNear(point, start, selectionSize: selectionSize) { return .arrowStart }
            if isNear(point, end, selectionSize: selectionSize) { return .arrowEnd }
        case let .rect(bounds), let .ellipse(bounds):
            for handle in AnnotationResizeHandle.allCases {
                if isNear(point, handle.point(in: bounds), selectionSize: selectionSize) {
                    return .resize(handle)
                }
            }
        case .pen:
            break
        case .blur:
            return nil
        }

        return pathContains(annotation: annotation, point: point, selectionSize: selectionSize) ? .move : nil
    }

    static func transformed(
        _ annotation: Annotation,
        target: AnnotationEditTarget,
        from: CGPoint,
        to: CGPoint
    ) -> Annotation {
        guard isEditable(annotation) else { return annotation }
        let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let kind: Annotation.Kind

        switch (annotation.kind, target) {
        case let (.arrow(start, end), .move):
            let moved = translated(points: [start, end], by: delta)
            kind = .arrow(start: moved[0], end: moved[1])
        case let (.arrow(_, end), .arrowStart):
            kind = .arrow(start: clamped(to), end: end)
        case let (.arrow(start, _), .arrowEnd):
            kind = .arrow(start: start, end: clamped(to))
        case let (.rect(bounds), .move):
            kind = .rect(translated(bounds: bounds, by: delta))
        case let (.ellipse(bounds), .move):
            kind = .ellipse(translated(bounds: bounds, by: delta))
        case let (.pen(points), .move):
            kind = .pen(points: translated(points: points, by: delta))
        case let (.rect(bounds), .resize(handle)):
            kind = .rect(resized(bounds: bounds, handle: handle, to: to))
        case let (.ellipse(bounds), .resize(handle)):
            kind = .ellipse(resized(bounds: bounds, handle: handle, to: to))
        default:
            return annotation
        }

        return Annotation(id: annotation.id, kind: kind, color: annotation.color, lineWidth: annotation.lineWidth)
    }

    static func updatingStyle(_ annotation: Annotation, color: RGBA, lineWidth: CGFloat) -> Annotation {
        guard isEditable(annotation) else { return annotation }
        return Annotation(id: annotation.id, kind: annotation.kind, color: color, lineWidth: lineWidth)
    }

    static func removing(id: Annotation.ID, from annotations: [Annotation]) -> [Annotation] {
        annotations.filter { $0.id != id }
    }

    static func replacing(_ annotation: Annotation, in annotations: [Annotation]) -> [Annotation] {
        annotations.map { $0.id == annotation.id ? annotation : $0 }
    }

    private static func isEditable(_ annotation: Annotation) -> Bool {
        if case .blur = annotation.kind { return false }
        return true
    }

    private static func translated(points: [CGPoint], by delta: CGPoint) -> [CGPoint] {
        guard let bounds = bounds(of: points) else { return points }
        let limitedDelta = limiting(delta: delta, for: bounds)
        return points.map { point in
            CGPoint(x: point.x + limitedDelta.x, y: point.y + limitedDelta.y)
        }
    }

    private static func translated(bounds: CGRect, by delta: CGPoint) -> CGRect {
        let limitedDelta = limiting(delta: delta, for: bounds)
        return bounds.offsetBy(dx: limitedDelta.x, dy: limitedDelta.y)
    }

    private static func limiting(delta: CGPoint, for bounds: CGRect) -> CGPoint {
        let horizontalLimit = delta.x >= 0 ? 1 - bounds.maxX : -bounds.minX
        let verticalLimit = delta.y >= 0 ? 1 - bounds.maxY : -bounds.minY
        let scale = min(
            1,
            delta.x == 0 ? 1 : horizontalLimit / delta.x,
            delta.y == 0 ? 1 : verticalLimit / delta.y
        )
        return CGPoint(x: delta.x * scale, y: delta.y * scale)
    }

    private static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        let minX = points.map(\.x).min() ?? first.x
        let maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y
        let maxY = points.map(\.y).max() ?? first.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func resized(
        bounds: CGRect,
        handle: AnnotationResizeHandle,
        to point: CGPoint
    ) -> CGRect {
        let point = clamped(point)
        var fixedX = bounds.minX
        var movingX = bounds.maxX
        var fixedY = bounds.minY
        var movingY = bounds.maxY

        switch handle {
        case .topLeft:
            fixedX = bounds.maxX
            movingX = point.x
            fixedY = bounds.maxY
            movingY = point.y
        case .top:
            fixedY = bounds.maxY
            movingY = point.y
        case .topRight:
            movingX = point.x
            fixedY = bounds.maxY
            movingY = point.y
        case .right:
            movingX = point.x
        case .bottomRight:
            movingX = point.x
            movingY = point.y
        case .bottom:
            movingY = point.y
        case .bottomLeft:
            fixedX = bounds.maxX
            movingX = point.x
            movingY = point.y
        case .left:
            fixedX = bounds.maxX
            movingX = point.x
        }

        return rect(fixedX: fixedX, movingX: movingX, fixedY: fixedY, movingY: movingY)
    }

    private static func rect(fixedX: CGFloat, movingX: CGFloat, fixedY: CGFloat, movingY: CGFloat) -> CGRect {
        var rect = CGRect(
            x: min(fixedX, movingX),
            y: min(fixedY, movingY),
            width: abs(fixedX - movingX),
            height: abs(fixedY - movingY)
        )
        if rect.width < 0.01 {
            rect.size.width = 0.01
            if movingX < fixedX { rect.origin.x = fixedX - 0.01 }
        }
        if rect.height < 0.01 {
            rect.size.height = 0.01
            if movingY < fixedY { rect.origin.y = fixedY - 0.01 }
        }
        return rect
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private static func pathContains(
        annotation: Annotation,
        point: CGPoint,
        selectionSize: CGSize
    ) -> Bool {
        guard selectionSize.width > 0, selectionSize.height > 0 else { return false }
        let selection = CGRect(origin: .zero, size: selectionSize)
        let localPoint = AnnotationGeometry.localPoint(point, in: selection)
        let path = AnnotationGeometry.path(
            for: annotation.kind,
            in: selection,
            lineWidth: annotation.lineWidth
        )
        let strokedPath = path.copy(
            strokingWithWidth: max(annotation.lineWidth, 8),
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10,
            transform: .identity
        )
        return strokedPath.contains(localPoint)
    }

    private static func isNear(
        _ point: CGPoint,
        _ controlPoint: CGPoint,
        selectionSize: CGSize
    ) -> Bool {
        guard selectionSize.width > 0, selectionSize.height > 0 else { return false }
        let dx = (point.x - controlPoint.x) * selectionSize.width
        let dy = (point.y - controlPoint.y) * selectionSize.height
        return hypot(dx, dy) <= 8
    }
}

private extension AnnotationResizeHandle {
    func point(in bounds: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: bounds.minX, y: bounds.minY)
        case .top: CGPoint(x: bounds.midX, y: bounds.minY)
        case .topRight: CGPoint(x: bounds.maxX, y: bounds.minY)
        case .right: CGPoint(x: bounds.maxX, y: bounds.midY)
        case .bottomRight: CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .bottom: CGPoint(x: bounds.midX, y: bounds.maxY)
        case .bottomLeft: CGPoint(x: bounds.minX, y: bounds.maxY)
        case .left: CGPoint(x: bounds.minX, y: bounds.midY)
        }
    }
}
