# Kacha V2 窗口识别 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 截图时鼠标悬停自动高亮窗口，点击即以窗口矩形为选区进入 V1 调整态（复用全部后续流程）

**Architecture:** 热键触发时与抓帧同刻枚举 `SCShareableContent.windows`，过滤普通窗口后经纯逻辑模块 `WindowGeometry` 预转换为每屏局部坐标；SelectionView 用 `.onContinuousHover` 做命中检测（idle 态蓝边高亮 + 遮罩挖洞），onEnded 增加窗口分支。截图内容 = 冻结帧裁剪（复用 V1 链路），无新抓取路径。

**Tech Stack:** Swift 6 / SwiftUI / ScreenCaptureKit（已验证 `SCWindow.windowLayer/frame/windowID/owningApplication?.processID` 在本 SDK 均可用）

**Spec:** `docs/superpowers/specs/2026-09-16-kacha-v2-window-detection-design.md`

## Global Constraints

- 零第三方依赖；用户可见文案简体中文
- 窗口过滤：`windowLayer == 0`、`owningApplication != nil` 且 `processID != 本 app`、`frame.width > 0 && frame.height > 0`
- 命中语义：`SCShareableContent.windows` 数组顺序即前后序（front-to-back），**首个 contains 命中 = 最上层**
- 高亮：系统蓝（`Color(nsColor: .controlAccentColor)`）2pt 描边，仅 idle 态显示
- 坐标换算集中 `WindowGeometry`：CG 全局左上原点 ↔ 屏幕局部，公式 `屏幕 CG 原点 = (frame.minX, totalHeight - frame.maxY)`，`totalHeight = max(所有屏 frame.maxY)`
- 提交信息：中文 + Conventional Commits 前缀，末尾 `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- 既有 18 个测试不得回归；`swift test` / `swift build -c release` / `make app` 为验证命令

---

### Task 1: WindowGeometry 纯逻辑模块（TDD）

**Files:**
- Create: `Sources/Kacha/WindowGeometry.swift`
- Test: `Tests/KachaTests/WindowGeometryTests.swift`

**Interfaces:**
- Consumes: 无（纯 Foundation/CoreGraphics）
- Produces:
  - `WindowGeometry.screenOriginGlobalCG(frame: CGRect, totalHeight: CGFloat) -> CGPoint`
  - `WindowGeometry.localRect(window: CGRect, screenFrame: CGRect, totalHeight: CGFloat) -> CGRect`
  - `WindowGeometry.hitTest(point: CGPoint, windows: [CGRect]) -> CGRect?`
  - `WindowGeometry.clampedToScreen(_ rect: CGRect, screenBounds: CGRect) -> CGRect?`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import kacha

final class WindowGeometryTests: XCTestCase {
    // MARK: screenOriginGlobalCG

    func test_origin_mainScreenAtZero() {
        // 主屏 frame (0,0,1512,982)（AppKit 左下原点），总高 982 → CG 原点 (0, 0)
        let p = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), totalHeight: 982)
        XCTAssertEqual(p, CGPoint(x: 0, y: 0))
    }

    func test_origin_screenAboveMain() {
        // 主屏 (0,0,1512,982)、上排副屏 (0,982,1000,800)：总高 1782
        // 主屏 CG origin y = 1782 - 982 = 800；副屏 CG origin y = 1782 - 1782 = 0
        let main = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), totalHeight: 1782)
        XCTAssertEqual(main, CGPoint(x: 0, y: 800))
        let top = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 0, y: 982, width: 1000, height: 800), totalHeight: 1782)
        XCTAssertEqual(top, CGPoint(x: 0, y: 0))
    }

    func test_origin_sideScreenNonZeroX() {
        // 右侧副屏 (1512,0,1920,1080)，总高 1080 → CG 原点 (1512, 0)
        let p = WindowGeometry.screenOriginGlobalCG(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), totalHeight: 1080)
        XCTAssertEqual(p, CGPoint(x: 1512, y: 0))
    }

    // MARK: localRect

    func test_localRect_mainScreen() {
        let r = WindowGeometry.localRect(
            window: CGRect(x: 100, y: 200, width: 300, height: 400),
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            totalHeight: 982
        )
        XCTAssertEqual(r, CGRect(x: 100, y: 200, width: 300, height: 400))
    }

    func test_localRect_offsetScreen() {
        // 窗口 CG 全局 (1600, 300)，副屏 CG 原点 (1512, 0) → 局部 (88, 300)
        let r = WindowGeometry.localRect(
            window: CGRect(x: 1600, y: 300, width: 500, height: 400),
            screenFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            totalHeight: 1080
        )
        XCTAssertEqual(r, CGRect(x: 88, y: 300, width: 500, height: 400))
    }

    // MARK: hitTest

    func test_hitTest_firstWinsOnOverlap() {
        // 数组顺序 = front-to-back；重叠点命中首个
        let w1 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let w2 = CGRect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(WindowGeometry.hitTest(point: CGPoint(x: 60, y: 60), windows: [w1, w2]), w1)
    }

    func test_hitTest_fallsThroughToSecond() {
        let w1 = CGRect(x: 0, y: 0, width: 100, height: 100)
        let w2 = CGRect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(WindowGeometry.hitTest(point: CGPoint(x: 140, y: 140), windows: [w1, w2]), w2)
    }

    func test_hitTest_missReturnsNil() {
        XCTAssertNil(WindowGeometry.hitTest(point: CGPoint(x: 500, y: 500), windows: [CGRect(x: 0, y: 0, width: 100, height: 100)]))
    }

    func test_hitTest_emptyListReturnsNil() {
        XCTAssertNil(WindowGeometry.hitTest(point: CGPoint(x: 1, y: 1), windows: []))
    }

    // MARK: clampedToScreen

    func test_clamp_crossScreenIntersects() {
        // 窗口跨屏：屏 (0,0,1512,982)，窗口 CG (1400,0,300,982) → 交集 (1400,0,112,982)
        let r = WindowGeometry.clampedToScreen(CGRect(x: 1400, y: 0, width: 300, height: 982), screenBounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(r, CGRect(x: 1400, y: 0, width: 112, height: 982))
    }

    func test_clamp_disjointReturnsNil() {
        XCTAssertNil(WindowGeometry.clampedToScreen(CGRect(x: 2000, y: 0, width: 100, height: 100), screenBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)))
    }

    func test_clamp_insideUnchanged() {
        let r = WindowGeometry.clampedToScreen(CGRect(x: 10, y: 10, width: 100, height: 100), screenBounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(r, CGRect(x: 10, y: 10, width: 100, height: 100))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter WindowGeometryTests`
Expected: FAIL——`cannot find 'WindowGeometry' in scope`

- [ ] **Step 3: 写最小实现 Sources/Kacha/WindowGeometry.swift**

```swift
import CoreGraphics
import Foundation

/// CGWindow 全局坐标（左上原点）与屏幕局部坐标换算、悬停命中（纯逻辑，不依赖 AppKit）
enum WindowGeometry {
    /// 屏幕 CG 全局原点：AppKit frame（左下原点）→ CG 全局（左上原点）
    /// 公式：x = frame.minX，y = totalHeight - frame.maxY（totalHeight = 所有屏 frame.maxY 的最大值）
    static func screenOriginGlobalCG(frame: CGRect, totalHeight: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX, y: totalHeight - frame.maxY)
    }

    /// 窗口 CG 全局矩形 → 本屏局部矩形（左上原点）
    static func localRect(window: CGRect, screenFrame: CGRect, totalHeight: CGFloat) -> CGRect {
        let origin = screenOriginGlobalCG(frame: screenFrame, totalHeight: totalHeight)
        return window.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// Z 序命中：windows 为 front-to-back 顺序的局部坐标矩形，返回首个包含 point 的（= 最上层）
    static func hitTest(point: CGPoint, windows: [CGRect]) -> CGRect? {
        windows.first { $0.contains(point) }
    }

    /// 与屏幕求交集；不相交返回 nil
    static func clampedToScreen(_ rect: CGRect, screenBounds: CGRect) -> CGRect? {
        rect.intersection(screenBounds).isNull ? nil : rect.intersection(screenBounds)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter WindowGeometryTests`
Expected: 全部 PASS（12 个测试），全量 `swift test` 30/30

- [ ] **Step 5: Commit**

```bash
git add Sources/Kacha/WindowGeometry.swift Tests/KachaTests/WindowGeometryTests.swift
git commit -m "feat: WindowGeometry 窗口坐标换算与命中检测（TDD）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: 窗口枚举与数据链路（CaptureSession + 透传）

**Files:**
- Modify: `Sources/Kacha/ScreenCaptureService.swift`
- Modify: `Sources/Kacha/OverlayController.swift`
- Modify: `Sources/Kacha/CaptureCoordinator.swift`

**Interfaces:**
- Consumes: `WindowGeometry.localRect/clampedToScreen`（Task 1）
- Produces:
  - `struct CaptureSession { let frames: [ScreenFrame]; let windowsByScreen: [CGDirectDisplayID: [CGRect]] }`（ScreenCaptureService.swift 内；windowsByScreen 值为本屏局部坐标、front-to-back 顺序）
  - `ScreenCaptureService.captureSession() async throws -> CaptureSession`（**取代** `captureAllDisplays()`，调用方同步更新）
  - `OverlayController.show(frames:windowsByScreen:onCapture:onCancel:)`（签名新增 `windowsByScreen: [CGDirectDisplayID: [CGRect]]`）
  - `SelectionView` 初始化新增 `windows: [CGRect]` 参数（本屏局部坐标；Task 3 在 SelectionView 内接好）

- [ ] **Step 1: ScreenCaptureService 改造**

在 `ScreenFrame` 定义之后新增：

```swift
/// 一次截图会话的完整数据：各屏冻结帧 + 各屏窗口矩形（本屏局部坐标、front-to-back）
struct CaptureSession {
    let frames: [ScreenFrame]
    let windowsByScreen: [CGDirectDisplayID: [CGRect]]
}
```

`captureAllDisplays()` 整体重命名为 `captureSession()` 并在末尾返回 `CaptureSession`（原有逐屏抓帧逻辑不动），新增窗口枚举（在抓帧循环之后、return 之前）：

```swift
// 窗口枚举（与冻结帧同刻）：普通窗口、有主 app、非本 app、frame 有效
let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
let myPID = ProcessInfo.processInfo.processIdentifier
var windowsByScreen: [CGDirectDisplayID: [CGRect]] = [:]
for window in content.windows {
    guard window.windowLayer == 0,
          let owner = window.owningApplication,
          owner.processID != myPID,
          window.frame.width > 0, window.frame.height > 0
    else { continue }
    for screen in NSScreen.screens {
        let local = WindowGeometry.localRect(window: window.frame, screenFrame: screen.frame, totalHeight: totalHeight)
        let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
        if let clamped = WindowGeometry.clampedToScreen(local, screenBounds: screenBounds) {
            windowsByScreen[screen.displayID, default: []].append(clamped)
        }
    }
}
return CaptureSession(frames: frames, windowsByScreen: windowsByScreen)
```

（`screen.displayID` 为现有 deviceDescription 提取逻辑的封装/局部变量，沿用当前文件内写法。）

- [ ] **Step 2: OverlayController.show 签名透传**

`func show(frames: [ScreenFrame], windowsByScreen: [CGDirectDisplayID: [CGRect]], onCapture: @escaping (CGImage, CaptureAction) -> Void, onCancel: @escaping () -> Void)`（onCapture/onCancel 参数体与现有完全一致，仅新增 windowsByScreen 形参）——循环内创建 SelectionView 时传入本屏窗口数组：

```swift
let displayID = frame.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
let view = SelectionView(frame: frame, windows: windowsByScreen[displayID] ?? []) { /* 现有 onConfirm 闭包原样 */ } onCancel: { /* 现有闭包原样 */ }
```

（若现有代码以 trailing closure 传 onConfirm、具名传 onSave/onCancel，保持其形态，只插入 `windows:` 参数；其余逻辑不动。）

- [ ] **Step 3: CaptureCoordinator 调用更新**

`let frames = try await captureService.captureAllDisplays()` 改为：

```swift
let session = try await captureService.captureSession()
overlay.show(frames: session.frames, windowsByScreen: session.windowsByScreen, onCapture: { image, action in ... 原有 }, onCancel: {})
```

- [ ] **Step 4: 验证**

Run: `swift build && swift test`
Expected: 构建成功（本任务 SelectionView 的 `windows` 参数尚为未消费的新属性，SwiftUI memberwise init 自动包含）；30/30 测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/Kacha/ScreenCaptureService.swift Sources/Kacha/OverlayController.swift Sources/Kacha/CaptureCoordinator.swift
git commit -m "feat: 截图会话枚举窗口并按屏预转换坐标

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: SelectionView 悬停高亮与点击窗口分支

**Files:**
- Modify: `Sources/Kacha/SelectionView.swift`

**Interfaces:**
- Consumes: `SelectionView` 现有 `windows: [CGRect]` 属性（Task 2 已接线）；`WindowGeometry.hitTest`（Task 1）
- Produces: 无新接口（行为完成）

- [ ] **Step 1: 悬停状态与命中检测**

新增 `@State private var hoveredWindow: CGRect? = nil`；在根 `.coordinateSpace(name: "sel")` 之后加：

```swift
.onContinuousHover(coordinateSpace: .named("sel")) { hoverPhase in
    switch hoverPhase {
    case .active(let point):
        hoveredWindow = (phase == .idle) ? WindowGeometry.hitTest(point: point, windows: windows) : nil
    case .ended:
        hoveredWindow = nil
    }
}
```

- [ ] **Step 2: 高亮渲染（仅 idle 态）**

遮罩的选区参数改为（替换现有 `DimmingMask(selection: ...)` 处的实参）：

```swift
let maskSelection = activeSelection ?? ((phase == .idle) ? hoveredWindow : nil)
DimmingMask(selection: maskSelection)
    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
    .allowsHitTesting(false)
```

在遮罩之后、现有白边渲染之前加蓝描边（与白边同层结构）：

```swift
if phase == .idle, let hw = hoveredWindow {
    Rectangle()
        .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
        .frame(width: hw.width, height: hw.height)
        .position(x: hw.midX, y: hw.midY)
        .allowsHitTesting(false)
}
```

- [ ] **Step 3: onEnded 窗口分支**

父层手势 onEnded 中，在现有「rect 有效 → 框选」之后、「`else if phase != .adjusting` → onCancel」之前插入：

```swift
else if let hw = hoveredWindow, phase != .adjusting {
    // 点击窗口：以窗口矩形为选区进入调整态（dragStart/dragCurrent 由 defer 清空，
    // 满足 confirm 的 dragStart == nil 守卫）
    selection = hw
    phase = .adjusting
}
```

（注意：按下未动时 onChanged 已把 phase 设为 .dragging——窗口分支条件用 `phase != .adjusting` 而非 `.idle`。hoveredWindow 在 .dragging 期间保持旧值不更新，可读。）

- [ ] **Step 4: 光标一致性**

`applyCursor` 的「无选区 → crosshair」分支保持不变（悬停窗口时仍是十字，与系统 ⌘⇧4 一致）；无需改动。

- [ ] **Step 5: 验证与冒烟准备**

Run: `swift build && swift test && make app`
Expected: 构建零警告；30/30 测试通过；打包成功

- [ ] **Step 6: 用户 GUI 冒烟（由控制器安排）**

清单：悬停出现蓝色高亮+遮罩挖洞；点击窗口进调整态且选区=窗口矩形；点击空白取消；拖拽框选不受影响；多窗口重叠悬停取最上；菜单栏/Dock/桌面无高亮；点击后按钮组/整边缩放/平移/双击/回车/ESC 正常。

- [ ] **Step 7: Commit**

```bash
git add Sources/Kacha/SelectionView.swift
git commit -m "feat: 悬停高亮窗口，点击进入调整态

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: 截图圆角（底部原生滑动条实时调整）（2026-09-16 用户迭代需求）

**Files:**
- Modify: `Sources/Kacha/SelectionView.swift`
- Modify: `Sources/Kacha/OverlayController.swift`

**Interfaces:**
- Consumes: Task 3 的调整态结构（phase/selection/按钮组/confirm/save）、handleConfirm 裁剪链路
- Produces:
  - `SelectionView` 的 `onConfirm`/`onSave` 签名变为 `(CGRect, CGFloat) -> Void`（第二参数 = 圆角半径 point）
  - `OverlayController.handleConfirm(frame:pointRect:cornerRadius:action:)` 内部裁剪后按需圆角化
  - `OverlayController` 私有 `roundedCornerImage(_ image: CGImage, pixelRadius: CGFloat) -> CGImage`（alpha 圆角化）

**规格：**
- 调整态屏幕底部中央显示液态玻璃容器（Capsule）：「圆角」标签 + 原生 `Slider(value: 0...40, step: 1)`（宽 160）+ 当前数值（等宽数字）；每次截图会话重置为 0
- 实时预览：选区白边 `Rectangle` → `RoundedRectangle(cornerRadius: r)`（strokeBorder 不变）
- 输出（复制/保存统一）：r > 0 时裁剪图经 CGContext 圆角化（`CGPath(roundedRect:)` clip + premultiplied alpha），pixelRadius = point 半径 × (imagePixelSize / screenPointSize)；r == 0 跳过（零成本直通）
- 滑动条命中区不与选区手势冲突（选区外无操作已保证）；光标 pointer
- 提交信息：`feat: 截图圆角，底部滑动条实时调整`，末尾 Co-Authored-By: Claude Code <noreply@anthropic.com>

**实现要点：**

SelectionView：
```swift
@State private var cornerRadius: Double = 0
// 调整态渲染（按钮组之后）：
HStack(spacing: 12) {
    Text("圆角").font(.system(size: 12, weight: .medium))
    Slider(value: $cornerRadius, in: 0...40, step: 1).frame(width: 160)
    Text("\(Int(cornerRadius))").font(.system(size: 12, weight: .medium).monospacedDigit()).frame(width: 24)
}
.padding(.horizontal, 14).padding(.vertical, 8)
.glassEffect(in: Capsule())
.position(x: geo.size.width / 2, y: geo.size.height - 36)
// confirm()/save() 调用改为 onConfirm(selection, CGFloat(cornerRadius)) / onSave(selection, CGFloat(cornerRadius))
// 白边：Rectangle().strokeBorder(.white, lineWidth: 1) 改 RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white, lineWidth: 1)（frame/position 不变）
```

OverlayController：
```swift
// handleConfirm 增参 cornerRadius: CGFloat；裁剪后：
let output: CGImage
if cornerRadius > 0 {
    let scale = frame.imagePixelSize.width / frame.screenPointSize.width
    output = roundedCornerImage(cropped, pixelRadius: cornerRadius * scale)
} else {
    output = cropped
}
onCapture(output, action)

/// alpha 圆角化（premultiplied）；失败时退回原图
private func roundedCornerImage(_ image: CGImage, pixelRadius: CGFloat) -> CGImage {
    let w = image.width, h = image.height
    guard w > 0, h > 0, pixelRadius > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let _ = (ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                                      cornerWidth: pixelRadius, cornerHeight: pixelRadius, transform: nil)),
                   ctx.clip(), ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)), Optional(()))
    else { return image }
    return ctx.makeImage() ?? image
}
```
（SelectionView 两个闭包初始化处同步传 radius；SelectionView 白边在 dragging 态也用 cornerRadius？dragging 时 cornerRadius 恒 0，等价直角 ✓ 共用一处代码即可。）

- [ ] Step 1: 实现两个文件改动（SelectionView UI+状态+签名；OverlayController 签名+圆角化）
- [ ] Step 2: `swift build && swift test`（30/30 仍过）→ `make app`
- [ ] Step 3: 用户 GUI 冒烟（滑动条显示/拖动流畅/白边预览/输出圆角 PNG 透明角/复制保存都圆角/滑条不干扰手势）
- [ ] Step 4: Commit（信息见上）

---

### Task 6: 抓帧引擎换 screencapture CLI（保留窗口阴影）（2026-09-16 用户迭代需求）

**Files:**
- Modify: `Sources/Kacha/ScreenCaptureService.swift`

**Interfaces:**
- Consumes: `CaptureSession` 结构、窗口枚举（不变）、NSScreen.displayID
- Produces: `captureSession()` 签名不变；内部抓帧从 SCScreenshotManager 换为 `/usr/sbin/screencapture -x -D <displayID> -t png <tmp>` → CGImage

**规格：**
- 逐屏：`screencapture -x -D <displayID> -t png <临时文件>`（-x 静音；-D 接 CGDirectDisplayID；默认物理像素分辨率、不含鼠标指针）→ `CGImage(pngDataProviderSource:)` 读入 → 删除临时文件
- 进程等待放后台（`Task.detached` 或 async let），不卡 MainActor
- 失败（非零退出/读图失败）→ `CaptureError.captureFailed`
- 窗口枚举（SCShareableContent）与全部下游链路（坐标/裁剪/圆角/复制/保存）不动
- 提交信息：`feat: 抓帧引擎换 screencapture，保留窗口阴影`，末尾 Co-Authored-By: Claude Code <noreply@anthropic.com>

- [ ] Step 1: 实现（保留 SCScreenshotManager 旧路径代码可删除，git 可 revert）
- [ ] Step 2: `swift build && swift test`（30/30）→ `make install`
- [ ] Step 3: 用户冒烟（冻结画面有阴影/延迟可接受/裁剪圆角复制保存无回归/分辨率清晰度不降）
- [ ] Step 4: Commit
