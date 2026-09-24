import XCTest
@testable import kacha

final class AnnotationToolSelectionTests: XCTestCase {
    func test_tappingToolFromNoSelectionActivatesIt() {
        XCTAssertEqual(SelectionView.toggledTool(current: nil, tapped: .arrow), .arrow)
    }

    func test_tappingActiveToolClearsIt() {
        XCTAssertNil(SelectionView.toggledTool(current: .arrow, tapped: .arrow))
    }

    func test_tappingAnotherToolSwitchesDirectly() {
        XCTAssertEqual(SelectionView.toggledTool(current: .arrow, tapped: .rect), .rect)
    }

    func test_blankInteractionWithoutToolAdjustsSelection() {
        XCTAssertEqual(SelectionView.blankInteraction(for: nil), .adjustSelection)
    }

    func test_blankInteractionWithTextCreatesText() {
        XCTAssertEqual(SelectionView.blankInteraction(for: .text), .createText)
    }

    func test_blankInteractionWithShapeDrawsCurrentTool() {
        XCTAssertEqual(SelectionView.blankInteraction(for: .ellipse), .draw(.ellipse))
    }

    func test_textToolSecondPressOnSameTextEntersEditing() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.2, y: 0.2), string: "Text", fontSize: 24),
            color: .black,
            lineWidth: 4
        )
        var taps = TextAnnotationTapSequence()
        let first = taps.press(id: text.id, at: Date(timeIntervalSince1970: 100))
        let second = taps.press(id: text.id, at: Date(timeIntervalSince1970: 100.2))

        XCTAssertFalse(first)
        XCTAssertTrue(second)
    }

    func test_textPressesOnDifferentTargetsOrOutsideDoubleClickIntervalDoNotEdit() {
        let firstID = UUID()
        let otherID = UUID()
        var taps = TextAnnotationTapSequence()

        XCTAssertFalse(taps.press(id: firstID, at: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(taps.press(id: otherID, at: Date(timeIntervalSince1970: 100.1)))
        XCTAssertFalse(taps.press(id: firstID, at: Date(timeIntervalSince1970: 101)))
        XCTAssertTrue(taps.press(id: firstID, at: Date(timeIntervalSince1970: 101.2)))
    }

    func test_selectingExistingTextWhileCreatingCommitsNonemptyDraft() {
        let existing = Annotation(kind: .text(at: CGPoint(x: 0.5, y: 0.5), string: "old", fontSize: 24), color: .black, lineWidth: 4)
        let state = SelectionView.documentAfterSelectingAnnotation(
            id: existing.id,
            session: .creating(at: CGPoint(x: 0.1, y: 0.1)),
            draft: "new text",
            annotations: [existing],
            color: .red,
            fontSize: 24,
            lineWidth: 4,
            selectionSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(state.selectedAnnotationID, existing.id)
        XCTAssertEqual(state.annotations.count, 2)
        XCTAssertTrue(state.annotations.contains { if case .text(_, "new text", _, _) = $0.kind { return true }; return false })
    }

    func test_selectingExistingTextSavesResizedDraftWidth() {
        let existing = Annotation(kind: .text(at: CGPoint(x: 0.5, y: 0.5), string: "old", fontSize: 24), color: .black, lineWidth: 4)
        let state = SelectionView.documentAfterSelectingAnnotation(
            id: existing.id,
            session: .creating(at: CGPoint(x: 0.1, y: 0.1)),
            draft: "new text",
            annotations: [existing],
            color: .red,
            fontSize: 24,
            lineWidth: 4,
            selectionSize: CGSize(width: 400, height: 300),
            width: 0.35
        )

        guard case let .text(_, _, _, width) = state.annotations.last?.kind else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(width, 0.35)
    }

    func test_selectingExistingTextWhileCreatingDiscardsBlankDraft() {
        let existing = Annotation(kind: .text(at: CGPoint(x: 0.5, y: 0.5), string: "old", fontSize: 24), color: .black, lineWidth: 4)
        let state = SelectionView.documentAfterSelectingAnnotation(
            id: existing.id,
            session: .creating(at: CGPoint(x: 0.1, y: 0.1)),
            draft: "  \n ",
            annotations: [existing],
            color: .red,
            fontSize: 24,
            lineWidth: 4,
            selectionSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(state.selectedAnnotationID, existing.id)
        XCTAssertEqual(state.annotations, [existing])
    }

    func test_selectingOtherTextWhileEditingBlankPreservesOriginal() {
        let edited = Annotation(kind: .text(at: CGPoint(x: 0.1, y: 0.1), string: "keep", fontSize: 24), color: .black, lineWidth: 4)
        let target = Annotation(kind: .text(at: CGPoint(x: 0.5, y: 0.5), string: "target", fontSize: 24), color: .red, lineWidth: 4)
        let state = SelectionView.documentAfterSelectingAnnotation(
            id: target.id,
            session: .editing(edited.id),
            draft: "",
            annotations: [edited, target],
            color: .red,
            fontSize: 24,
            lineWidth: 4,
            selectionSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(state.selectedAnnotationID, target.id)
        XCTAssertEqual(state.annotations, [edited, target])
    }

    func test_doubleTapTextEditsEvenWithAnotherToolActive() {
        let text = Annotation(
            kind: .text(at: CGPoint(x: 0.2, y: 0.2), string: "Text", fontSize: 24),
            color: .black,
            lineWidth: 4
        )
        XCTAssertEqual(
            SelectionView.doubleTapAction(
                at: CGPoint(x: 0.25, y: 0.25),
                tool: .arrow,
                selectionSize: CGSize(width: 400, height: 300),
                annotations: [text]
            ),
            .editText(text.id)
        )
    }

    func test_doubleTapBlankConfirmsOnlyWithoutTool() {
        XCTAssertEqual(
            SelectionView.doubleTapAction(
                at: CGPoint(x: 0.5, y: 0.5),
                tool: nil,
                selectionSize: CGSize(width: 400, height: 300),
                annotations: []
            ),
            .confirmCapture
        )
        XCTAssertEqual(
            SelectionView.doubleTapAction(
                at: CGPoint(x: 0.5, y: 0.5),
                tool: .pen,
                selectionSize: CGSize(width: 400, height: 300),
                annotations: []
            ),
            .none
        )
    }
}
