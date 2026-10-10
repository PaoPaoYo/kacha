import AppKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
@testable import kacha

/// 显式开启的真实窗口压力测试：避免日常单测不断覆盖用户桌面。
@MainActor
final class CaptureMemoryStressTests: XCTestCase {
    func testRepeated4KCaptureWindowsReachStableMemory() async throws {
        guard ProcessInfo.processInfo.environment["KACHA_MEMORY_STRESS"] == "1" else {
            throw XCTSkip("设置 KACHA_MEMORY_STRESS=1 执行真实窗口内存回归")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = OverlayController()
        var samples: [UInt64] = []
        for iteration in 1...60 {
            try autoreleasepool {
                let context = try XCTUnwrap(CGContext(data: nil, width: 3840, height: 2160,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                for row in stride(from: 0, to: 2160, by: 24) {
                    context.setFillColor(CGColor(red: CGFloat((row + iteration * 7) % 255) / 255,
                        green: CGFloat((row * 3 + iteration * 11) % 255) / 255, blue: 0.6, alpha: 1))
                    context.fill(CGRect(x: 0, y: row, width: 3840, height: 24))
                }
                let original = try XCTUnwrap(context.makeImage())
                let png = try XCTUnwrap(ClipboardService.pngData(original))
                let provider = try XCTUnwrap(CGDataProvider(data: png as CFData))
                let image = try XCTUnwrap(CGImage(pngDataProviderSource: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent))
                controller.show(frames: [ScreenFrame(screen: screen, image: image)], windowsByScreen: [:],
                    onCapture: { _, _, _ in }, onScroll: { _, _, _ in }, onCancel: {})
            }
            try await Task.sleep(for: .milliseconds(60))
            autoreleasepool { controller.dismissAll() }
            try await Task.sleep(for: .milliseconds(60))
            if iteration.isMultiple(of: 10) {
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(200))
                let footprint = try physicalFootprint()
                samples.append(footprint)
                print("KACHA_MEMORY_SAMPLE captures=\(iteration) footprintMiB=\(Double(footprint) / 1_048_576)")
            }
        }
        if ProcessInfo.processInfo.environment["KACHA_MEMORY_BASELINE"] != "1" {
            let warm = try XCTUnwrap(samples.first)
            let final = try XCTUnwrap(samples.last)
            XCTAssertLessThan(final, warm + 96 * 1_048_576, "预热后再截 50 次，不能继续积累全屏图片")
            XCTAssertLessThan(final, 512 * 1_048_576, "60 次 4K 截图后应低于 512 MiB")
        }
    }

    func testRepeatedPinAndBlurWindowsReachStableMemory() async throws {
        guard ProcessInfo.processInfo.environment["KACHA_MEMORY_STRESS"] == "1" else {
            throw XCTSkip("设置 KACHA_MEMORY_STRESS=1 执行钉图和打码内存回归")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        var warm: UInt64 = 0
        for iteration in 1...60 {
            let panel: NSPanel = try autoreleasepool {
                let image = makeImage(width: 1280, height: 720) { y, x in
                    UInt8(truncatingIfNeeded: y * 19 + x * 11 + iteration)
                }
                PinWindowController.shared.pin(image, frame: CGRect(x: screen.frame.minX + 60,
                    y: screen.frame.minY + 80, width: 640, height: 360))
                let panel = NSPanel(contentRect: CGRect(x: screen.frame.minX + 100,
                    y: screen.frame.minY + 100, width: 640, height: 360),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                let selection = CGRect(x: 0, y: 0, width: 640, height: 360)
                let annotations = [Annotation(kind: .blur(points: [CGPoint(x: 0.1, y: 0.4),
                    CGPoint(x: 0.9, y: 0.6)], radius: CGFloat(4 + iteration % 16)), color: .black, lineWidth: 40)]
                panel.contentView = NSHostingView(rootView: ZStack {
                    CaptureImageView(image: image)
                    CaptureAnnotationPreview(image: image, pointSize: selection.size,
                        selection: selection, annotations: annotations)
                })
                panel.orderFrontRegardless()
                return panel
            }
            try await Task.sleep(for: .milliseconds(80))
            autoreleasepool {
                CaptureWindowLifecycle.close(panel)
                PinWindowController.shared.closeAll()
            }
            try await Task.sleep(for: .milliseconds(80))
            if iteration.isMultiple(of: 10) {
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(200))
                let footprint = try physicalFootprint()
                if iteration == 10 { warm = footprint }
                print("KACHA_PIN_BLUR_SAMPLE cycles=\(iteration) footprintMiB=\(Double(footprint) / 1_048_576)")
                if iteration == 60 {
                    XCTAssertLessThan(footprint, warm + 96 * 1_048_576)
                    XCTAssertLessThan(footprint, 512 * 1_048_576)
                }
            }
        }
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return info.phys_footprint
    }
}
