import AppKit
import XCTest
@testable import kacha

final class TextAnnotationEditorTests: XCTestCase {
    @MainActor
    func test_configureUsesGrowingTextViewWithoutScrollInsets() {
        let textView = NSTextView(frame: .zero)

        TextAnnotationEditor.configure(textView)

        XCTAssertFalse(textView.drawsBackground)
        XCTAssertFalse(textView.isRichText)
        XCTAssertTrue(textView.isVerticallyResizable)
        XCTAssertFalse(textView.isHorizontallyResizable)
        XCTAssertEqual(textView.textContainerInset, .zero)
        XCTAssertTrue(textView.textContainer?.widthTracksTextView ?? false)
        XCTAssertFalse(textView.textContainer?.heightTracksTextView ?? true)
    }
}
