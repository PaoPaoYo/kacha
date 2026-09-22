import XCTest
@testable import kacha

final class AnnotationHistoryTests: XCTestCase {
    func test_commitUndoAndRedoRestoreAnnotationsAndSelection() {
        let first = Annotation(
            kind: .rect(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            color: .red,
            lineWidth: 4
        )
        let second = Annotation(
            kind: .ellipse(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)),
            color: .blue,
            lineWidth: 8
        )
        let initial = AnnotationDocumentState(
            annotations: [first],
            selectedAnnotationID: first.id
        )
        let committed = AnnotationDocumentState(
            annotations: [first, second],
            selectedAnnotationID: second.id
        )
        var history = AnnotationHistory(initial: initial)

        history.commit(committed)

        XCTAssertEqual(history.undo(), initial)
        XCTAssertEqual(history.redo(), committed)
    }

    func test_commitAfterUndoClearsRedo() {
        let first = Annotation(
            kind: .pen(points: [.zero, CGPoint(x: 0.1, y: 0.1)]),
            color: .red,
            lineWidth: 2
        )
        let second = Annotation(
            kind: .pen(points: [.zero, CGPoint(x: 0.2, y: 0.2)]),
            color: .blue,
            lineWidth: 4
        )
        var history = AnnotationHistory(initial: .init(annotations: [], selectedAnnotationID: nil))

        history.commit(.init(annotations: [first], selectedAnnotationID: first.id))
        _ = history.undo()
        history.commit(.init(annotations: [second], selectedAnnotationID: second.id))

        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo())
    }

    func test_committingSameStateDoesNotCreateUndoEntry() {
        let state = AnnotationDocumentState(annotations: [], selectedAnnotationID: nil)
        var history = AnnotationHistory(initial: state)

        history.commit(state)

        XCTAssertFalse(history.canUndo)
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.current, state)
    }

    func test_blankSelectionClickCommitsOnlyDeselection() {
        let annotation = Annotation(
            kind: .rect(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            color: .red,
            lineWidth: 4
        )
        let selected = AnnotationDocumentState(annotations: [annotation], selectedAnnotationID: annotation.id)
        let deselected = AnnotationDocumentState(annotations: [annotation], selectedAnnotationID: nil)
        var history = AnnotationHistory(initial: selected)

        history.commit(deselected)

        XCTAssertEqual(history.current.annotations, [annotation])
        XCTAssertNil(history.current.selectedAnnotationID)
        XCTAssertEqual(history.undo(), selected)
    }

    func test_undoRestoresDeletedAnnotationAndSelectedID() {
        let first = Annotation(
            kind: .rect(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            color: .red,
            lineWidth: 4
        )
        let second = Annotation(
            kind: .ellipse(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)),
            color: .blue,
            lineWidth: 8
        )
        let beforeDeletion = AnnotationDocumentState(
            annotations: [first, second],
            selectedAnnotationID: second.id
        )
        var history = AnnotationHistory(initial: beforeDeletion)

        history.commit(.init(annotations: [first], selectedAnnotationID: nil))

        XCTAssertEqual(history.undo(), beforeDeletion)
    }

    func test_undoRestoresPreviousStyle() {
        let original = Annotation(
            kind: .ellipse(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)),
            color: .red,
            lineWidth: 2
        )
        let restyled = Annotation(
            id: original.id,
            kind: original.kind,
            color: .blue,
            lineWidth: 8
        )
        let initial = AnnotationDocumentState(
            annotations: [original],
            selectedAnnotationID: original.id
        )
        var history = AnnotationHistory(initial: initial)

        history.commit(.init(annotations: [restyled], selectedAnnotationID: restyled.id))

        XCTAssertEqual(history.undo(), initial)
    }
}
