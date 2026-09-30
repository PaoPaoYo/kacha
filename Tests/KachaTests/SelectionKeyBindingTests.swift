import Carbon.HIToolbox
import XCTest
@testable import kacha

final class SelectionKeyBindingTests: XCTestCase {
    func test_deleteKeyWithSelectionRequestsDelete() {
        XCTAssertEqual(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Delete),
                modifiers: [],
                hasSelectedAnnotation: true
            ),
            .deleteSelectedAnnotation
        )
    }

    func test_forwardDeleteKeyWithSelectionRequestsDelete() {
        XCTAssertEqual(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_ForwardDelete),
                modifiers: [],
                hasSelectedAnnotation: true
            ),
            .deleteSelectedAnnotation
        )
    }

    func test_deleteKeyWithoutSelectionRequestsNothing() {
        XCTAssertNil(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Delete),
                modifiers: [],
                hasSelectedAnnotation: false
            )
        )
    }

    func test_deleteKeyWithCommandModifierRequestsNothing() {
        XCTAssertNil(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Delete),
                modifiers: .command,
                hasSelectedAnnotation: true
            )
        )
    }

    func test_deleteKeyWhileEditingTextIsLeftToTheTextView() {
        // 编辑现有文本时标注仍处于选中态：Delete 必须放行给输入框删字符，而不是删除标注
        XCTAssertNil(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Delete),
                modifiers: [],
                hasSelectedAnnotation: true,
                isTextEditing: true
            )
        )
        XCTAssertNil(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_ForwardDelete),
                modifiers: [],
                hasSelectedAnnotation: true,
                isTextEditing: true
            )
        )
    }

    func test_escapeStillCancelsOverlayWhileEditingText() {
        XCTAssertEqual(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Escape),
                modifiers: [],
                hasSelectedAnnotation: false,
                isTextEditing: true
            ),
            .cancelOverlay
        )
    }

    func test_closesTextEditSessionOnlyForTheEditedAnnotation() {
        let edited = UUID()
        XCTAssertTrue(
            SelectionView.closesTextEditSession(removing: edited, session: .editing(edited))
        )
        // 删的是别的标注：编辑会话不受影响
        XCTAssertFalse(
            SelectionView.closesTextEditSession(removing: UUID(), session: .editing(edited))
        )
        // 新建输入中（无对象）或被删对象不在编辑：不涉及关闭
        XCTAssertFalse(
            SelectionView.closesTextEditSession(removing: edited, session: .creating(at: .zero))
        )
        XCTAssertFalse(
            SelectionView.closesTextEditSession(removing: edited, session: nil)
        )
    }

    func test_returnKeyRequestsNothing() {
        XCTAssertNil(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Return),
                modifiers: [],
                hasSelectedAnnotation: true
            )
        )
    }

    func test_escapeRequestsOverlayCancellationWithoutSelection() {
        XCTAssertEqual(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Escape),
                modifiers: [],
                hasSelectedAnnotation: false
            ),
            .cancelOverlay
        )
    }
}
