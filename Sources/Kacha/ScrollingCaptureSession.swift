import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

enum ScrollingToolbarGeometry {
    static func localFrame(anchor: CGPoint) -> CGRect {
        CGRect(x: anchor.x - 76, y: anchor.y - 34, width: 76, height: 34)
    }
}

/// 拼接服务：把逐帧分析与合成放到 actor 上执行（后台线程），
/// 主线程只负责把结果贴到 UI 上。旧实现直接在 MainActor 里做全图转换 + 暴力搜索，
/// 每 0.25s 就有一次 10–30ms 的主线程停顿，和预览渲染抢线程。
actor ScrollingStitchService {
    struct Update: Sendable {
        let result: ScrollingStitcher.Result
        let preview: CGImage?
        let pixelHeight: Int
        let bands: ScrollingStitcher.Bands
        let consecutiveFailures: Int
        let didRealign: Bool
    }

    private var stitcher = ScrollingStitcher()
    private var lastIngest = Date.distantPast
    /// 结束后不再接受帧；导出快照或丢弃画布后立即释放内部状态。
    private var isSealed = false
    /// 最短处理间隔：画面持续动画时也不会把 CPU 打满
    private let minimumInterval: TimeInterval = 0.06
    /// 预览刷新间隔：makePreview 的成本与长图当前高度成正比，长图越大越不该每帧都重算
    private let previewInterval: TimeInterval = 0.1
    private var cachedPreview: CGImage?
    private var finishedImage: CGImage?
    private var lastPreviewAt = Date.distantPast

    func ingest(_ frame: CGImage) -> Update? {
        guard !isSealed else { return nil }
        let now = Date()
        guard now.timeIntervalSince(lastIngest) >= minimumInterval else { return nil }
        lastIngest = now
        let result = stitcher.append(frame)
        if case .appended = result, now.timeIntervalSince(lastPreviewAt) >= previewInterval {
            cachedPreview = stitcher.preview
            lastPreviewAt = now
        } else if case .started = result {
            cachedPreview = stitcher.preview
            lastPreviewAt = now
        }
        return Update(result: result, preview: cachedPreview,
                      pixelHeight: stitcher.pixelHeight, bands: stitcher.bands,
                      consecutiveFailures: stitcher.consecutiveFailures,
                      didRealign: stitcher.didRealign)
    }

    /// 封盘并交出全分辨率长图。actor 串行执行保证：要么在途的帧先写完，要么被 `isSealed` 挡掉。
    func finishImage() -> CGImage? {
        guard !isSealed else { return finishedImage }
        isSealed = true
        finishedImage = stitcher.image
        releaseStorage()
        return finishedImage
    }

    func discard() {
        isSealed = true
        finishedImage = nil
        releaseStorage()
    }

    private func releaseStorage() {
        stitcher = ScrollingStitcher()
        cachedPreview = nil
    }
}

@MainActor
final class ScrollingCaptureSession: ObservableObject {
    @Published private(set) var preview: CGImage?
    @Published private(set) var status = "准备采集…"
    @Published private(set) var revision = 0

    private let service = ScrollingStitchService()
    private var stream: SCStream?
    private var output: ScrollingStreamOutput?
    private(set) var isFinished = false
    private let screen: NSScreen
    private let selection: CGRect
    private let toolbarAnchor: CGPoint
    private let onDismiss: () -> Void
    private let onOutput: (CGImage, CaptureAction) -> Void
    private var panel: NSPanel?
    private var toolbarPanel: NSPanel?
    private var borderPanel: NSPanel?

    init(screen: NSScreen, selection: CGRect, toolbarAnchor: CGPoint, onDismiss: @escaping () -> Void,
         onOutput: @escaping (CGImage, CaptureAction) -> Void) {
        self.screen = screen
        self.selection = selection
        self.toolbarAnchor = toolbarAnchor
        self.onDismiss = onDismiss
        self.onOutput = onOutput
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard !isFinished else { throw CancellationError() }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let ownApp = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw CaptureError.captureFailed(underlying: NSError(domain: "kacha.scrolling", code: 1))
        }
        let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        // SCDisplay 的 width/height 单位是 point，而 SCStreamConfiguration 的 width/height
        // 是输出像素数：直接赋值会让 Retina 屏上的长截图只有一半的线性分辨率。
        // 换算比例用 SCContentFilter.pointPixelScale（文档：screen points → pixels 的比例），
        // 而不是 NSScreen.backingScaleFactor —— 显示器跑缩放分辨率时两者不等
        // （例：1920pt 逻辑宽度落在 2880px 面板上是 1.5 而非 2，用后者会向上采样出模糊图）。
        let contentSize = filter.contentRect.size
        let pointPixelScale = CGFloat(filter.pointPixelScale)
        let pixelScale = pointPixelScale > 0 ? pointPixelScale : screen.backingScaleFactor
        let pixelWidth = max(1, Int((contentSize.width * pixelScale).rounded()))
        let pixelHeight = max(1, Int((contentSize.height * pixelScale).rounded()))
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.showsCursor = false
        configuration.queueDepth = 3

        // 选区在帧内的像素矩形：在回调里按**实际缓冲区尺寸**换算后直接裁 CVPixelBuffer，
        // 避免每帧把整屏 CGImage 转换出来再裁（Retina 下每帧 20MB+）。
        // 用实际尺寸而不是配置值，SCK 若做了缩放也不会裁错位置。
        let receiver = ScrollingStreamOutput(selection: selection, screenPointSize: screen.frame.size,
                                             onFrame: { [weak self] frame in
            await self?.receive(frame)
        }, onError: { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.fail(error)
            }
        })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: DispatchQueue(label: "kacha.scrolling.frames"))
        self.output = receiver
        self.stream = stream
        showPreview()
        do {
            try await stream.startCapture()
            if isFinished { try? await stream.stopCapture() }
        } catch {
            receiver.stopAcceptingFrames()
            closePanels()
            preview = nil
            await service.discard()
            self.stream = nil
            self.output = nil
            throw error
        }
    }

    /// 流回调已在后台队列裁剪好选区，这里只做线程切换与状态更新
    private func receive(_ frame: CGImage) async {
        guard !isFinished else { return }
        guard let update = await service.ingest(frame) else { return }
        apply(update)
    }

    private func apply(_ update: ScrollingStitchService.Update) {
        guard !isFinished else { return }
        let bands = update.bands
        let bandNote = bands.confirmed && !bands.isZero
            ? " · 已避开固定栏(顶\(bands.top)/底\(bands.bottom))" : ""
        switch update.result {
        case .started:
            preview = update.preview
            revision += 1
            status = "已截取首屏，请向下滚动"
        case .appended(let pixels):
            preview = update.preview
            revision += 1
            status = "已追加 \(pixels) 像素 · 总高 \(update.pixelHeight) 像素" + bandNote
        case .unchanged:
            break
        case .sizeChanged:
            status = "选区尺寸变化，已暂停拼接（缩回原尺寸可继续，或直接完成截图）"
        case .unmatched:
            let realignNote = update.didRealign ? "；已重新对齐参考帧，中间可能缺一段" : ""
            let hint = update.consecutiveFailures >= 3
                ? "（连续 \(update.consecutiveFailures) 次无法对齐：多为滚动过快、一次滚过一屏，或画面在动）"
                : "，请缓慢滚动"
            status = "本次未追加：画面无法对齐" + hint + realignNote + bandNote
        case .limitReached:
            status = "已到长图尺寸上限，请完成截图"
        }
    }

    func finish(_ action: CaptureAction) {
        guard !isFinished, preview != nil else { return }
        isFinished = true
        output?.stopAcceptingFrames()
        Task {
            let image = await service.finishImage()
            await stop()
            if let image { onOutput(image, action) }
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        output?.stopAcceptingFrames()
        Task {
            await service.discard()
            await stop()
        }
    }

    private func stop() async {
        output?.stopAcceptingFrames()
        closePanels()
        preview = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
        onDismiss()
    }

    private func closePanels() {
        for window in [panel, toolbarPanel, borderPanel].compactMap({ $0 }) {
            CaptureWindowLifecycle.close(window)
        }
        panel = nil
        toolbarPanel = nil
        borderPanel = nil
    }

    private func fail(_ error: Error) async {
        guard !isFinished else { return }
        isFinished = true
        output?.stopAcceptingFrames()
        await service.discard()
        await stop()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "长截图采集已停止"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showPreview() {
        let region = PinWindowController.appkitFrame(fromLocal: selection, on: screen)
        let border = NSPanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        border.isReleasedWhenClosed = false
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.hidesOnDeactivate = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView:
            Rectangle().strokeBorder(.green, lineWidth: 2)
                .allowsHitTesting(false))
        border.orderFrontRegardless()
        borderPanel = border

        let toolbarRegion = PinWindowController.appkitFrame(
            fromLocal: ScrollingToolbarGeometry.localFrame(anchor: toolbarAnchor), on: screen)
        let toolbar = NSPanel(contentRect: toolbarRegion, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        toolbar.isReleasedWhenClosed = false
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.level = .floating
        toolbar.hidesOnDeactivate = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.contentView = NSHostingView(rootView: ScrollingCaptureToolbar(session: self))
        toolbar.orderFrontRegardless()
        toolbarPanel = toolbar

        let previewPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 420),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        previewPanel.isReleasedWhenClosed = false
        previewPanel.isOpaque = false
        previewPanel.backgroundColor = .clear
        previewPanel.hasShadow = true
        previewPanel.isMovableByWindowBackground = true
        previewPanel.level = .floating
        previewPanel.hidesOnDeactivate = false
        previewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        previewPanel.contentView = NSHostingView(rootView: ScrollingPreviewView(session: self))
        let visible = screen.visibleFrame
        let x: CGFloat
        if region.minX - visible.minX >= 350 {
            x = region.minX - 344
        } else if visible.maxX - region.maxX >= 350 {
            x = region.maxX + 4
        } else {
            x = max(visible.minX, min(visible.maxX - 340, region.minX))
        }
        previewPanel.setFrameOrigin(CGPoint(x: x, y: max(visible.minY, min(visible.maxY - 420, region.midY - 210))))
        previewPanel.orderFrontRegardless()
        panel = previewPanel
    }
}

private final class ScrollingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let selection: CGRect
    private let screenPointSize: CGSize
    private let onFrame: @Sendable (CGImage) async -> Void
    private let onError: @Sendable (Error) -> Void
    private let admission = ScrollingFrameAdmission()

    init(selection: CGRect, screenPointSize: CGSize, onFrame: @escaping @Sendable (CGImage) async -> Void,
         onError: @escaping @Sendable (Error) -> Void) {
        self.selection = selection
        self.screenPointSize = screenPointSize
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer,
              admission.begin() else { return }
        guard let image = autoreleasepool(invoking: {
            Self.croppedImage(from: buffer, selection: selection, screenPointSize: screenPointSize)
        }) else {
            admission.end()
            return
        }
        let admission = admission
        let onFrame = onFrame
        Task {
            defer { admission.end() }
            await onFrame(image)
        }
    }

    func stopAcceptingFrames() {
        admission.close()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        admission.close()
        onError(error)
    }

    private static let ciContext = CIContext()

    /// 直接把选区行从 CVPixelBuffer 拷进紧凑缓冲区，不再整屏转 CGImage。
    private static func croppedImage(from buffer: CVPixelBuffer, selection: CGRect,
                                     screenPointSize: CGSize) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rect = SelectionGeometry.pixelRect(pointRect: selection, screenPointSize: screenPointSize,
                                               imagePixelSize: CGSize(width: width, height: height))
        // 下面按 32 位 BGRA 逐行拷贝。格式不符（平面格式 / 16・24 位）时绝不能硬算：
        // 平面格式的 base address 是 NULL，会变成"静默丢帧、预览永远不动"。
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            return convertedImage(from: buffer, rect: rect)
        }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = max(0, min(width, Int(rect.minX.rounded(.down))))
        let y0 = max(0, min(height, Int(rect.minY.rounded(.down))))
        let x1 = max(x0, min(width, Int(rect.maxX.rounded(.up))))
        let y1 = max(y0, min(height, Int(rect.maxY.rounded(.up))))
        let cropWidth = x1 - x0
        let cropHeight = y1 - y0
        guard cropWidth > 0, cropHeight > 0 else { return nil }

        let destinationBytesPerRow = cropWidth * 4
        var pixels = [UInt8](repeating: 0, count: destinationBytesPerRow * cropHeight)
        pixels.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress else { return }
            let source = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<cropHeight {
                memcpy(destination + row * destinationBytesPerRow,
                       source + (y0 + row) * sourceBytesPerRow + x0 * 4,
                       destinationBytesPerRow)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        // SCK 按 configuration.pixelFormat 输出 32BGRA：内存顺序 B,G,R,A。
        // alpha 用 noneSkipFirst 而不是 premultipliedFirst：屏幕帧若带 alpha，
        // 标成"预乘"会被下游当透明度解释；通道偏移与 FramePixels 的推导一致。
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        let colorSpace = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(width: cropWidth, height: cropHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: destinationBytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 非 32BGRA 时的回退路径：走 CoreImage 转换一次再裁（和旧实现同路，慢但不丢帧）
    private static func convertedImage(from buffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let full = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return full.cropping(to: rect.integral)
    }
}

private struct ScrollingCaptureToolbar: View {
    @ObservedObject var session: ScrollingCaptureSession

    var body: some View {
        CaptureActionButtons(onSave: { session.finish(.save) },
                             onCopy: { session.finish(.copy) })
            .disabled(session.preview == nil)
            .frame(height: 24)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(in: Capsule())
            .frame(width: 76, height: 34)
    }
}

private struct ScrollingPreviewView: View {
    @ObservedObject var session: ScrollingCaptureSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let image = session.preview {
                    CaptureImageView(image: image)
                        .allowsHitTesting(false)
                        .frame(width: 324, height: 324 * CGFloat(image.height) / CGFloat(image.width))
                    Color.clear.frame(height: 1).id("bottom")
                } else {
                    ProgressView()
                        .frame(width: 324, height: 404)
                }
            }
            .contentMargins(8)
            .onChange(of: session.revision) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(width: 340, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
