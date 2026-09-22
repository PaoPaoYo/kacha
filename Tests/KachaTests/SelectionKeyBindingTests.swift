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

    func test_returnKeyRequestsNothing() {
        XCTAssertNil(
            SelectionView.keyCommand(
                keyCode: UInt16(kVK_Return),
                modifiers: [],
                hasSelectedAnnotation: true
            )
        )
    }
}
