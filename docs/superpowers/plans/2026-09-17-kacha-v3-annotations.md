# Kacha V3 标注工具 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 调整态选区内绘制箭头/矩形/椭圆/画笔标注（8 色板、3 档粗细、撤销），确认时按像素比例合成到输出图（圆角化之前）

**Architecture:** 标注几何用归一化坐标（0–1 相对选区）存储，选区形变自动跟随；单一几何函数产出 CGPath 供 SwiftUI Canvas（屏幕预览）与 CGContext（像素合成）两处同构渲染；绘制手势以覆盖层接管选区内拖动，「选择」工具恢复现有平移/缩放。

**Tech Stack:** Swift 6 / SwiftUI（Canvas）/ CoreGraphics（CGContext 合成）

**Spec:** `docs/superpowers/specs/2026-09-17-kacha-v3-annotations-design.md`

## Global Constraints

- 色板固定 8 色：红 `#FF3B30`、橙 `#FF9500`、黄 `#FFCC00`、绿 `#34C759`、蓝 `#007AFF`、紫 `#AF52DE`、黑 `#000000`、白 `#FFFFFF`
- 粗细三档 pt：2 / 4 / 8；箭头头长 = `max(3 × lineWidth, 10)`（pt），头半角 15°
- 标注几何为归一化坐标（0–1，相对选区），lineWidth 为绝对 pt（不随选区缩放）
- 绘制 clamp 到选区；有效性：arrow/rect/ellipse 局部长度 < 4pt 丢弃、pen < 2 点丢弃、pen 采样与上一点距离 > 1pt 才记录
- 合成顺序：裁剪 → 标注合成（scale = 图像像素宽 / 选区 point 宽）→ 圆角化 → 输出
- 白色标注在色板 UI 与画布上加 1pt 可见描边（仅 UI/预览层；合成不加）
- 工具栏全部 24pt 高玻璃胶囊风格；选区外无操作语义不破坏
- 提交信息：中文 + Conventional Commits 前缀，末尾 `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- 既有 30 个测试不得回归；验证命令 `swift test` / `make install`

---

### Task 1: Annotation 模型与几何（TDD）

**Files:**
- Create: `Sources/Kacha/Annotation.swift`
- Test: `Tests/KachaTests/AnnotationTests.swift`

**Interfaces:**
- Consumes: 无（纯 Foundation/CoreGraphics）
- Produces:
  - `struct RGBA: Equatable { var r, g, b, a: Double; static let palette: [RGBA]; static let red/orange/yellow/green/blue/purple/black/white }`
  - `enum AnnotationTool: Equatable { case select, arrow, rect, ellipse, pen; var takesOverDrag: Bool }`
  - `enum AnnotationWidth: CaseIterable { case thin, medium, thick; var pt: CGFloat; var dotDiameter: CGFloat }`
  - `struct Annotation: Identifiable, Equatable { enum Kind: Equatable { case arrow(start: CGPoint, end: CGPoint); case rect(CGRect); case ellipse(CGRect); case pen(points: [CGPoint]) }; let id: UUID; var kind: Kind; var color: RGBA; var lineWidth: CGFloat; init(kind:color:lineWidth:) }`
  - `enum AnnotationGeometry { static func normalizedPoint(_:in:) -> CGPoint; static func localPoint(_:in:) -> CGPoint; static func arrowHeadLength(lineWidth:) -> CGFloat; static func shouldAppendPenPoint(_:after:) -> Bool; static func path(for:in:lineWidth:) -> CGPath; static func isValid(_:selectionSize:) -> Bool }`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import kacha

final class AnnotationTests: XCTestCase {
    let sel = CGRect(x: 100, y: 50, width: 200, height: 100)

    // MARK: 归一化换算

    func test_normalizedPoint_center() {
        let n = AnnotationGeometry.normalizedPoint(CGPoint(x: 200, y: 100), in: sel)
        XCTAssertEqual(n, CGPoint(x: 0.5, y: 0.5))
    }

    func test_normalizedPoint_clampsOutside() {
        let n = AnnotationGeometry.normalizedPoint(CGPoint(x: -50, y: 400), in: sel)
        XCTAssertEqual(n, CGPoint(x: 0, y: 1))
    }

    func test_localPoint_roundTrip() {
        let n = CGPoint(x: 0.25, y: 0.75)
        let p = AnnotationGeometry.localPoint(n, in: sel)
        XCTAssertEqual(p, CGPoint(x: 150, y: 125))
        XCTAssertEqual(AnnotationGeometry.normalizedPoint(p, in: sel), n)
    }

    // MARK: 箭头头几何

    func test_arrowHeadLength_minimum10() {
        XCTAssertEqual(AnnotationGeometry.arrowHeadLength(lineWidth: 2), 10)
    }

    func test_arrowHeadLength_scalesWithWidth() {
        XCTAssertEqual(AnnotationGeometry.arrowHeadLength(lineWidth: 8), 24)
    }

    // MARK: pen 采样

    func test_penAppend_firstPointAlways() {
        XCTAssertTrue(AnnotationGeometry.shouldAppendPenPoint(CGPoint(x: 1, y: 1), after: nil))
    }

    func test_penAppend_dedup() {
        let last = CGPoint(x: 10, y: 10)
        XCTAssertFalse(AnnotationGeometry.shouldAppendPenPoint(CGPoint(x: 10.5, y: 10.5), after: last))
        XCTAssertTrue(AnnotationGeometry.shouldAppendPenPoint(CGPoint(x: 12, y: 10), after: last))
    }

    // MARK: 有效性

    func test_valid_arrowTooShort() {
        // 归一化 (0.5,0.5)→(0.52,0.5)：局部 4pt 宽、高 0 → 最长边 4pt，等于阈值判有效；再短无效
        XCTAssertFalse(AnnotationGeometry.isValid(.arrow(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.51, y: 0.5)), selectionSize: sel.size))
        XCTAssertTrue(AnnotationGeometry.isValid(.arrow(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.6, y: 0.5)), selectionSize: sel.size))
    }

    func test_valid_penNeedsTwoPoints() {
        XCTAssertFalse(AnnotationGeometry.isValid(.pen(points: [CGPoint(x: 0.5, y: 0.5)]), selectionSize: sel.size))
        XCTAssertTrue(AnnotationGeometry.isValid(.pen(points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.5)]), selectionSize: sel.size))
    }

    // MARK: path

    func test_path_rectBoundingBox() {
        let n = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let p = AnnotationGeometry.path(for: .rect(n), in: sel, lineWidth: 4)
        // rect 以中心线建 path，boundingBox 即归一化 × 选区（未做 inset——stroke 由渲染层处理）
        XCTAssertEqual(p.boundingBox, CGRect(x: 120, y: 70, width: 100, height: 30))
    }

    func test_path_ellipseBoundingBox() {
        let n = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let p = AnnotationGeometry.path(for: .ellipse(n), in: sel, lineWidth: 4)
        XCTAssertEqual(p.boundingBox, CGRect(x: 120, y: 70, width: 100, height: 30))
    }

    func test_path_arrowContainsHead() {
        let p = AnnotationGeometry.path(for: .arrow(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5)), in: sel, lineWidth: 4)
        // 头三角在 end 附近（局部 (300, 100)），boundingBox 应覆盖到端点附近
        XCTAssertGreaterThanOrEqual(p.boundingBox.maxX, 299)
        XCTAssertLessThanOrEqual(p.boundingBox.minX, 100)
    }

    func test_path_penPolyline() {
        let p = AnnotationGeometry.path(for: .pen(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]), in: sel, lineWidth: 4)
        XCTAssertEqual(p.boundingBox, CGRect(x: 100, y: 50, width: 200, height: 100))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter AnnotationTests`
Expected: FAIL——`cannot find 'RGBA'/'Annotation' in scope`

- [ ] **Step 3: 写实现 Sources/Kacha/Annotation.swift**

```swift
import CoreGraphics
import Foundation

/// 标注颜色（RGBA 分量，0-1）
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let red = RGBA(r: 1, g: 0.231, b: 0.188, a: 1)        // #FF3B30
    static let orange = RGBA(r: 1, g: 0.584, b: 0, a: 1)         // #FF9500
    static let yellow = RGBA(r: 1, g: 0.8, b: 0, a: 1)           // #FFCC00
    static let green = RGBA(r: 0.204, g: 0.78, b: 0.349, a: 1)   // #34C759
    static let blue = RGBA(r: 0, g: 0.478, b: 1, a: 1)           // #007AFF
    static let purple = RGBA(r: 0.686, g: 0.322, b: 0.871, a: 1) // #AF52DE
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

/// 标注工具；非 select 激活时接管选区内拖动为绘制
enum AnnotationTool: Equatable {
    case select, arrow, rect, ellipse, pen
    var takesOverDrag: Bool { self != .select }
}

/// 粗细三档（pt）
enum AnnotationWidth: CaseIterable {
    case thin, medium, thick
    var pt: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 8
        }
    }
    /// 工具栏示意圆点直径
    var dotDiameter: CGFloat {
        switch self {
        case .thin: 4
        case .medium: 6
        case .thick: 9
        }
    }
}

/// 一笔标注。几何为归一化坐标（0-1，相对选区）：选区移动/缩放时标注跟随；
/// lineWidth 为绝对 pt，不随选区缩放。
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow(start: CGPoint, end: CGPoint)  // 归一化
        case rect(CGRect)                         // 归一化
        case ellipse(CGRect)                      // 归一化
        case pen(points: [CGPoint])               // 归一化
    }

    let id: UUID
    var kind: Kind
    var color: RGBA
    var lineWidth: CGFloat

    init(kind: Kind, color: RGBA, lineWidth: CGFloat) {
        self.id = UUID()
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// 标注几何（纯逻辑，单测覆盖；预览与像素合成共用）
enum AnnotationGeometry {
    /// 局部 point → 归一化（clamp 到 [0,1]）
    static func normalizedPoint(_ p: CGPoint, in selection: CGRect) -> CGPoint {
        guard selection.width > 0, selection.height > 0 else { return .zero }
        let x = max(0, min((p.x - selection.minX) / selection.width, 1))
        let y = max(0, min((p.y - selection.minY) / selection.height, 1))
        return CGPoint(x: x, y: y)
    }

    /// 归一化 → 局部 point（按目标选区）
    static func localPoint(_ n: CGPoint, in selection: CGRect) -> CGPoint {
        CGPoint(x: selection.minX + n.x * selection.width,
                y: selection.minY + n.y * selection.height)
    }

    /// 箭头头长（pt）：max(3 × lineWidth, 10)；头半角 15°
    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(3 * lineWidth, 10)
    }

    /// pen 采样去重：与上一点距离 > 1pt 才记录（首点恒记录）
    static func shouldAppendPenPoint(_ p: CGPoint, after last: CGPoint?) -> Bool {
        guard let last else { return true }
        return hypot(p.x - last.x, p.y - last.y) > 1
    }

    /// 标注 CGPath（选区局部坐标）。箭头含线段与实心头三角两个子路径；
    /// rect/ellipse 以归一化矩形直接构建（stroke 中心线语义，由渲染层 stroke）。
    static func path(for kind: Annotation.Kind, in selection: CGRect, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case let .arrow(start, end):
            let s = localPoint(start, in: selection)
            let e = localPoint(end, in: selection)
            path.move(to: s)
            path.addLine(to: e)
            // 头三角：end 为顶点，方向沿 (e-s)，两翼张开 15°
            let dx = e.x - s.x, dy = e.y - s.y
            let len = hypot(dx, dy)
            let head = arrowHeadLength(lineWidth: lineWidth)
            if len > 1 {
                let ux = dx / len, uy = dy / len          // 单位方向
                let nx = -uy, ny = ux                      // 单位法向
                let tan15 = tan(.pi / 12)
                let base = CGPoint(x: e.x - ux * head, y: e.y - uy * head)
                let w1 = CGPoint(x: base.x + nx * head * tan15, y: base.y + ny * head * tan15)
                let w2 = CGPoint(x: base.x - nx * head * tan15, y: base.y - ny * head * tan15)
                path.move(to: e)
                path.addLine(to: w1)
                path.addLine(to: w2)
                path.closeSubpath()
            }
        case let .rect(n):
            path.addRect(CGRect(x: selection.minX + n.minX * selection.width,
                                y: selection.minY + n.minY * selection.height,
                                width: n.width * selection.width,
                                height: n.height * selection.height))
        case let .ellipse(n):
            path.addEllipse(in: CGRect(x: selection.minX + n.minX * selection.width,
                                       y: selection.minY + n.minY * selection.height,
                                       width: n.width * selection.width,
                                       height: n.height * selection.height))
        case let .pen(points):
            guard let first = points.first else { break }
            path.move(to: localPoint(first, in: selection))
            for p in points.dropFirst() {
                path.addLine(to: localPoint(p, in: selection))
            }
        }
        return path
    }

    /// 松开时有效性：太小的标注丢弃（arrow/rect/ellipse 局部最长边 < 4pt；pen < 2 点）
    static func isValid(_ kind: Annotation.Kind, selectionSize: CGSize) -> Bool {
        let minimum: CGFloat = 4
        switch kind {
        case let .arrow(start, end):
            let dx = (end.x - start.x) * selectionSize.width
            let dy = (end.y - start.y) * selectionSize.height
            return max(abs(dx), abs(dy)) >= minimum
        case let .rect(n):
            return max(n.width * selectionSize.width, n.height * selectionSize.height) >= minimum
        case let .ellipse(n):
            return max(n.width * selectionSize.width, n.height * selectionSize.height) >= minimum
        case let .pen(points):
            return points.count >= 2
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter AnnotationTests`
Expected: 12 个新测试全过；全量 42/42

- [ ] **Step 5: Commit**

```bash
git add Sources/Kacha/Annotation.swift Tests/KachaTests/AnnotationTests.swift
git commit -m "feat: Annotation 模型与归一化几何（TDD）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: AnnotationRenderer 像素合成（TDD）

**Files:**
- Create: `Sources/Kacha/AnnotationRenderer.swift`
- Test: `Tests/KachaTests/AnnotationRendererTests.swift`

**Interfaces:**
- Consumes: `Annotation`、`RGBA`、`AnnotationGeometry.path(for:in:lineWidth:)`（Task 1）
- Produces: `enum AnnotationRenderer { static func composite(_ image: CGImage, annotations: [Annotation], selectionPointWidth: CGFloat) -> CGImage }`（无有效标注返回原图引用）

- [ ] **Step 1: 写失败的测试**（像素级断言：合成后中点为标注色、角落仍为底色）

```swift
import XCTest
import CoreGraphics
@testable import kacha

final class AnnotationRendererTests: XCTestCase {
    /// 生成纯色 CGImage
    private func solidImage(_ rgba: RGBA, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        guard let data = image.dataProvider?.copyData() else { return (0, 0, 0) }
        let bytes = [UInt8](data)
        // CGImage 位图按左上原点存储，第 (x, y) 像素 = bytes[y * bytesPerRow + x * 4]（premultipliedLast: RGBA）
        let o = y * image.bytesPerRow + x * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    func test_composite_rectStrokeColorsCenter() {
        let base = solidImage(RGBA.white, width: 100, height: 100)
        // 归一化矩形 (0.1,0.45,0.8,0.1)：黑描边 lineWidth 4（point）；scale = 100/100 = 1
        let a = Annotation(kind: .rect(CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.1)),
                           color: .black, lineWidth: 4)
        let out = AnnotationRenderer.composite(base, annotations: [a], selectionPointWidth: 100)
        // 上下边中点应为黑（描边中心线 y=0.45*100=45、0.55*100=55）
        let top = pixel(out, 50, 45)
        let bottom = pixel(out, 50, 55)
        XCTAssertLessThan(Int(top.0) + Int(top.1) + Int(top.2), 60)
        XCTAssertLessThan(Int(bottom.0) + Int(bottom.1) + Int(bottom.2), 60)
        // 矩形内部（非描边）与画布角落仍为白
        let inner = pixel(out, 50, 50)
        XCTAssertGreaterThan(Int(inner.0) + Int(inner.1) + Int(inner.2), 700)
        let corner = pixel(out, 5, 5)
        XCTAssertGreaterThan(Int(corner.0) + Int(corner.1) + Int(corner.2), 700)
    }

    func test_composite_emptyReturnsSameImage() {
        let base = solidImage(RGBA.white, width: 50, height: 50)
        let out = AnnotationRenderer.composite(base, annotations: [], selectionPointWidth: 50)
        XCTAssertTrue(out === base)
    }
}
```

（`pixel` 中的 CGImage 像素存储按左上原点、行序自上而下；CGContext 绘制坐标为左下原点——Renderer 内部需做 Y 翻转，测试读取也按此约定。）

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter AnnotationRendererTests`
Expected: FAIL——`cannot find 'AnnotationRenderer' in scope`

- [ ] **Step 3: 写实现 Sources/Kacha/AnnotationRenderer.swift**

```swift
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
            ctx.addPath(path)
            ctx.setLineWidth(a.lineWidth)
            ctx.setStrokeColor(CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a))
            ctx.setFillColor(CGColor(red: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a))
            ctx.strokePath()
            // 箭头头三角为第二子路径，需要再 fill（strokePath 已消费 path，重建 fill 头部）
            if case .arrow = a.kind {
                // 重新构建仅头三角：path() 返回线+头两个子路径，stroke 后头三角已有描边；
                // 为实心头，再 fill 一次整个 path（线段 fill 无面积、无副作用）
                let p2 = AnnotationGeometry.path(for: a.kind, in: selection, lineWidth: a.lineWidth)
                ctx.addPath(p2)
                ctx.fillPath(using: .eoFill)  // 线子路径无面积，头三角被填充
            }
        }
        return ctx.makeImage() ?? image
    }
}
```

（若 eoFill 对「线 + 头」组合导致头三角出现空洞，改为仅构建头三角的独立路径 fill——实现时以测试像素断言为准修正。）

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter AnnotationRendererTests`
Expected: 2 个新测试过；全量 44/44

- [ ] **Step 5: Commit**

```bash
git add Sources/Kacha/AnnotationRenderer.swift Tests/KachaTests/AnnotationRendererTests.swift
git commit -m "feat: AnnotationRenderer 像素合成（TDD）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: 标注工具栏 UI 与状态

**Files:**
- Modify: `Sources/Kacha/SelectionView.swift`

**Interfaces:**
- Consumes: `RGBA.palette`、`AnnotationTool`、`AnnotationWidth`、`Annotation`（Task 1）；现有 ToolbarButton/toolbarRowLayout 模式
- Produces: `@State private var annotations: [Annotation] = []`、`@State private var activeTool: AnnotationTool = .select`、`@State private var annotationColor: RGBA = .red`、`@State private var annotationWidth: AnnotationWidth = .medium`、`@State private var drawingAnnotation: Annotation?`（本任务只建状态与 UI，Task 4 接手势）

**规格（精确值）：**
- 新增标注工具行（与现有输出行组成两行 VStack(spacing: 8)，整组沿用 toolbarRowLayout 的右缘锚定与贴底收内侧——布局函数扩展为两组行高）
- 5 个工具钮 24×24 玻璃圆钮（复用 ToolbarButton 风格），SF Symbols 依次：`move`（选择）、`arrow.up.right`（箭头）、`rectangle`（矩形）、`circle`（椭圆）、`scribble`（画笔）；当前工具 accent 描边高亮
- 分隔线 1×16 半透明
- 色板：8 个 14pt 圆（HStack spacing 6），白色与黑色圆加 1pt `Color(nsColor: .separator)` 描边；当前色外圈 2pt accent ring
- 粗细：3 个按钮（垂直居中的实心圆点，直径 = AnnotationWidth.dotDiameter），当前档 accent ring
- 撤销钮：SF `arrow.uturn.backward`，`annotations.isEmpty` 时 40% 透明度禁用；点击 `if !annotations.isEmpty { annotations.removeLast() }`
- 全部 hitTest 不进选区（选区外无操作保证）；光标 zone 扩展覆盖两组行
- 布局锚定：组右缘 = sel.maxX（与现有一致）；贴底收内侧判定用组总高（两行 ≈ 56pt：24 + 8 + 24）

**验证：** `swift build && swift test`（44/44）→ `make install`；GUI 冒烟由 Task 5 统一安排（本任务完成后 UI 可见但无绘制行为）

- [ ] **Commit:** `feat: 标注工具栏 UI 与状态`（步骤：实现 → build/test → make install → commit，同前任务模式）

---

### Task 4: 绘制交互与实时渲染

**Files:**
- Modify: `Sources/Kacha/SelectionView.swift`

**Interfaces:**
- Consumes: Task 3 的五个 @State；`AnnotationGeometry.normalizedPoint/shouldAppendPenPoint/isValid/path`（Task 1）
- Produces: 选区内绘制手势 + Canvas 实时渲染（屏幕预览与 AnnotationGeometry.path 同构）

**规格（精确行为）：**
- 当 `activeTool.takesOverDrag` 时，在现有「选区 move 层」之上渲染绘制层（后渲染覆盖命中，move/边/角手势让位；「选择」工具时绘制层不存在，恢复现状）：
```swift
Color.clear
    .frame(width: sel.width, height: sel.height)
    .position(x: sel.midX, y: sel.midY)
    .contentShape(Rectangle())
    .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("sel"))
            .onChanged { value in updateDrawing(to: value.location, start: value.startLocation) }
            .onEnded { _ in commitDrawing() }
    )
```
- `updateDrawing(to:start:)`（局部 point → 归一化，clamp 由 normalizedPoint 承担）：
  - arrow：start/start end/to
  - rect/ellipse：CGRect(start, to) 归一化（x/y/w/h 由两点 min/max）
  - pen：`shouldAppendPenPoint` 则 append（points 归一化数组，初始含首点）
- `commitDrawing()`：`AnnotationGeometry.isValid(kind, selectionSize: sel.size)` 为真才 append 到 annotations；`drawingAnnotation = nil`
- 渲染层（ZStack 内、白边之后、move/绘制手势层之前）：一个 `Canvas` frame=sel 尺寸 position=sel 中心，遍历 `annotations + [drawingAnnotation].compactMap { $0 }`：
```swift
let path = Path(AnnotationGeometry.path(for: a.kind, in: sel, lineWidth: a.lineWidth))
let color = Color(red: a.color.r, green: a.color.g, blue: a.color.b, opacity: a.color.a)
// pen/rect/ellipse：context.stroke(path, with: .color(color), lineWidth: a.lineWidth)
// arrow：stroke 线 + fill 头——path 整体 stroke 一次 + fill(eoFill) 一次（与 Renderer 同构）
// 白色标注额外 stroke 1pt separator 描边（仅预览层，规格约束）
```
- 标注工具激活时双击确认失效可接受（绘制层覆盖）——回车/按钮/右键仍可用（规格已注明）

**验证：** `swift build && swift test`（44/44）→ `make install`；冒烟由 Task 5 统一安排

- [ ] **Commit:** `feat: 标注绘制交互与实时渲染`

---

### Task 5: 全链路合成与冒烟

**Files:**
- Modify: `Sources/Kacha/SelectionView.swift`（confirm/save 传出 annotations）
- Modify: `Sources/Kacha/OverlayController.swift`（handleConfirm 增参并接 Renderer）

**Interfaces:**
- Consumes: `AnnotationRenderer.composite(_:annotations:selectionPointWidth:)`（Task 2）、现有 handleConfirm 裁剪→圆角链路
- Produces: `SelectionView` 的 `onConfirm`/`onSave` 签名 `(CGRect, CGFloat, [Annotation]) -> Void`；handleConfirm 内裁剪后先 `AnnotationRenderer.composite(cropped, annotations: ann, selectionPointWidth: pointRect.width)` 再圆角化

**规格：**
- `confirm()`/`save()` 调 `onConfirm(selection, CGFloat(cornerRadius), annotations)` / `onSave(...)`（守卫不变）
- OverlayController：SelectionView 初始化两闭包同步增参；handleConfirm 增 `annotations: [Annotation]` 形参，链路：`cropped → composite（pointRect.width 为 point 宽）→ 圆角化 → onCapture`
- `swift build && swift test`（44/44）→ `make install`
- 冒烟清单（用户 GUI）：四工具绘制手感；8 色/3 粗细即时生效；撤销逐笔；选区移动/缩放标注跟随；输出放大核对颜色/线宽/箭头头；标注+圆角并存（先标注后调圆角，输出两者都有）；选择工具恢复平移缩放；回车/按钮/右键/ESC 无回归；绘制层不响应选区外

- [ ] **Commit:** `feat: 标注合成输出全链路`
