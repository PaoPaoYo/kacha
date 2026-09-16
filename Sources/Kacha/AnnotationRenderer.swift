import CoreGraphics
import CoreImage
import Foundation

/// 标注像素合成：把归一化标注按 scale 重绘到选区裁剪图上（线宽×scale，箭头头长同步缩放）
enum AnnotationRenderer {
    /// scale = 图像像素宽 / 选区 point 宽；无标注返回原图引用
    static func composite(_ image: CGImage, annotations: [Annotation], selectionPointWidth: CGFloat) -> CGImage {
        guard !annotations.isEmpty, selectionPointWidth > 0 else { return image }
        let scale = CGFloat(image.width) / selectionPointWidth
        guard scale > 0,
              let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        // 底图（左下原点坐标语义）
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))

        // 切换到左上原点（与 AnnotationGeometry 局部坐标一致）：翻转 Y
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        // point 坐标系（局部选区原点即图像左上）
        ctx.scaleBy(x: scale, y: scale)

        let selection = CGRect(x: 0, y: 0, width: selectionPointWidth, height: CGFloat(image.height) / scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations {
            let path = AnnotationGeometry.path(for: a.kind, in: selection, lineWidth: a.lineWidth)
            // 高斯模糊：不走 stroke——路径按 lineWidth 展宽为区域，区域内底图 CIGaussianBlur
            // （半径 radius pt 固化于每笔，× scale 转像素）
            if case let .blur(_, radius) = a.kind {
                // 模糊生成失败也不回退成彩色描边（blur 不应有颜色语义）
                if let blurred = gaussianBlurred(image, scale: scale, radius: radius) {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.setLineWidth(a.lineWidth)
                    ctx.replacePathWithStrokedPath()
                    ctx.clip()
                    // 图像绘制遵循 CTM：当前 CTM 含 Y 翻转，直接画会上下镜像——先翻回再画，
                    // 保证模糊内容与底图位置一致（预览层 SwiftUI 无此问题，见 SelectionView）
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: selection.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: selection.width, height: selection.height))
                    ctx.restoreGState()
                    ctx.restoreGState()
                }
                continue
            }
            ctx.addPath(path)
            ctx.setLineWidth(a.lineWidth)
            ctx.setStrokeColor(CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a))
            ctx.setFillColor(CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a))
            ctx.strokePath()
            // 箭头头三角为第二子路径，stroke 后需再 fill 成实心头；
            // 线段子路径无面积、对 fill 无副作用（CG 光栅化会丢弃零面积子路径，已验证无空洞）
            if case .arrow = a.kind {
                ctx.addPath(path)  // strokePath 消费的是上下文路径；CGPath 不可变，可直接复用
                ctx.fillPath(using: .evenOdd)
            }
        }
        return ctx.makeImage() ?? image
    }

    /// 底图 CI 高斯模糊：半径 radius(pt，固化于每笔) × scale（像素）；clampedToExtent 防边缘发白/收缩，裁回原 extent
    static func gaussianBlurred(_ image: CGImage, scale: CGFloat, radius: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let clamped = ciImage.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius * scale, forKey: kCIInputRadiusKey)
        let blurred = (filter.outputImage ?? clamped).cropped(to: ciImage.extent)
        return sharedCIContext.createCGImage(blurred, from: ciImage.extent)
    }

    /// CIContext 线程安全、创建昂贵——全模块复用一份（输出合成与预览共用）。
    /// CIContext 未标 Sendable：nonisolated(unsafe) 豁免（同 SelectionView 环境键先例）
    nonisolated(unsafe) static let sharedCIContext = CIContext()
}
