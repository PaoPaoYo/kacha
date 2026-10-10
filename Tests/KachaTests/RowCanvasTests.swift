import AppKit
import XCTest
@testable import kacha

/// 增量画布：追加只写新增行、指针恒定、容量上限可预期。
final class RowCanvasTests: XCTestCase {

    private func makeCanvas(maxHeight: Int, width: Int = 8) -> RowCanvas {
        RowCanvas(width: width, maxHeight: maxHeight, maxBytes: 1_000_000,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func framePixels(_ image: CGImage) throws -> FramePixels {
        try XCTUnwrap(FramePixels(image: image))
    }

    func testAppendGrowsOnlyByAppendedRows() throws {
        let canvas = makeCanvas(maxHeight: 32)
        let first = makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: y * 10 + x) }
        let second = makeImage(width: 8, height: 4) { y, x in UInt8(truncatingIfNeeded: 100 + y * 10 + x) }

        XCTAssertTrue(canvas.append(try framePixels(first), rows: 0..<6, overlap: 0))
        XCTAssertEqual(canvas.height, 6)
        XCTAssertTrue(canvas.append(try framePixels(second), rows: 0..<4, overlap: 0))
        XCTAssertEqual(canvas.height, 10)

        let image = try XCTUnwrap(canvas.makeImage())
        XCTAssertEqual(image.height, 10)
        XCTAssertEqual(pixels(of: image), pixels(of: makeImage(width: 8, height: 10) { y, x in
            y < 6 ? UInt8(truncatingIfNeeded: y * 10 + x) : UInt8(truncatingIfNeeded: 100 + (y - 6) * 10 + x)
        }))
    }

    func testOverlapRewindsTailThenOverwritesIt() throws {
        let canvas = makeCanvas(maxHeight: 32)
        let first = makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: y * 10 + x) }
        // 追加 second 的 [2, 6) 共 4 行，回退 2 行 ⇒ 净增 2 行，末尾 2 行被新帧覆盖
        let second = makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: 200 + y * 10 + x) }

        XCTAssertTrue(canvas.append(try framePixels(first), rows: 0..<6, overlap: 0))
        XCTAssertTrue(canvas.append(try framePixels(second), rows: 2..<6, overlap: 2))
        XCTAssertEqual(canvas.height, 8)

        let image = try XCTUnwrap(canvas.makeImage())
        XCTAssertEqual(pixels(of: image), pixels(of: makeImage(width: 8, height: 8) { y, x in
            // 行 0..3 原样保留；行 4 起由 second 的 [2, 6) 覆盖（回退 2 行 + 追加 4 行）
            y < 4 ? UInt8(truncatingIfNeeded: y * 10 + x)
                  : UInt8(truncatingIfNeeded: 200 + (y - 2) * 10 + x)
        }))
    }

    func testAppendStopsAtCapacity() throws {
        let canvas = makeCanvas(maxHeight: 8)
        let source = try framePixels(makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: y * 10 + x) })

        XCTAssertTrue(canvas.append(source, rows: 0..<6, overlap: 0))
        XCTAssertFalse(canvas.append(source, rows: 0..<6, overlap: 0), "超出上限应返回 false 而不是越界写")
        XCTAssertEqual(canvas.height, 6)
        XCTAssertEqual(canvas.remainingRows, 2)
    }

    func testTruncateDropsTailRows() throws {
        let canvas = makeCanvas(maxHeight: 32)
        let source = try framePixels(makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: y * 10 + x) })
        XCTAssertTrue(canvas.append(source, rows: 0..<6, overlap: 0))

        XCTAssertTrue(canvas.truncate(to: 3))
        XCTAssertEqual(canvas.height, 3)
        XCTAssertFalse(canvas.truncate(to: 4), "不能反向增长")
        XCTAssertEqual(try XCTUnwrap(canvas.makeImage()).height, 3)
    }

    func testMakeImageWrapsBufferWithoutLosingLaterAppends() throws {
        let canvas = makeCanvas(maxHeight: 32)
        let source = try framePixels(makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: y * 10 + x) })
        XCTAssertTrue(canvas.append(source, rows: 0..<6, overlap: 0))

        // 零拷贝包装后继续追加：指针恒定，旧图仍可读且不崩
        let snapshot = try XCTUnwrap(canvas.makeImage())
        XCTAssertEqual(snapshot.height, 6)
        XCTAssertTrue(canvas.append(source, rows: 0..<4, overlap: 0))
        XCTAssertEqual(canvas.height, 10)
        XCTAssertEqual(pixels(of: snapshot).count, 8 * 6 * 4, "旧快照应保持 6 行大小")
    }

    func testPreviewIsDownscaled() throws {
        let canvas = makeCanvas(maxHeight: 64, width: 40)
        let source = try framePixels(makeImage(width: 40, height: 20) { y, x in UInt8(truncatingIfNeeded: x * 6 + y) })
        XCTAssertTrue(canvas.append(source, rows: 0..<20, overlap: 0))

        let preview = try XCTUnwrap(canvas.makePreview(maxWidth: 10))
        XCTAssertEqual(preview.width, 10)
        XCTAssertEqual(preview.height, 5)
        XCTAssertNil(makeCanvas(maxHeight: 8).makePreview(maxWidth: 10), "空画布不应产出预览图")
    }
}
