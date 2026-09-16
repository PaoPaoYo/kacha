import CoreGraphics
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
            // 马赛克：不走 stroke——路径按 lineWidth 展宽为区域，区域内底图像素块化（20pt 块，降采样放大）
            if case .mosaic = a.kind,
               let small = downsampledBlockImage(image, scale: scale, in: ctx) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(a.lineWidth)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.interpolationQuality = .none
                // 图像绘制遵循 CTM：当前 CTM 含 Y 翻转，直接画会上下镜像——先翻回再画，
                // 保证块内容与底图位置一致（预览层 SwiftUI 无此问题，见 SelectionView）
                ctx.saveGState()
                ctx.translateBy(x: 0, y: selection.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(small, in: CGRect(x: 0, y: 0, width: selection.width, height: selection.height))
                ctx.restoreGState()
                ctx.restoreGState()
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

    /// 底图降采样：块大小（像素）= 20 × scale；小图 = 原图 / 块（none 插值取样），
    /// 放大回去（none 插值）即每块取一像素的块状马赛克
    private static func downsampledBlockImage(_ image: CGImage, scale: CGFloat, in ctx: CGContext) -> CGImage? {
        let blockSize = max(2, Int(20 * scale))
        let smallW = max(1, image.width / blockSize)
        let smallH = max(1, image.height / blockSize)
        guard let smallCtx = CGContext(data: nil, width: smallW, height: smallH, bitsPerComponent: 8,
                                       bytesPerRow: 0, space: ctx.colorSpace ?? image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        smallCtx.interpolationQuality = .none
        smallCtx.draw(image, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        return smallCtx.makeImage()
    }
}
