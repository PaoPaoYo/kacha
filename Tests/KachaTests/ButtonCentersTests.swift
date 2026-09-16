import XCTest
@testable import kacha

/// SelectionView.buttonCenters(sel:bounds:) 位置公式：
/// copyX = min(sel.maxX - 16, bounds.width - 28)（仅右缘 clamp，无左缘下界——V2 待修）
/// saveX = max(28, copyX - 52)
/// y = belowFits ? sel.maxY + 20 : sel.maxY - 20（belowFits = sel.maxY + 36 <= bounds.height）
final class ButtonCentersTests: XCTestCase {
    private let bounds = CGSize(width: 1000, height: 800)

    // MARK: 右缘 clamp

    func test_copyX_clampsAtRightScreenEdge() {
        // 选区贴右缘（maxX == bounds.width）：copyX 收进屏内 = bounds.width - 28
        let sel = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let centers = SelectionView.buttonCenters(sel: sel, bounds: bounds)
        XCTAssertEqual(centers.copy.x, bounds.width - 28)
        // 下方空间充足：按钮在选区下方外侧
        XCTAssertEqual(centers.copy.y, sel.maxY + 20)
        XCTAssertEqual(centers.save.y, centers.copy.y)
    }

    // MARK: belowFits 翻转

    func test_belowFits_false_putsButtonsInsideSelection() {
        // 选区贴底（maxY == bounds.height）：下方放不下（maxY + 36 > height），
        // 按钮中心收进选区内侧 sel.maxY - 20（按钮下缘离选区底 8pt）
        let sel = CGRect(x: 0, y: 600, width: 100, height: 200)
        let centers = SelectionView.buttonCenters(sel: sel, bounds: bounds)
        XCTAssertEqual(centers.copy.y, sel.maxY - 20)
        XCTAssertEqual(centers.save.y, sel.maxY - 20)
    }

    func test_belowFits_true_keepsButtonsBelowSelection() {
        // 选区远离底边：按钮在下方外侧 sel.maxY + 20
        let sel = CGRect(x: 0, y: 0, width: 100, height: 200)
        let centers = SelectionView.buttonCenters(sel: sel, bounds: bounds)
        XCTAssertEqual(centers.copy.y, sel.maxY + 20)
        XCTAssertEqual(centers.save.y, sel.maxY + 20)
    }

    // MARK: saveX 下界

    func test_saveX_flooredAt28_extremeRightSelection() {
        // 极右选区：saveX = copyX - 52 = bounds.width - 80，远在下界之上
        let sel = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let centers = SelectionView.buttonCenters(sel: sel, bounds: bounds)
        XCTAssertEqual(centers.copy.x, 972)
        XCTAssertEqual(centers.save.x, 920)
        XCTAssertGreaterThanOrEqual(centers.save.x, 28)
    }

    func test_saveX_flooredAt28_narrowSelectionAtLeftEdge() {
        // 窄选区贴左缘：copyX - 52 = -8 越界，saveX 触及下界 28
        let sel = CGRect(x: 0, y: 0, width: 60, height: 100)
        let centers = SelectionView.buttonCenters(sel: sel, bounds: bounds)
        XCTAssertEqual(centers.save.x, 28)
        XCTAssertGreaterThanOrEqual(centers.save.x, 28)
    }

    // MARK: 现状 pin（saveX 有下界、copyX 无下界）

    func test_copyX_hasNoLowerBound_knownV2Issue() {
        // 已知 V2 待修：copyX 只 clamp 右缘、无左缘下界——
        // 窄选区贴左缘时 copyX 可 < 28（半钮宽 22 + 6 边距），按钮左半被裁出屏外。
        // 此处 pin 当前实际值（saveX 有 max(28,·) 下界而 copyX 无），防止公式被意外改动回归。
        let sel = CGRect(x: 0, y: 0, width: 30, height: 100)
        let centers = SelectionView.buttonCenters(sel: sel, bounds: bounds)
        XCTAssertEqual(centers.copy.x, 14)  // min(30 - 16, 1000 - 28)，无下界
        XCTAssertEqual(centers.save.x, 28)  // max(28, 14 - 52)
    }
}
