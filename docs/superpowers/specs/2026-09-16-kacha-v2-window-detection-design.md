# 咔嚓 Kacha — V2 窗口识别设计

日期：2026-09-16
状态：已与作者确认
前置：V1（`docs/superpowers/specs/2026-09-15-kacha-mvp-design.md`）

## 1. 概述

在 V1 两段式框选之上增加窗口识别：悬停自动高亮窗口，点击即以该窗口矩形为选区进入调整态，后续流程（缩放/平移/按钮组/确认/取消）完全复用 V1。截图内容为冻结帧裁剪窗口矩形（含背景，不做纯窗口图层抓取）。

## 2. 交互模型

```
idle（无选区）
├─ 悬停窗口 → 系统蓝（controlAccentColor）2pt 描边高亮 + 全屏遮罩挖窗口洞
├─ 点击窗口 → selection = 窗口矩形（clamp 本屏）→ phase = .adjusting（现有调整态）
├─ 按下并拖动 → 自由框选（现有；高亮消失）
└─ 点击空白（无窗口命中）→ 取消（现有）
```

- 高亮仅 idle 态显示；进入 dragging/adjusting 即消失
- 悬停命中多窗口重叠时取 Z 序最上（`SCShareableContent.windows` 数组顺序即前后序，首个命中）

## 3. 模块与数据流

| 模块 | 职责 |
|---|---|
| `WindowGeometry`（新，纯逻辑） | CGWindow 全局坐标（左上原点）↔ NSScreen 局部坐标（左下原点翻转）；Z 序命中（输入局部坐标窗口数组，返回命中矩形）；窗口矩形 clamp 到屏幕。不依赖 AppKit 可单测（NSScreen 坐标以参数传入） |
| `ScreenCaptureService` | 枚举屏幕时一并取 `SCShareableContent.windows`；过滤：`windowLayer == 0`（普通窗口，排除菜单栏/Dock/桌面壁纸）、onScreen、frame 宽高 > 0、`owningApplication?.processID != 本 app`；经 WindowGeometry 按屏预转换为**本屏局部坐标**的 `[CGRect]`（保持 Z 序），随会话返回 |
| `SelectionView` | 新增 `windows: [CGRect]`（本屏局部坐标、Z 序）与 `hoveredWindow: CGRect?` @State；`.onContinuousHover(coordinateSpace: .named("sel"))` 流式命中检测；idle 渲染高亮（蓝边 + DimmingMask 挖洞复用）；`onEnded` 窗口分支 |
| `OverlayController` / `CaptureCoordinator` | 数据透传（show 签名加 windows 参数），无逻辑变化 |

数据流：`captureAllDisplays()` → `CaptureSession { frames: [ScreenFrame], windowsByScreen: [CGDirectDisplayID: [CGRect]] }` → OverlayController 按屏取本屏数组注入 SelectionView → 悬停命中（View 内）→ 点击 → selection = clamp(窗口矩形) → 现有调整态链路（裁剪/复制/保存不变）。

## 4. 关键技术点

- **坐标系换算**：CGWindow frame 为全局左上原点（CG 显示坐标）；NSScreen.frame 为全局左下原点（AppKit 坐标）。屏幕的 CG 原点 = `(screen.frame.minX, totalHeight - screen.frame.maxY)`，其中 `totalHeight = max(所有 NSScreen.frame.maxY)`。局部坐标 = 窗口 CG 全局坐标 − 屏幕 CG 原点。公式集中在 WindowGeometry，单测覆盖单屏/多屏横排/竖排。
- **悬停检测**：SwiftUI `.onContinuousHover`（macOS 14+），不动现有 NSEvent 光标 monitor 管道（applyCursor 保持不变——悬停窗口时光标仍为十字）。
- **点击路径**：复用父层 DragGesture(minimumDistance: 0) 的 onEnded——拖拽矩形有效 → 框选（现有）；无效但 `hoveredWindow` 命中且 phase == idle → 窗口分支（注意：此时 dragStart 已被 onChanged 写入，进入调整态后需清空，confirm 的 dragStart == nil 守卫才能通过）。
- **数据时效**：窗口列表在热键触发时枚举一次（与冻结帧同刻），悬停期间不刷新——窗口移动不跟踪（MVP 取舍）。

## 5. 测试策略

- **单元测试（TDD）**：`WindowGeometryTests`——坐标换算（单屏原点、多屏左右/上下排列、非零原点副屏）、Z 序命中（重叠取首个、边界 contains 语义）、clamp（窗口跨屏裁到本屏、越界修正）
- **手动冒烟**：悬停高亮出现/消失；点击进调整态且选区=窗口；点击空白取消；拖拽框选不受影响；多窗口遮挡取最上；菜单栏/Dock/桌面不触发；点击后按钮组/缩放/平移正常；ESC

## 6. 不做（YAGNI）

- 纯窗口图层抓取（desktopIndependentWindow）——用户已选屏幕区域裁剪
- 窗口移动实时跟踪、Tab 组聚合、跨屏窗口合并、标注（V3）、钉图（V4）
