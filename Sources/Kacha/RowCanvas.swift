import CoreGraphics
import Foundation

/// 增量长图画布。
///
/// 旧实现每次追加都新建一张「旧图 + 新增行」的 CGContext 并把整张旧图重画一遍，
/// 单次拼接一半以上时间花在这里，而且是 O(n²)：长图越高越慢，追加瞬间还要同时
/// 持有旧图与新图（实测 24000×1600 时进程峰值 405MB）。
///
/// 这里改成：按上限一次性 malloc 好容量（虚拟内存，写到哪里才驻留），之后每次追加
/// 只 memcpy 新增的行，指针恒定 ⇒ 生成 CGImage 零拷贝、追加成本 O(新增行数)。
///
/// `makeImage()` 交出的是一份**快照**（只拷贝实际用到的行）：之后 append 不会改写它，
/// 画布也可以随之释放 —— 导出图不会再钉住整块容量内存。
final class RowCanvas {
    let pixelWidth: Int
    let bytesPerRow: Int
    let maxHeight: Int
    let bitmapInfo: CGBitmapInfo
    let colorSpace: CGColorSpace

    private(set) var height = 0
    private var buffer: UnsafeMutableRawPointer?

    var remainingRows: Int { maxHeight - height }
    var isFull: Bool { height >= maxHeight }

    init(width: Int, maxHeight: Int, maxBytes: Int, bitmapInfo: CGBitmapInfo, colorSpace: CGColorSpace) {
        self.pixelWidth = max(1, width)
        self.bytesPerRow = self.pixelWidth * 4
        self.maxHeight = max(1, min(maxHeight, max(1, maxBytes / self.bytesPerRow)))
        self.bitmapInfo = bitmapInfo
        self.colorSpace = colorSpace
    }

    deinit {
        if let buffer { free(buffer) }
    }

    /// 追加 `source` 的 [rows] 区段到画布末尾。
    ///
    /// `overlap` 表示"先把已有内容回退 overlap 行、再由新帧覆盖"：新帧的渲染会盖住
    /// 接缝，从而掩掉亚像素渲染差异，同时不丢任何内容（旧实现直接把新帧画在旧图上方，
    /// 也是这个意图，但代价是整图重绘）。画布高度净增 = rows.count - 实际回退行数。
    ///
    /// 返回 false 表示超出容量上限（调用方应据此结束采集）。
    @discardableResult
    func append(_ source: FramePixels, rows: Range<Int>, overlap: Int) -> Bool {
        guard rows.lowerBound >= 0, rows.upperBound <= source.height,
              source.bytesPerRow >= source.width * 4 else { return false }
        guard !rows.isEmpty else { return true }   // 空区间是合法 no-op，不代表超容量
        let rewind = min(max(0, overlap), height)
        let start = height - rewind
        let newHeight = start + rows.count
        guard newHeight <= maxHeight else { return false }
        if buffer == nil {
            buffer = malloc(bytesPerRow * maxHeight)
            guard buffer != nil else { return false }
        }
        guard let base = buffer else { return false }
        let destination = base.advanced(by: start * bytesPerRow)
        if source.bytesPerRow == bytesPerRow {
            memcpy(destination, source.rowPointer(rows.lowerBound), rows.count * bytesPerRow)
        } else {
            // 行跨距不同（window server 补齐）：逐行拷贝，仍然只有新增行的成本
            let copyBytes = min(bytesPerRow, source.bytesPerRow)
            for offset in 0..<rows.count {
                memcpy(destination.advanced(by: offset * bytesPerRow),
                       source.rowPointer(rows.lowerBound + offset),
                       copyBytes)
            }
        }
        height = newHeight
        return true
    }

    /// 截掉尾部若干行（用于首帧含固定底栏时回退到内容区边界）
    @discardableResult
    func truncate(to newHeight: Int) -> Bool {
        guard newHeight >= 0, newHeight <= height else { return false }
        height = newHeight
        return true
    }

    /// 快照成 CGImage（只拷贝 height 行，不是整块容量）。拷贝一次换取清晰的所有权语义：
    /// 交付出去的图不再随后续 append 改变，也不必为了安全而一直留着画布。
    func makeImage() -> CGImage? {
        guard let buffer, height > 0 else { return nil }
        let size = height * bytesPerRow
        guard let provider = CGDataProvider(data: Data(bytes: buffer, count: size) as CFData) else { return nil }
        return CGImage(width: pixelWidth, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 预览图：按整数步长抽样。成本与**长图当前高度**成正比（O(height/step²) 量级），
    /// 所以调用方要限频（见 `ScrollingStitchService` 的预览节流），避免长图越长越费。
    func makePreview(maxWidth: Int) -> CGImage? {
        guard let buffer, height > 0, pixelWidth > 0, maxWidth > 0 else { return nil }
        let step = max(1, (pixelWidth + maxWidth - 1) / maxWidth)
        let previewWidth = max(1, pixelWidth / step)
        let previewHeight = max(1, height / step)
        var pixels = [UInt8](repeating: 0, count: previewWidth * previewHeight * 4)
        let source = buffer.assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeMutableBufferPointer { destination in
            guard let out = destination.baseAddress else { return }
            for y in 0..<previewHeight {
                let sourceRow = source + (y * step) * bytesPerRow
                let destinationRow = y * previewWidth * 4
                for x in 0..<previewWidth {
                    let s = sourceRow + (x * step) * 4
                    let d = destinationRow + x * 4
                    out[d] = s[0]
                    out[d + 1] = s[1]
                    out[d + 2] = s[2]
                    out[d + 3] = s[3]
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: previewWidth, height: previewHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: previewWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
