import XCTest
@testable import kacha

final class WindowGeometryTests: XCTestCase {
    // MARK: screenOriginGlobalCG

    func test_origin_mainScreenAtZero() {
        // 主屏 frame (0,0,1512,982)（AppKit 左下原点），总高 982 → CG 原点 (0, 0)
        let p = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), totalHeight: 982)
        XCTAssertEqual(p, CGPoint(x: 0, y: 0))
    }

    func test_origin_screenAboveMain() {
        // 主屏 (0,0,1512,982)、上排副屏 (0,982,1000,800)：总高 1782
        // 主屏 CG origin y = 1782 - 982 = 800；副屏 CG origin y = 1782 - 1782 = 0
        let main = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), totalHeight: 1782)
        XCTAssertEqual(main, CGPoint(x: 0, y: 800))
        let top = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 0, y: 982, width: 1000, height: 800), totalHeight: 1782)
        XCTAssertEqual(top, CGPoint(x: 0, y: 0))
    }

    func test_origin_sideScreenNonZeroX() {
        // 右侧副屏 (1512,0,1920,1080)，总高 1080 → CG 原点 (1512, 0)
        let p = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), totalHeight: 1080)
        XCTAssertEqual(p, CGPoint(x: 1512, y: 0))
    }

    // MARK: localRect

    func test_localRect_mainScreen() {
        let r = WindowGeometry.localRect(
            window: CGRect(x: 100, y: 200, width: 300, height: 400),
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            totalHeight: 982
        )
        XCTAssertEqual(r, CGRect(x: 100, y: 200, width: 300, height: 400))
    }

    func test_localRect_offsetScreen() {
        // 窗口 CG 全局 (1600, 300)，副屏 CG 原点 (1512, 0) → 局部 (88, 300)
        let r = WindowGeometry.localRect(
            window: CGRect(x: 1600, y: 300, width: 500, height: 400),
            screenFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            totalHeight: 1080
        )
        XCTAssertEqual(r, CGRect(x: 88, y: 300, width: 500, height: 400))
    }

    // MARK: hitTest

    func test_hitTest_firstWinsOnOverlap() {
        // 数组顺序 = front-to-back；重叠点命中首个
        let w1 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let w2 = CGRect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(WindowGeometry.hitTest(point: CGPoint(x: 60, y: 60), windows: [w1, w2]), w1)
    }

    func test_hitTest_fallsThroughToSecond() {
        let w1 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let w2 = CGRect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(WindowGeometry.hitTest(point: CGPoint(x: 140, y: 140), windows: [w1, w2]), w2)
    }

    func test_hitTest_missReturnsNil() {
        XCTAssertNil(WindowGeometry.hitTest(point: CGPoint(x: 500, y: 500), windows: [CGRect(x: 0, y: 0, width: 100, height: 100)]))
    }

    func test_hitTest_emptyListReturnsNil() {
        XCTAssertNil(WindowGeometry.hitTest(point: CGPoint(x: 1, y: 1), windows: []))
    }

    // MARK: clampedToScreen

    func test_clamp_crossScreenIntersects() {
        // 窗口跨屏：屏 (0,0,1512,982)，窗口 CG (1400,0,300,982) → 交集 (1400,0,112,982)
        let r = WindowGeometry.clampedToScreen(CGRect(x: 1400, y: 0, width: 300, height: 982), screenBounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(r, CGRect(x: 1400, y: 0, width: 112, height: 982))
    }

    func test_clamp_disjointReturnsNil() {
        XCTAssertNil(WindowGeometry.clampedToScreen(CGRect(x: 2000, y: 0, width: 100, height: 100), screenBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)))
    }

    func test_clamp_insideUnchanged() {
        let r = WindowGeometry.clampedToScreen(CGRect(x: 10, y: 10, width: 100, height: 100), screenBounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(r, CGRect(x: 10, y: 10, width: 100, height: 100))
    }
}
