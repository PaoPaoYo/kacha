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
