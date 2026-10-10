import AppKit
import XCTest
@testable import kacha

/// 端到端拼接测试：合成一个带「固定顶栏 + 固定底栏」的滚动区域，
/// 与"理想长图"逐像素对拍。核心断言是**固定底栏不能出现在长图里**——
/// 旧实现只要单次滚动量小于底栏高度，就会把底栏整条追加成长图内容。
final class ScrollingBandTests: XCTestCase {

    // MARK: - 底栏不再被重复贴入

    func testFixedFooterIsNotDuplicatedIntoLongImage() throws {
        let page = PageModel()
        var stitcher = ScrollingStitcher()

        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)
        var scroll = 0
        for _ in 0..<5 {
            scroll += 12
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll)), .appended(12))
        }

        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: scroll))
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: scroll)),
                       "长图应与「顶栏 + 全部内容行」逐像素一致")
    }

    func testFooterDoesNotBlockLargerScrolls() throws {
        // 旧实现在有底栏时，滚动量越大匹配代价被抬得越高，最终整帧被判失配（unmatched）
        let page = PageModel()
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)

        var scroll = 0
        for _ in 0..<3 {
            scroll += 40
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll)), .appended(40))
        }
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: scroll))
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: scroll)))
    }

    func testFooterRowsNeverAppearInResult() throws {
        let page = PageModel()
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)
        XCTAssertEqual(stitcher.append(page.frame(scroll: 9)), .appended(9))

        let image = try XCTUnwrap(stitcher.image)
        XCTAssertFalse(containsBlock(of: image, block: page.footerOnlyImage()),
                       "固定底栏整块图案不应出现在长图任何位置")
    }

    func testSparseAnimationInsideFooterStillCountsAsFixedBand() throws {
        // 固定栏里通常有稀疏动画（输入框光标闪烁、进度条）：只看"平均差"会让固定栏
        // 被判小，那截底栏就会被追加进长图。这里用闪烁光标复现该场景。
        let page = PageModel()
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0, caret: true)), .started)

        var scroll = 0
        for step in 0..<4 {
            scroll += 13
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll, caret: step % 2 == 0)), .appended(13))
        }
        XCTAssertEqual(stitcher.bands.bottom, page.footerHeight, "闪烁光标不应让底栏判小")
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: scroll))
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: scroll)))
    }

    // MARK: - 右侧滚动条

    func testChangingScrollbarColumnDoesNotBreakMatching() throws {
        let page = PageModel()
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0, scrollbar: true)), .started)

        var scroll = 0
        for step in 0..<4 {
            scroll += 14
            // 滚动条在相邻帧之间淡入淡出：不排除右缘这几列会抬高所有候选的代价
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll, scrollbar: step % 2 == 0)), .appended(14))
        }
        XCTAssertGreaterThanOrEqual(stitcher.bands.right, 3, "应把右缘变化列排除出匹配（内容整体滚动时会取到扫描上限）")
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: scroll))
    }

    // MARK: - 歧义内容

    func testPeriodicContentWithAmbiguousShiftIsRejected() throws {
        // 每 12 行完全重复的内容 + 滚动 18px：6 / 18 / 30 都能完美对齐，无法判定真实位移
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(makeImage(width: 64, height: 120) { y, x in
            pageValue(y % 12, x)
        }), .started)
        let before = stitcher.pixelHeight

        let next = makeImage(width: 64, height: 120) { y, x in pageValue((18 + y) % 12, x) }
        XCTAssertEqual(stitcher.append(next), .unmatched, "歧义位移必须拒绝，而不是猜一个")
        XCTAssertEqual(stitcher.pixelHeight, before, "拒绝时不得污染长图")
    }

    func testPerfectlyPeriodicScrollIsReportedUnchanged() throws {
        // 周期内容滚动整数个周期 ⇒ 两帧像素完全一致，只能报"画面没动"
        var stitcher = ScrollingStitcher()
        _ = stitcher.append(makeImage(width: 64, height: 120) { y, x in pageValue(y % 12, x) })
        let next = makeImage(width: 64, height: 120) { y, x in pageValue((12 + y) % 12, x) }
        XCTAssertEqual(stitcher.append(next), .unchanged)
    }

    // MARK: - 小位移累积

    func testSmallScrollIsIgnoredUntilItAccumulates() throws {
        let page = PageModel()
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)

        // 2px：低于最小位移，不应追加（也不该猜一个错误位移）；此时首帧仍在画布上
        XCTAssertNotEqual(stitcher.append(page.frame(scroll: 2)), .appended(2))
        XCTAssertEqual(stitcher.pixelHeight, page.viewportHeight)

        // 参考帧仍是 scroll=0 的那一帧，于是 5px 能正常接上
        XCTAssertEqual(stitcher.append(page.frame(scroll: 5)), .appended(5))
        XCTAssertEqual(stitcher.append(page.frame(scroll: 15)), .appended(10))
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: 15))
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: 15)))
    }

    // MARK: - 辅助

    private struct PageModel {
        let width = 64
        let viewportHeight = 120
        let headerHeight = 8
        let footerHeight = 16
        var contentHeight: Int { viewportHeight - headerHeight - footerHeight }

        func frame(scroll: Int, scrollbar: Bool = false, caret: Bool = false) -> CGImage {
            makeImage(width: width, height: viewportHeight) { y, x in
                if y < self.headerHeight { return x % 7 < 3 ? 40 : 210 }
                if y >= self.viewportHeight - self.footerHeight {
                    // 底部固定栏：一列 8 行高的"光标"按帧闪烁
                    if caret, x == 5, y >= self.viewportHeight - self.footerHeight + 4,
                       y < self.viewportHeight - self.footerHeight + 12 {
                        return 10
                    }
                    return x % 11 < 4 ? 60 : 235
                }
                // 右缘 3 列模拟滚动条（只在需要时叠加，否则会污染 ground truth）
                if scrollbar, x >= self.width - 3 { return 20 }
                return pageValue(scroll + (y - self.headerHeight), x)
            }
        }

        func expectedImage(scroll: Int) -> CGImage {
            makeImage(width: width, height: expectedHeight(scroll: scroll)) { y, x in
                if y < self.headerHeight { return x % 7 < 3 ? 40 : 210 }
                return pageValue(y - self.headerHeight, x)
            }
        }

        func expectedHeight(scroll: Int) -> Int { headerHeight + contentHeight + scroll }

        func footerOnlyImage() -> CGImage {
            makeImage(width: width, height: footerHeight) { _, x in
                x % 11 < 4 ? 60 : 235
            }
        }
    }

}

// MARK: - 共享工具

func pageValue(_ pageRow: Int, _ x: Int) -> UInt8 {
    var hash = UInt32(truncatingIfNeeded: pageRow &* 2_654_435_761 &+ x &* 40_503)
    hash = (hash ^ (hash >> 13)) &* 1_274_126_177
    return UInt8(truncatingIfNeeded: (hash ^ (hash >> 16)) & 0xFF)
}

func makeImage(width: Int, height: Int, value: (Int, Int) -> UInt8) -> CGImage {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let v = value(y, x)
            let offset = (y * width + x) * 4
            data[offset] = v
            data[offset + 1] = v
            data[offset + 2] = v
            data[offset + 3] = 255
        }
    }
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

func pixels(of image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

func rows(of image: CGImage) -> [Int] {
    let data = pixels(of: image)
    return (0..<image.height).map { Int(data[$0 * image.width * 4]) }
}

/// 长图里是否出现了与 `block` 完全相同的整块像素（用于断言固定栏没有被贴进长图）
func containsBlock(of image: CGImage, block: CGImage) -> Bool {
    guard block.width <= image.width, block.height <= image.height else { return false }
    let haystack = pixels(of: image)
    let needle = pixels(of: block)
    let imageStride = image.width * 4
    let blockStride = block.width * 4
    guard block.height <= image.height else { return false }
    for startRow in 0...(image.height - block.height) {
        for startColumn in 0...(image.width - block.width) {
            var matches = true
            outer: for row in 0..<block.height {
                let haystackRow = (startRow + row) * imageStride + startColumn * 4
                let needleRow = row * blockStride
                for byte in 0..<blockStride where haystack[haystackRow + byte] != needle[needleRow + byte] {
                    matches = false
                    break outer
                }
            }
            if matches { return true }
        }
    }
    return false
}
