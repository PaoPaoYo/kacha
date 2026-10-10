import AppKit
import XCTest
@testable import kacha

/// 复核报告里复现过的边角场景回归：底栏高于 1/4 视口、底栏中途出现、
/// 底栏里带大面积动画、内容区大片空白、帧尺寸变化、以及拼接服务的封盘语义。
final class ScrollingBandEdgeTests: XCTestCase {

    // MARK: - 底栏高于视口 1/4（旧实现按 height/4 截断，边界会落进底栏内部）

    func testTallFooterIsExcluded() throws {
        // 120 行视口里 48 行底栏（40%）——正是"底部工具栏/输入栏"的常见比例
        let page = EdgePage(footerHeight: 48)
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)

        var scroll = 0
        for _ in 0..<5 {
            scroll += 12
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll)), .appended(12))
        }
        XCTAssertEqual(stitcher.bands.bottom, 48, "底栏高于 1/4 视口也必须被完整识别")
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: scroll))
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: scroll)))
    }

    // MARK: - 底栏中途出现

    func testFooterAppearingMidCaptureIsExcluded() throws {
        let page = EdgePage(footerHeight: 16)
        var stitcher = ScrollingStitcher()
        // 前两帧没有底栏，之后才出现：合成边界必须跟着下移，否则多出来的底栏会被当内容追加
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0, footerVisible: false)), .started)
        var scroll = 0
        for step in 0..<5 {
            scroll += 12
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll, footerVisible: step >= 1)), .appended(12))
        }
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.height, page.expectedHeight(scroll: scroll))
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: scroll)))
        XCTAssertFalse(containsBlock(of: image, block: page.footerStrip(rows: 4)),
                       "中途出现的底栏不应进入长图")
    }

    // MARK: - 底栏里带大面积动画（半透明毛玻璃 / 宽进度条 / 跑马灯）

    func testFooterWithWideAnimationIsExcluded() throws {
        let page = EdgePage(footerHeight: 16, footerProgressBar: true)
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0, progressTick: 0)), .started)

        var scroll = 0
        for step in 0..<6 {
            scroll += 12
            XCTAssertEqual(stitcher.append(page.frame(scroll: scroll, progressTick: step + 1)), .appended(12))
        }
        XCTAssertEqual(stitcher.bands.bottom, 16,
                       "固定栏内部的大面积动画不应让整条底栏失去识别")
        let image = try XCTUnwrap(stitcher.image)
        XCTAssertFalse(containsBlock(of: image, block: page.footerStrip(rows: 4)),
                       "像素在变的底栏同样不应进入长图")
        XCTAssertEqual(pixels(of: image), pixels(of: page.expectedImage(scroll: scroll)))
    }

    // MARK: - 内容区大片空白

    func testBlankBandDoesNotStallCapture() throws {
        // 96 行内容里 88 行是纯色（只有顶部几行文字）：旧实现会把纯色块当底栏，
        // 内容区被压没、纹理配额不达标 → 之后永久 unmatched，后半页全丢
        let page = EdgePage(blankRows: 8..<96)
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)

        var scroll = 0
        var appended = 0
        var realigns = 0
        for _ in 0..<8 {
            scroll += 12
            let result = stitcher.append(page.frame(scroll: scroll))
            if case .appended = result { appended += 1 }
            if result == .unmatched, stitcher.didRealign { realigns += 1 }
        }
        // 大片无特征内容本身可能"两帧的信息区完全不重叠"（纯像素无法对齐），
        // 所以允许开头几步对不上；关键是**不能永久卡死**：重锚后必须继续采集。
        XCTAssertGreaterThanOrEqual(appended, 5, "大片空白不应导致永久失配")
        XCTAssertLessThanOrEqual(realigns, 2, "重锚不应反复发生")
        let image = try XCTUnwrap(stitcher.image)
        // 大片纯色内容与纯色固定栏在像素上无法区分，本实现按"固定栏"处理（与 macshot 的
        // frozen rows 一致）：代价是长图末尾可能少若干行，但结果必须仍是理想长图的前缀
        //（不能出现重复或错位）；一旦中途重锚，长图尾部必须恢复到正确对位。
        XCTAssertTrue(isPrefix(of: page.expectedImage(scroll: scroll), candidate: image)
                      || suffixMatches(ideal: page.expectedImage(scroll: scroll), candidate: image, rows: 24),
                      "丢内容可以，错位不行")
        XCTAssertGreaterThan(image.height, page.expectedHeight(scroll: scroll) - page.footerHeight - 96)
        XCTAssertLessThanOrEqual(image.height, page.expectedHeight(scroll: scroll))
    }

    // MARK: - 帧尺寸变化

    func testSizeChangeIsReportedInsteadOfStalling() throws {
        let page = EdgePage()
        var stitcher = ScrollingStitcher()
        XCTAssertEqual(stitcher.append(page.frame(scroll: 0)), .started)
        XCTAssertEqual(stitcher.append(page.frame(scroll: 12)), .appended(12))
        let heightBefore = stitcher.pixelHeight

        let resized = makeImage(width: page.width, height: page.viewportHeight - 40) { y, x in
            otherPageValue(y, x)
        }
        XCTAssertEqual(stitcher.append(resized), .sizeChanged, "尺寸变化要有明确语义，不能静默永久失配")
        XCTAssertEqual(stitcher.pixelHeight, heightBefore, "尺寸变化时不得写画布")

        // 尺寸恢复后还能继续拼接
        XCTAssertEqual(stitcher.append(page.frame(scroll: 24)), .appended(12))
    }

    // MARK: - 拼接服务封盘

    func testStitchServiceSealsAfterFinish() async throws {
        let service = ScrollingStitchService()
        let page = EdgePage()
        let first = await service.ingest(page.frame(scroll: 0))
        XCTAssertEqual(first?.result, .started)
        _ = await service.ingest(page.frame(scroll: 12))

        let deliveredImage = await service.finishImage()
        let delivered = try XCTUnwrap(deliveredImage)
        let deliveredHeight = delivered.height
        // 等过节流窗口，确认"新帧被挡掉"是因为封盘而不是被节流
        try await Task.sleep(nanoseconds: 120_000_000)
        let late = await service.ingest(page.frame(scroll: 24))
        XCTAssertNil(late, "封盘后不再接受新帧")
        let finalImage = await service.finishImage()
        let final = try XCTUnwrap(finalImage)
        XCTAssertEqual(final.height, deliveredHeight, "交付后的长图不应再被写入")
    }
}

// MARK: - 参数化页面模型

private struct EdgePage {
    var width = 64
    var viewportHeight = 120
    var headerHeight = 8
    var footerHeight = 16
    /// 这些页行用纯色（模拟大片空白内容）
    var blankRows: Range<Int>?
    /// 底栏里放一条 3/4 宽、4 行高的动态进度条
    var footerProgressBar = false

    var contentHeight: Int { viewportHeight - headerHeight - footerHeight }

    func contentValue(_ pageRow: Int, _ x: Int) -> UInt8 {
        if let blankRows, blankRows.contains(pageRow) { return 250 }
        return pageValue(pageRow, x)
    }

    func frame(scroll: Int, footerVisible: Bool = true, progressTick: Int = 0) -> CGImage {
        makeImage(width: width, height: viewportHeight) { y, x in
            if y < headerHeight { return x % 7 < 3 ? 40 : 210 }
            let footerTop = viewportHeight - footerHeight
            if footerVisible, y >= footerTop {
                if footerProgressBar, y >= footerTop + 6, y < footerTop + 10, x < width * 3 / 4 {
                    return progressTick % 2 == 0 ? 20 : 200
                }
                return x % 11 < 4 ? 60 : 235
            }
            return contentValue(scroll + (y - headerHeight), x)
        }
    }

    func expectedImage(scroll: Int) -> CGImage {
        makeImage(width: width, height: expectedHeight(scroll: scroll)) { y, x in
            if y < headerHeight { return x % 7 < 3 ? 40 : 210 }
            return contentValue(y - headerHeight, x)
        }
    }

    func expectedHeight(scroll: Int) -> Int { headerHeight + contentHeight + scroll }

    func footerStrip(rows: Int) -> CGImage {
        makeImage(width: width, height: rows) { _, x in x % 11 < 4 ? 60 : 235 }
    }
}

private func otherPageValue(_ row: Int, _ x: Int) -> UInt8 {
    var hash = UInt32(truncatingIfNeeded: row &* 2_246_822_519 &+ x &* 32_647)
    hash = (hash ^ (hash >> 15)) &* 2_654_435_761
    return UInt8(truncatingIfNeeded: (hash ^ (hash >> 13)) & 0xFF)
}

/// `candidate` 末尾 `rows` 行是否与 `ideal` 末尾 `rows` 行逐像素一致（重锚后对位检查）
func suffixMatches(ideal: CGImage, candidate: CGImage, rows: Int) -> Bool {
    guard candidate.width == ideal.width, candidate.height >= rows, ideal.height >= rows else { return false }
    let idealPixels = pixels(of: ideal)
    let candidatePixels = pixels(of: candidate)
    let bytesPerRow = candidate.width * 4
    let idealStart = (ideal.height - rows) * bytesPerRow
    let candidateStart = (candidate.height - rows) * bytesPerRow
    return Array(candidatePixels[candidateStart...]) == Array(idealPixels[idealStart..<(idealStart + rows * bytesPerRow)])
}

/// `candidate` 是否是 `ideal` 的前缀（逐像素；允许 candidate 更短）
func isPrefix(of ideal: CGImage, candidate: CGImage) -> Bool {
    guard candidate.width == ideal.width, candidate.height <= ideal.height else { return false }
    let idealPixels = pixels(of: ideal)
    let candidatePixels = pixels(of: candidate)
    let bytesPerRow = candidate.width * 4
    return candidatePixels == Array(idealPixels[0..<(candidate.height * bytesPerRow)])
}
