import XCTest
@testable import kacha

final class AnnotationEditorTests: XCTestCase {
    private let selectionSize = CGSize(width: 1_000, height: 1_000)

    func test_hitTestPrefersLastOverlappingEditableAnnotation() {
        let bottom = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )
        let top = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .blue,
            lineWidth: 4
        )

        XCTAssertEqual(
            AnnotationEditor.hitTest(
                annotations: [bottom, top],
                point: CGPoint(x: 0.2, y: 0.45),
                selectionSize: selectionSize
            ),
            top.id
        )
    }

    func test_hitTestDoesNotSelectRectInterior() {
        let annotation = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 4
        )

        XCTAssertNil(
            AnnotationEditor.hitTest(
                annotations: [annotation],
                point: CGPoint(x: 0.45, y: 0.45),
                selectionSize: selectionSize
            )
        )
    }

    func test_hitTestDoesNotSelectBlurAnnotation() {
        let annotation = Annotation(
            kind: .blur(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 8),
            color: .red,
            lineWidth: 4
        )

        XCTAssertNil(
            AnnotationEditor.hitTest(
                annotations: [annotation],
                point: CGPoint(x: 0.5, y: 0.5),
                selectionSize: selectionSize
            )
        )
    }

    func test_targetReturnsArrowEndpointBeforeMove() {
        let annotation = Annotation(
            kind: .arrow(start: CGPoint(x: 0.2, y: 0.3), end: CGPoint(x: 0.8, y: 0.7)),
            color: .red,
            lineWidth: 4
        )

        XCTAssertEqual(
            AnnotationEditor.target(
                at: CGPoint(x: 0.8, y: 0.7),
                annotation: annotation,
                selectionSize: selectionSize
            ),
            .arrowEnd
        )
    }

    func test_targetReturnsRectCornerResizeHandle() {
        let annotation = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)),
            color: .red,
            lineWidth: 4
        )

        XCTAssertEqual(
            AnnotationEditor.target(
                at: CGPoint(x: 0.2, y: 0.3),
                annotation: annotation,
                selectionSize: selectionSize
            ),
            .resize(.topLeft)
        )
    }

    func test_transformMovesArrowBothEndpointsAndClampsToSelection() {
        let arrow = Annotation(
            kind: .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.8, y: 0.7)),
            color: .red,
            lineWidth: 4
        )

        let result = AnnotationEditor.transformed(
            arrow,
            target: .move,
            from: CGPoint(x: 0.5, y: 0.5),
            to: CGPoint(x: 0.9, y: 0.9)
        )

        XCTAssertArrow(
            result.kind,
            start: CGPoint(x: 0.3, y: 0.4),
            end: CGPoint(x: 1, y: 0.9)
        )
    }

    func test_transformUpdatesArrowEndOnly() {
        let arrow = Annotation(
            kind: .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.8, y: 0.7)),
            color: .red,
            lineWidth: 4
        )

        let result = AnnotationEditor.transformed(
            arrow,
            target: .arrowEnd,
            from: CGPoint(x: 0.8, y: 0.7),
            to: CGPoint(x: 0.6, y: 0.4)
        )

        XCTAssertEqual(result.kind, .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.6, y: 0.4)))
    }

    func test_resizeNormalizesRectWhenDraggedAcrossOppositeCorner() {
        let rect = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)),
            color: .red,
            lineWidth: 4
        )

        let result = AnnotationEditor.transformed(
            rect,
            target: .resize(.topLeft),
            from: CGPoint(x: 0.2, y: 0.2),
            to: CGPoint(x: 0.8, y: 0.8)
        )

        XCTAssertRectBounds(
            result.kind,
            expected: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
        )
    }

    func test_resizeEllipseChangesWidthAndHeightIndependently() {
        let ellipse = Annotation(
            kind: .ellipse(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)),
            color: .red,
            lineWidth: 4
        )

        let result = AnnotationEditor.transformed(
            ellipse,
            target: .resize(.right),
            from: CGPoint(x: 0.6, y: 0.4),
            to: CGPoint(x: 0.8, y: 0.4)
        )

        XCTAssertEllipseBounds(
            result.kind,
            expected: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.2)
        )
    }

    func test_movePenTranslatesEveryPoint() {
        let pen = Annotation(
            kind: .pen(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.7, y: 0.3)]),
            color: .red,
            lineWidth: 4
        )

        let result = AnnotationEditor.transformed(
            pen,
            target: .move,
            from: CGPoint(x: 0.5, y: 0.5),
            to: CGPoint(x: 0.7, y: 0.8)
        )

        XCTAssertPenPoints(
            result.kind,
            expected: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.6, y: 0.8), CGPoint(x: 0.9, y: 0.6)]
        )
    }

    func test_updatingStylePreservesAnnotationIdentityAndKind() {
        let annotation = Annotation(
            kind: .ellipse(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)),
            color: .red,
            lineWidth: 2
        )

        let result = AnnotationEditor.updatingStyle(annotation, color: .blue, lineWidth: 8)

        XCTAssertEqual(result.id, annotation.id)
        XCTAssertEqual(result.kind, annotation.kind)
        XCTAssertEqual(result.color, .blue)
        XCTAssertEqual(result.lineWidth, 8)
    }

    func test_removingDeletesOnlyMatchingAnnotationID() {
        let first = Annotation(kind: .pen(points: [.zero, CGPoint(x: 0.1, y: 0.1)]), color: .red, lineWidth: 4)
        let second = Annotation(kind: .pen(points: [.zero, CGPoint(x: 0.2, y: 0.2)]), color: .blue, lineWidth: 4)

        let result = AnnotationEditor.removing(id: first.id, from: [first, second])

        XCTAssertEqual(result, [second])
    }

    func test_previewDragDoesNotCommitHistoryUntilRelease() {
        let original = Annotation(
            kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)),
            color: .red,
            lineWidth: 4
        )
        let preview = AnnotationEditor.transformed(
            original,
            target: .move,
            from: CGPoint(x: 0.3, y: 0.3),
            to: CGPoint(x: 0.5, y: 0.5)
        )
        var history = AnnotationHistory(initial: .init(annotations: [original], selectedAnnotationID: original.id))

        XCTAssertEqual(history.current.annotations, [original])
        XCTAssertFalse(history.canUndo)

        history.commit(.init(
            annotations: AnnotationEditor.replacing(preview, in: history.current.annotations),
            selectedAnnotationID: original.id
        ))

        XCTAssertEqual(history.current.annotations, [preview])
        XCTAssertTrue(history.canUndo)
    }

    private func XCTAssertArrow(
        _ kind: Annotation.Kind,
        start expectedStart: CGPoint,
        end expectedEnd: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .arrow(start, end) = kind else {
            XCTFail("Expected arrow", file: file, line: line)
            return
        }
        XCTAssertEqual(start.x, expectedStart.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(start.y, expectedStart.y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(end.x, expectedEnd.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(end.y, expectedEnd.y, accuracy: 0.000_001, file: file, line: line)
    }

    private func XCTAssertRectBounds(
        _ kind: Annotation.Kind,
        expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .rect(bounds) = kind else {
            XCTFail("Expected rectangle", file: file, line: line)
            return
        }
        XCTAssertEqual(bounds.origin.x, expected.origin.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(bounds.origin.y, expected.origin.y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(bounds.width, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(bounds.height, expected.height, accuracy: 0.000_001, file: file, line: line)
    }

    private func XCTAssertEllipseBounds(
        _ kind: Annotation.Kind,
        expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .ellipse(bounds) = kind else {
            XCTFail("Expected ellipse", file: file, line: line)
            return
        }
        XCTAssertEqual(bounds.origin.x, expected.origin.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(bounds.origin.y, expected.origin.y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(bounds.width, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(bounds.height, expected.height, accuracy: 0.000_001, file: file, line: line)
    }

    private func XCTAssertPenPoints(
        _ kind: Annotation.Kind,
        expected: [CGPoint],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .pen(points) = kind else {
            XCTFail("Expected pen", file: file, line: line)
            return
        }
        XCTAssertEqual(points.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(points, expected) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001, file: file, line: line)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001, file: file, line: line)
        }
    }
}
