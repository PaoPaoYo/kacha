import AppKit
import XCTest
@testable import kacha

final class ScrollingStitcherTests: XCTestCase {
    func testAppendsOnlyNewRowsAfterDownwardScroll() throws {
        var stitcher = ScrollingStitcher()
        let first = try image(rows: Array(0..<80))
        let second = try image(rows: Array(30..<110))

        XCTAssertEqual(stitcher.append(first), .started)
        XCTAssertEqual(stitcher.append(second), .appended(30))
        XCTAssertEqual(stitcher.image?.height, 110)
        XCTAssertEqual(try rows(of: XCTUnwrap(stitcher.image)), try rows(of: image(rows: Array(0..<110))))
    }

    func testIdenticalFrameDoesNotAppend() throws {
        var stitcher = ScrollingStitcher()
        let frame = try image(rows: Array(0..<80))
        _ = stitcher.append(frame)

        XCTAssertEqual(stitcher.append(frame), .unchanged)
        XCTAssertEqual(stitcher.image?.height, 80)
    }

    func testUnrelatedFrameDoesNotCorruptResult() throws {
        var stitcher = ScrollingStitcher()
        let first = try image(rows: Array(0..<80))
        _ = stitcher.append(first)

        XCTAssertEqual(stitcher.append(try image(rows: Array(140..<220))), .unmatched)
        XCTAssertEqual(try rows(of: XCTUnwrap(stitcher.image)), try rows(of: first))
    }

    func testRepeatedTableRowsDoNotCauseAmbiguousJump() throws {
        var stitcher = ScrollingStitcher()
        let first = try image(rows: Array(0..<80).map { $0 / 4 })
        let next = try image(rows: Array(20..<100).map { $0 / 4 })
        _ = stitcher.append(first)

        XCTAssertEqual(stitcher.append(next), .appended(20))
        XCTAssertEqual(stitcher.image?.height, 100)
    }

    func testFixedHeaderAppearsOnlyOnce() throws {
        var stitcher = ScrollingStitcher()
        let first = try image(rows: [900, 901, 902, 903] + Array(0..<76))
        let next = try image(rows: [900, 901, 902, 903] + Array(24..<100))
        _ = stitcher.append(first)

        XCTAssertEqual(stitcher.append(next), .appended(24))
        XCTAssertEqual(stitcher.image?.height, 104)
        XCTAssertEqual(try rows(of: XCTUnwrap(stitcher.image)),
                       try rows(of: image(rows: [900, 901, 902, 903] + Array(0..<100))))
    }

    func testTallFixedTableHeaderIsNotUsedForAlignment() throws {
        var stitcher = ScrollingStitcher()
        let header = Array(900..<920)
        let first = try image(rows: header + Array(0..<80))
        let next = try image(rows: header + Array(30..<110))
        _ = stitcher.append(first)

        XCTAssertEqual(stitcher.append(next), .appended(30))
        XCTAssertEqual(try rows(of: XCTUnwrap(stitcher.image)),
                       try rows(of: image(rows: header + Array(0..<110))))
    }

    func testFourPixelWideSelectionStillAppends() throws {
        var stitcher = ScrollingStitcher()
        _ = stitcher.append(try image(rows: Array(0..<80), width: 4))

        XCTAssertEqual(stitcher.append(try image(rows: Array(30..<110), width: 4)), .appended(30))
        XCTAssertEqual(stitcher.image?.height, 110)
    }

    private func image(rows: [Int], width: Int = 64) throws -> CGImage {
        let height = rows.count
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for (y, row) in rows.enumerated() {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = UInt8(truncatingIfNeeded: row &* 37 &+ x &* 71 &+ (row ^ x) &* 13)
                data[offset] = value
                data[offset + 1] = UInt8(truncatingIfNeeded: row &* 19 &+ x &* 43)
                data[offset + 2] = UInt8(truncatingIfNeeded: row &* 53 &+ x &* 11)
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func rows(of image: CGImage) throws -> [Int] {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.height).map { y in
            let offset = (y * image.width) * 4
            return Int(data[offset])
        }
    }
}
