import CoreGraphics
import Foundation

/// 一帧的原始像素访问封装。
///
/// 只接受 8 位/像素、32 位/像素的 RGB 位图——ScreenCaptureKit 的 BGRA 帧与测试里
/// `CGContext` 产出的 RGBA 帧都属于这一类；其它格式返回 nil，由调用方决定回退策略。
///
/// 通道偏移由 `alphaInfo` + `byteOrder` 推出，不假设"一定是 RGBA 还是 BGRA"，
/// 这样才能在两种来源上共用同一套匹配与合成代码。
///
/// 注意：地址计算一律使用图像自身的 `bytesPerRow`。用 `width * 4` 推算在
/// window server 为行对齐补齐字节时会逐行累积错位，第一行之后每个采样点
/// 都会落到错误位置。
struct FramePixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bitmapInfo: CGBitmapInfo
    let colorSpace: CGColorSpace?
    let redOffset: Int
    let greenOffset: Int
    let blueOffset: Int

    private let storage: CFData
    private let bytes: UnsafePointer<UInt8>

    init?(image: CGImage) {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.colorSpace?.model == .rgb,
              !image.bitmapInfo.contains(.floatComponents),
              image.width > 0, image.height > 0 else { return nil }
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        guard let offsets = Self.channelOffsets(alphaInfo: image.alphaInfo, byteOrder: byteOrder),
              image.bytesPerRow >= image.width * 4 else { return nil }
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.bytesPerRow * image.height else { return nil }
        self.width = image.width
        self.height = image.height
        self.bytesPerRow = image.bytesPerRow
        self.bitmapInfo = image.bitmapInfo
        self.colorSpace = image.colorSpace
        self.redOffset = offsets.red
        self.greenOffset = offsets.green
        self.blueOffset = offsets.blue
        self.storage = data
        self.bytes = pointer
    }

    /// 内存里各通道的字节位置。`alphaInfo` 描述的是 32 位字内的语义顺序，
    /// 字节序为 little-endian 时内存顺序与语义顺序相反，故两两组合共四种。
    private static func channelOffsets(alphaInfo: CGImageAlphaInfo,
                                       byteOrder: CGBitmapInfo) -> (red: Int, green: Int, blue: Int)? {
        let alphaFirst: Bool
        switch alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: alphaFirst = true
        case .last, .premultipliedLast, .noneSkipLast: alphaFirst = false
        default: return nil
        }
        switch byteOrder {
        case .byteOrderDefault, .byteOrder32Big:
            return alphaFirst ? (1, 2, 3) : (0, 1, 2)
        case .byteOrder32Little:
            return alphaFirst ? (2, 1, 0) : (3, 2, 1)
        default:
            return nil
        }
    }

    @inline(__always)
    func rowPointer(_ row: Int) -> UnsafePointer<UInt8> {
        bytes + row * bytesPerRow
    }

    @inline(__always)
    func pixelPointer(row: Int, column: Int) -> UnsafePointer<UInt8> {
        bytes + row * bytesPerRow + column * 4
    }

    /// 亮度（BT.601 整数近似），用于行签名
    @inline(__always)
    func luminance(row: Int, column: Int) -> Int {
        let p = pixelPointer(row: row, column: column)
        return (77 * Int(p[redOffset]) + 150 * Int(p[greenOffset]) + 29 * Int(p[blueOffset])) >> 8
    }

    /// 两帧同一像素的三通道绝对差之和（0…765）
    @inline(__always)
    func channelDifference(_ other: FramePixels, row: Int, column: Int) -> Int {
        let a = pixelPointer(row: row, column: column)
        let b = other.pixelPointer(row: row, column: column)
        return abs(Int(a[redOffset]) - Int(b[other.redOffset]))
            + abs(Int(a[greenOffset]) - Int(b[other.greenOffset]))
            + abs(Int(a[blueOffset]) - Int(b[other.blueOffset]))
    }
}
