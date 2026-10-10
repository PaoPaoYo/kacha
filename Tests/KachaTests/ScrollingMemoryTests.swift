import AppKit
import XCTest
@testable import kacha

final class ScrollingMemoryTests: XCTestCase {
    func testAdmissionRejectsFramesUntilProcessingCompletes() {
        let admission = ScrollingFrameAdmission()
        XCTAssertTrue(admission.begin())
        for _ in 0..<500 { XCTAssertFalse(admission.begin(), "慢拼接期间不得积压帧") }
        admission.end()
        XCTAssertTrue(admission.begin())
        admission.end()
    }

    func testClosedAdmissionNeverReopensAfterInflightFrameEnds() {
        let admission = ScrollingFrameAdmission()
        XCTAssertTrue(admission.begin())
        admission.close()
        admission.end()
        for _ in 0..<500 { XCTAssertFalse(admission.begin()) }
    }

    func testConcurrentFrameAdmissionStaysSingleFlight() {
        let admission = ScrollingFrameAdmission()
        let counter = ConcurrentCounter()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            guard admission.begin() else { return }
            counter.enter()
            Thread.sleep(forTimeInterval: 0.001)
            counter.leave()
            admission.end()
        }
        XCTAssertEqual(counter.maximum, 1)
    }

    func testDiscardDoesNotProduceSnapshotAndReleasesPreview() async throws {
        let service = ScrollingStitchService()
        weak var preview: CGImage?
        let image = makeImage(width: 64, height: 120) { y, x in UInt8(truncatingIfNeeded: y * 23 + x) }
        do {
            let update = await service.ingest(image)
            preview = try XCTUnwrap(update?.preview)
        }
        await service.discard()
        XCTAssertNil(preview, "取消后预览缓存应立即释放")
        let output = await service.finishImage()
        XCTAssertNil(output, "取消不能偷偷分配完整长图")
        let late = await service.ingest(image)
        XCTAssertNil(late)
    }

    func testFinishReusesSnapshotButReleasesPreview() async throws {
        let service = ScrollingStitchService()
        weak var preview: CGImage?
        do {
            let update = await service.ingest(makeImage(width: 64, height: 120) { y, x in
                UInt8(truncatingIfNeeded: y * 23 + x)
            })
            preview = try XCTUnwrap(update?.preview)
        }
        let value = await service.finishImage()
        let output = try XCTUnwrap(value)
        XCTAssertNil(preview)
        let again = await service.finishImage()
        XCTAssertTrue(output === again, "重复封盘必须复用快照，不能重新复制")
        await service.discard()
        let discarded = await service.finishImage()
        XCTAssertNil(discarded)
    }

    func testCanvasSnapshotSurvivesOverwriteAndCanvasRelease() throws {
        var canvas: RowCanvas? = RowCanvas(width: 8, maxHeight: 32, maxBytes: 1_000_000,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            colorSpace: CGColorSpaceCreateDeviceRGB())
        let original = makeImage(width: 8, height: 6) { y, x in UInt8(truncatingIfNeeded: y * 10 + x) }
        XCTAssertTrue(canvas!.append(try XCTUnwrap(FramePixels(image: original)), rows: 0..<6, overlap: 0))
        let snapshot = try XCTUnwrap(canvas?.makeImage())
        let expected = pixels(of: snapshot)
        let new = makeImage(width: 8, height: 6) { _, _ in 200 }
        XCTAssertTrue(canvas!.append(try XCTUnwrap(FramePixels(image: new)), rows: 0..<6, overlap: 6))
        canvas?.truncate(to: 2)
        canvas = nil
        XCTAssertEqual(pixels(of: snapshot), expected)
    }
}

private final class ConcurrentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }
    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
