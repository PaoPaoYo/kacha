import XCTest
@testable import kacha

final class SelectionCursorTests: XCTestCase {
    private let selection = CGRect(x: 100, y: 100, width: 400, height: 400)

    @MainActor
    func test_selectHoverOnRectStrokeReturnsArrowCursor() {
        let rect = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 180, y: 180),
            tool: .select,
            selection: selection,
            annotations: [rect],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertEqual(style, .arrow)
    }

    @MainActor
    func test_selectHoverOnEmptySelectionReturnsNil() {
        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 300, y: 300),
            tool: .select,
            selection: selection,
            annotations: [
                Annotation(
                    kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
                    color: .red,
                    lineWidth: 4
                ),
            ],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertNil(style)
    }

    @MainActor
    func test_drawToolDoesNotClaimAnnotationHover() {
        let rect = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 180, y: 180),
            tool: .pen,
            selection: selection,
            annotations: [rect],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertNil(style)
    }

    @MainActor
    func test_selectHoverOnBlurAnnotationReturnsNil() {
        let blur = Annotation(
            kind: .blur(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 8),
            color: .red,
            lineWidth: 4
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 300, y: 300),
            tool: .select,
            selection: selection,
            annotations: [blur],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertNil(style)
    }

    @MainActor
    func test_selectedAnnotationEndpointWinsOverHitTestArrow() {
        let arrow = Annotation(
            kind: .arrow(start: CGPoint(x: 0.2, y: 0.3), end: CGPoint(x: 0.8, y: 0.7)),
            color: .red,
            lineWidth: 4
        )
        let endPoint = CGPoint(
            x: selection.minX + 0.8 * selection.width,
            y: selection.minY + 0.7 * selection.height
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: endPoint,
            tool: .select,
            selection: selection,
            annotations: [arrow],
            selectedAnnotation: arrow,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertEqual(style, .crosshair)
    }

    @MainActor
    func test_selectedAnnotationStrokeHoverKeepsMoveHand() {
        let rect = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )

        // 顶边描边中段、避开 top 手柄（中点）与四角 ±8pt 控制区
        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 200, y: 180),
            tool: .select,
            selection: selection,
            annotations: [rect],
            selectedAnnotation: rect,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertEqual(style, .openHand)
    }

    @MainActor
    func test_moveDragKeepsClosedHandWhenPointerLeavesPath() {
        let pen = Annotation(
            kind: .pen(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)]),
            color: .red,
            lineWidth: 4
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 300, y: 300),
            tool: .select,
            selection: selection,
            annotations: [pen],
            selectedAnnotation: pen,
            activeEditTarget: .move,
            isDragging: true
        )

        XCTAssertEqual(style, .closedHand)
    }

    @MainActor
    func test_selectionDragOverStrokeDoesNotStealArrow() {
        let rect = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )

        // 空白/选区拖动中压过描边：不得返回箭头，否则抢走合掌/缩放手柄
        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 180, y: 180),
            tool: .select,
            selection: selection,
            annotations: [rect],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: true
        )

        XCTAssertNil(style)
    }

    @MainActor
    func test_invalidSelectionReturnsNilEvenOnStroke() {
        let rect = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: CGPoint(x: 180, y: 180),
            tool: .select,
            selection: .zero,
            annotations: [rect],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertNil(style)
    }

    @MainActor
    func test_unselectedPenStrokeReturnsArrowCursor() {
        let pen = Annotation(
            kind: .pen(points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)]),
            color: .red,
            lineWidth: 4
        )
        let onStroke = CGPoint(
            x: selection.minX + 0.5 * selection.width,
            y: selection.minY + 0.5 * selection.height
        )

        let style = SelectionView.annotationPointerCursorStyle(
            point: onStroke,
            tool: .select,
            selection: selection,
            annotations: [pen],
            selectedAnnotation: nil,
            activeEditTarget: nil,
            isDragging: false
        )

        XCTAssertEqual(style, .arrow)
    }
}
