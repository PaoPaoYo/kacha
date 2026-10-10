import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import kacha

@MainActor
final class CaptureResourceTests: XCTestCase {
    private final class Payload {}

    func testReplacingAndStoppingMonitorReleasesCapturedObjects() {
        _ = NSApplication.shared
        let monitor = LocalEventMonitor()
        weak var first: Payload?
        weak var second: Payload?
        autoreleasepool {
            let value = Payload()
            first = value
            monitor.start(matching: .applicationDefined) { [value] event in _ = value; return event }
        }
        XCTAssertNotNil(first)
        autoreleasepool {
            let value = Payload()
            second = value
            monitor.start(matching: .applicationDefined) { [value] event in _ = value; return event }
        }
        XCTAssertNil(first, "重复安装必须移除旧注册并释放旧闭包")
        XCTAssertTrue(monitor.isActive)
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isActive)
        XCTAssertNil(second)
    }

    func testMonitorDeinitRemovesRegistration() {
        weak var payload: Payload?
        autoreleasepool {
            let monitor = LocalEventMonitor()
            let value = Payload()
            payload = value
            monitor.start(matching: .applicationDefined) { [value] event in _ = value; return event }
            XCTAssertTrue(monitor.isActive)
        }
        XCTAssertNil(payload, "视图意外销毁时也必须清理注册")
    }

    func testClosingPanelDetachesViewAndImage() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        weak var view: CaptureBitmapView?
        weak var image: CGImage?
        autoreleasepool {
            let bitmap = makeImage(width: 64, height: 64) { y, x in UInt8(truncatingIfNeeded: x + y) }
            image = bitmap
            let content = CaptureBitmapView()
            content.image = bitmap
            view = content
            panel.contentView = content
            panel.initialFirstResponder = content
        }
        CaptureWindowLifecycle.close(panel)
        XCTAssertNil(panel.contentView)
        XCTAssertNil(panel.initialFirstResponder)
        XCTAssertNil(view?.image, "AppKit 即使暂留视图，也不应继续保留图片")
        XCTAssertNil(image)
    }

    func testImageDismantleDropsOwnedImage() {
        let view = CaptureBitmapView()
        weak var image: CGImage?
        autoreleasepool {
            let value = makeImage(width: 64, height: 64) { y, x in UInt8(truncatingIfNeeded: x + y) }
            image = value
            view.image = value
        }
        CaptureImageView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(image)
    }

    func testDetachedSmallCropReleasesFullScreenProvider() throws {
        weak var owner: PixelOwner?
        let detached: CGImage = try autoreleasepool {
            let pixels = PixelOwner(count: 400 * 300 * 4)
            owner = pixels
            let provider = try XCTUnwrap(CGDataProvider(dataInfo: Unmanaged.passRetained(pixels).toOpaque(),
                data: pixels.pointer, size: pixels.count, releaseData: { info, _, _ in
                    if let info { _ = Unmanaged<PixelOwner>.fromOpaque(info).takeRetainedValue() }
                }))
            let source = try XCTUnwrap(CGImage(width: 400, height: 300, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let crop = try XCTUnwrap(source.cropping(to: CGRect(x: 10, y: 20, width: 20, height: 10)))
            return try XCTUnwrap(CaptureBitmap.detached(crop))
        }
        XCTAssertNil(owner, "小钉图不得继续持有整屏像素的 provider")
        XCTAssertEqual(detached.width, 20)
        XCTAssertEqual(detached.height, 10)
        XCTAssertEqual(detached.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testPNGAndTIFFKeepDimensionsAlphaAndPixelOrientation() throws {
        let bytes: [UInt8] = [255,0,0,255, 0,128,0,128, 0,0,255,255, 0,0,0,0]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for type in [UTType.png, UTType.tiff] {
            let data = try XCTUnwrap(ClipboardService.encodedData(image, type: type))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let bitmap = try XCTUnwrap(CaptureBitmap.detached(decoded))
            XCTAssertEqual(bitmap.width, 2)
            XCTAssertEqual(bitmap.height, 2)
            let pixels = try XCTUnwrap(FramePixels(image: bitmap))
            for row in 0..<2 {
                for column in 0..<2 {
                    let pixel = pixels.pixelPointer(row: row, column: column)
                    let offset = (row * 2 + column) * 4
                    XCTAssertEqual(Int(pixel[pixels.redOffset]), Int(bytes[offset]), accuracy: 1)
                    XCTAssertEqual(Int(pixel[pixels.greenOffset]), Int(bytes[offset + 1]), accuracy: 1)
                    XCTAssertEqual(Int(pixel[pixels.blueOffset]), Int(bytes[offset + 2]), accuracy: 1)
                    XCTAssertEqual(Int(pixel[3]), Int(bytes[offset + 3]), accuracy: 1)
                }
            }
        }
    }
}

private final class PixelOwner {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    init(count: Int) {
        self.count = count
        pointer = .allocate(byteCount: count, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 255, count: count)
    }
    deinit { pointer.deallocate() }
}
