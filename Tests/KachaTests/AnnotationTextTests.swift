import XCTest
@testable import kacha

final class AnnotationTextTests: XCTestCase {
    private let selectionSize = CGSize(width: 400, height: 300)

    func test_toolTextDoesNotTakeOverDragAsShapeDraw() {
        XCTAssertFalse(AnnotationTool.text.takesOverDrag)
        XCTAssertTrue(AnnotationTool.pen.takesOverDrag)
    }

    func test_valid_textRequiresNonEmptyTrimmedString() {
        XCTAssertFalse(AnnotationGeometry.isValid(
            .text(at: CGPoint(x: 0.2, y: 0.3), string: "   \n  ", fontSize: 16),
            selectionSize: selectionSize
        ))
        XCTAssertTrue(AnnotationGeometry.isValid(
            .text(at: CGPoint(x: 0.2, y: 0.3), string: "你好", fontSize: 16),
            selectionSize: selectionSize
        ))
    }

    func test_path_textBoundsAtAnchorWithWrapWidth() {
        let kind = Annotation.Kind.text(at: CGPoint(x: 0.1, y: 0.2), string: "Hi", fontSize: 16)
        let path = AnnotationGeometry.path(for: kind, in: CGRect(origin: .zero, size: selectionSize), lineWidth: 4)
        let bounds = path.boundingBox
        XCTAssertEqual(bounds.origin.x, 40, accuracy: 0.5)
        XCTAssertEqual(bounds.origin.y, 60, accuracy: 0.5)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 16)
        // 自动换行宽度不超过选区 90%
        XCTAssertLessThanOrEqual(bounds.width, selectionSize.width * 0.9 + 1)
    }

    func test_path_textLongStringWrapsTallerThanOneLine() {
        let line = String(repeating: "字", count: 80)
        let kind = Annotation.Kind.text(at: CGPoint(x: 0, y: 0), string: line, fontSize: 24)
        let path = AnnotationGeometry.path(for: kind, in: CGRect(origin: .zero, size: selectionSize), lineWidth: 4)
        XCTAssertGreaterThan(path.boundingBox.height, 24 * 1.5)
        XCTAssertLessThanOrEqual(path.boundingBox.width, selectionSize.width + 1)
    }

    func test_hitTest_textInteriorHits() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.2, y: 0.3), string: "Hello", fontSize: 24),
            color: .black,
            lineWidth: 4
        )
        // 锚点附近应命中（fill 语义，不是描边）
        let id = AnnotationEditor.hitTest(
            annotations: [text],
            point: CGPoint(x: 0.25, y: 0.35),
            selectionSize: selectionSize
        )
        XCTAssertEqual(id, text.id)
    }

    func test_target_textReturnsMove() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.3, y: 0.4), string: "Ab", fontSize: 16),
            color: .blue,
            lineWidth: 4
        )
        XCTAssertEqual(
            AnnotationEditor.target(
                at: CGPoint(x: 0.32, y: 0.42),
                annotation: text,
                selectionSize: selectionSize
            ),
            .move
        )
    }

    func test_transform_textMoveTranslatesAnchorAndClamps() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.8, y: 0.2), string: "Move", fontSize: 16),
            color: .red,
            lineWidth: 4
        )
        let result = AnnotationEditor.transformed(
            text,
            target: .move,
            from: CGPoint(x: 0.8, y: 0.2),
            to: CGPoint(x: 1.2, y: 0.1)
        )
        guard case let .text(at, string, fontSize, _) = result.kind else {
            return XCTFail("expected text, got \(result.kind)")
        }
        XCTAssertEqual(at.x, 1, accuracy: 0.0001)
        XCTAssertEqual(at.y, 0.1, accuracy: 0.0001)
        XCTAssertEqual(string, "Move")
        XCTAssertEqual(fontSize, 16)
        XCTAssertEqual(result.id, text.id)
    }

    func test_editingTextPersistsResizedWidth() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.1, y: 0.1), string: "before", fontSize: 24, width: 0.5),
            color: .green,
            lineWidth: 4
        )

        let updated = AnnotationEditor.updatingText(text, string: "after", width: 0.3)
        guard case let .text(_, string, _, width) = updated.kind else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(string, "after")
        XCTAssertEqual(width, 0.3)
        XCTAssertEqual(updated.id, text.id)
    }

    func test_inputWidthHandleClampsToFontAndSelectionRightEdge() {
        let selection = CGRect(x: 100, y: 50, width: 400, height: 300)
        let anchor = CGPoint(x: 0.2, y: 0.2)
        XCTAssertEqual(SelectionView.inputWidth(at: 200, anchor: anchor, selection: selection, fontSize: 24), 0.06, accuracy: 0.0001)
        XCTAssertEqual(SelectionView.inputWidth(at: 340, anchor: anchor, selection: selection, fontSize: 24), 0.4, accuracy: 0.0001)
        XCTAssertEqual(SelectionView.inputWidth(at: 600, anchor: anchor, selection: selection, fontSize: 24), 0.8, accuracy: 0.0001)
    }

    func test_updatingTextPreservesIdAndFontSize() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.1, y: 0.1), string: "old", fontSize: 24, width: 0.4),
            color: .green,
            lineWidth: 4
        )
        let updated = AnnotationEditor.updatingText(text, string: "new\nline")
        XCTAssertEqual(updated.id, text.id)
        XCTAssertEqual(updated.color, text.color)
        guard case let .text(at, string, fontSize, width) = updated.kind else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(string, "new\nline")
        XCTAssertEqual(fontSize, 24)
        XCTAssertEqual(width, 0.4)
        XCTAssertEqual(at, CGPoint(x: 0.1, y: 0.1))
    }

    func test_updatingFontSizePreservesStringAndId() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.5, y: 0.5), string: "size", fontSize: 16),
            color: .black,
            lineWidth: 4
        )
        let updated = AnnotationEditor.updatingFontSize(text, fontSize: 36)
        XCTAssertEqual(updated.id, text.id)
        guard case let .text(_, string, fontSize, _) = updated.kind else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(string, "size")
        XCTAssertEqual(fontSize, 36)
    }

    func test_fontSizeSteps() {
        XCTAssertEqual(AnnotationFontSize.small.pt, 16)
        XCTAssertEqual(AnnotationFontSize.medium.pt, 24)
        XCTAssertEqual(AnnotationFontSize.large.pt, 36)
        XCTAssertEqual(AnnotationFontSize.nearest(17), .small)
        XCTAssertEqual(AnnotationFontSize.nearest(24), .medium)
        XCTAssertEqual(AnnotationFontSize.nearest(35), .large)
    }

    func test_textLayout_wrapsWithinMaxWidth() {
        let maxWidth: CGFloat = 80
        let size = AnnotationTextLayout.size(
            string: "WWWWWWWWWW",
            fontSize: 16,
            maxWidth: maxWidth
        )
        XCTAssertLessThanOrEqual(size.width, maxWidth + 1)
        XCTAssertGreaterThan(size.height, 16)
    }

    func test_textLayout_explicitNewlinesCreateMultipleLines() {
        let one = AnnotationTextLayout.size(string: "A", fontSize: 16, maxWidth: 400)
        let multi = AnnotationTextLayout.size(string: "A\nB\nC", fontSize: 16, maxWidth: 400)
        XCTAssertGreaterThan(multi.height, one.height + 16)
    }

    func test_autoWidthFollowsShortTextInsteadOfFillingSelection() {
        let selection = CGRect(origin: .zero, size: selectionSize)
        let rect = AnnotationTextLayout.localRect(
            at: CGPoint(x: 0.1, y: 0.2),
            string: "Hi",
            fontSize: 24,
            width: nil,
            selection: selection
        )

        XCTAssertLessThan(rect.width, 80)
        XCTAssertLessThanOrEqual(rect.maxX, selection.maxX)
    }

    func test_autoWidthStopsAtRemainingSelectionWidthAndWraps() {
        let selection = CGRect(origin: .zero, size: selectionSize)
        let rect = AnnotationTextLayout.localRect(
            at: CGPoint(x: 0.75, y: 0.1),
            string: String(repeating: "W", count: 30),
            fontSize: 24,
            width: nil,
            selection: selection
        )

        XCTAssertEqual(rect.width, 100, accuracy: 1)
        XCTAssertGreaterThan(rect.height, 30)
    }

    func test_fixedWidthIsPreservedForShortText() {
        let selection = CGRect(origin: .zero, size: selectionSize)
        let rect = AnnotationTextLayout.localRect(
            at: CGPoint(x: 0.1, y: 0.2),
            string: "Hi",
            fontSize: 24,
            width: 0.5,
            selection: selection
        )

        XCTAssertEqual(rect.width, 200, accuracy: 1)
    }

    func test_targetTextWidthHandleReturnsTextWidth() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.1, y: 0.2), string: "Hello", fontSize: 24, width: 0.5),
            color: .black,
            lineWidth: 4
        )

        XCTAssertEqual(
            AnnotationEditor.target(
                at: CGPoint(x: 0.6, y: 0.25),
                annotation: text,
                selectionSize: selectionSize
            ),
            .textWidth
        )
    }

    func test_transformTextWidthPersistsNormalizedWidth() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.1, y: 0.2), string: "Hello", fontSize: 24, width: nil),
            color: .black,
            lineWidth: 4
        )
        let result = AnnotationEditor.transformed(
            text,
            target: .textWidth,
            from: CGPoint(x: 0.2, y: 0.25),
            to: CGPoint(x: 0.45, y: 0.25)
        )

        guard case let .text(_, _, _, width) = result.kind else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(width ?? -1, 0.35, accuracy: 0.0001)
    }
}
