import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

@MainActor
final class ScrollingCaptureSession: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var status = "准备采集…"
    @Published private(set) var revision = 0
    @Published private(set) var isCompact = false

    private var stitcher = ScrollingStitcher()
    private var stream: SCStream?
    private var output: ScrollingStreamOutput?
    private var lastSample = Date.distantPast
    private var processing = false
    private(set) var isFinished = false
    private let screen: NSScreen
    private let selection: CGRect
    private let onDismiss: () -> Void
    private let onOutput: (CGImage, CaptureAction) -> Void
    private var panel: NSPanel?
    private var borderPanel: NSPanel?

    init(screen: NSScreen, selection: CGRect, onDismiss: @escaping () -> Void,
         onOutput: @escaping (CGImage, CaptureAction) -> Void) {
        self.screen = screen
        self.selection = selection
        self.onDismiss = onDismiss
        self.onOutput = onOutput
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let ownApp = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw CaptureError.captureFailed(underlying: NSError(domain: "kacha.scrolling", code: 1))
        }
        let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        let receiver = ScrollingStreamOutput(onFrame: { [weak self] frame in
            Task { @MainActor [weak self] in self?.receive(frame) }
        }, onError: { [weak self] error in
            Task { @MainActor [weak self] in self?.status = "采集失败：\(error.localizedDescription)" }
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
            panel?.close()
            panel = nil
            borderPanel?.close()
            borderPanel = nil
            self.stream = nil
            self.output = nil
            throw error
        }
    }

    private func receive(_ frame: CGImage) {
        guard !isFinished, !processing, Date().timeIntervalSince(lastSample) > 0.25 else { return }
        let pixelRect = SelectionGeometry.pixelRect(pointRect: selection,
                                                     screenPointSize: screen.frame.size,
                                                     imagePixelSize: CGSize(width: frame.width, height: frame.height))
        guard let crop = frame.cropping(to: pixelRect) else { return }
        processing = true
        lastSample = Date()
        let result = stitcher.append(crop)
        switch result {
        case .started:
            image = stitcher.image
            revision += 1
            status = "已截取首屏，请向下滚动"
        case .appended(let pixels):
            image = stitcher.image
            revision += 1
            status = "已追加 \(pixels) 像素 · 总高 \(image?.height ?? 0) 像素"
        case .unchanged:
            break
        case .unmatched:
            status = "本次未追加：画面无法对齐，请缓慢滚动"
        case .limitReached:
            status = "已到长图尺寸上限，请完成截图"
        }
        processing = false
    }

    func togglePreview() {
        isCompact.toggle()
        guard let panel else { return }
        let top = panel.frame.maxY
        let height: CGFloat = isCompact ? 124 : 470
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - height, width: 340, height: height), display: true)
    }

    func finish(_ action: CaptureAction) {
        guard !isFinished, let image else { return }
        isFinished = true
        Task {
            await stop()
            onOutput(image, action)
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        Task { await stop() }
    }

    private func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
        panel?.close()
        panel = nil
        borderPanel?.close()
        borderPanel = nil
        onDismiss()
    }

    private func showPreview() {
        let region = PinWindowController.appkitFrame(fromLocal: selection, on: screen)
        let border = NSPanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
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

        let preview = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 470),
                              styleMask: [.titled, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        preview.title = "长截图预览"
        preview.level = .floating
        preview.isFloatingPanel = true
        preview.hidesOnDeactivate = false
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        preview.contentView = NSHostingView(rootView: ScrollingPreviewView(session: self))
        let visible = screen.visibleFrame
        let x: CGFloat
        if region.minX - visible.minX >= 350 {
            x = region.minX - 344
        } else if visible.maxX - region.maxX >= 350 {
            x = region.maxX + 4
        } else {
            x = max(visible.minX, min(visible.maxX - 340, region.minX))
        }
        preview.setFrameOrigin(CGPoint(x: x, y: max(visible.minY, min(visible.maxY - 470, region.midY - 235))))
        preview.orderFrontRegardless()
        panel = preview
    }
}

private final class ScrollingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let context = CIContext()
    private let onFrame: @Sendable (CGImage) -> Void
    private let onError: @Sendable (Error) -> Void

    init(onFrame: @escaping @Sendable (CGImage) -> Void, onError: @escaping @Sendable (Error) -> Void) {
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
              let image = context.createCGImage(CIImage(cvPixelBuffer: buffer),
                                                 from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer),
                                                              height: CVPixelBufferGetHeight(buffer))) else { return }
        onFrame(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError(error)
    }
}

private struct ScrollingPreviewView: View {
    @ObservedObject var session: ScrollingCaptureSession

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.status)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                Button {
                    session.togglePreview()
                } label: {
                    Image(systemName: session.isCompact ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.plain)
                .help(session.isCompact ? "展开预览" : "收起预览")
            }
            if !session.isCompact {
            ScrollViewReader { proxy in
                ScrollView {
                    if let image = session.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: 300, height: 300 * CGFloat(image.height) / CGFloat(image.width))
                            .id(session.revision)
                    } else {
                        ProgressView("等待首帧")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .onChange(of: session.revision) { _, new in
                    withAnimation { proxy.scrollTo(new, anchor: .bottom) }
                }
            }
            }
            HStack {
                Button("取消") { session.cancel() }
                Spacer()
                Button("保存") { session.finish(.save) }
                    .disabled(session.image == nil)
                Button("复制") { session.finish(.copy) }
                    .disabled(session.image == nil)
            }
        }
        .padding(12)
        .frame(width: 340, height: session.isCompact ? 94 : 440)
    }
}
