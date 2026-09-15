# 咔嚓 Kacha — V1 MVP 设计

日期：2026-09-15
状态：已与作者确认

## 1. 产品概述

Kacha（咔嚓）是一个 macOS 截图工具。按下全局热键后屏幕冻结，鼠标直接操作：拖拽框选区域，松开即截图进剪贴板。UI 采用 macOS 26+ 系统组件风格（Liquid Glass 由 SwiftUI 原生提供，非仿制）。

### 路线图

| 阶段 | 内容 |
|---|---|
| **V1（本设计）** | 热键 → 冻结全屏 → 拖拽框选 → PNG 进剪贴板 |
| V2 | 鼠标悬停自动识别窗口，点击即截窗口 |
| V3 | 标注工具（箭头 / 画笔） |
| V4 | 钉图（置顶浮动缩略窗） |

## 2. V1 架构

```
热键 ⌃⌘A → 权限检查 → 逐屏抓帧(ScreenCaptureKit)
        → 每屏盖一个无边框覆盖窗(冻结帧+遮罩)
        → 拖拽框选 → 松开 → 按像素裁剪 → NSPasteboard → 关窗
```

### 模块职责

| 模块 | 职责 |
|---|---|
| `KachaApp` | SwiftUI 入口；`MenuBarExtra` 菜单栏（截屏 / 退出）；`LSUIElement` 无 Dock 图标 |
| `HotKeyCenter` | Carbon `RegisterEventHotKey` 全局热键 ⌃⌘A（系统 API，零第三方依赖）；自定义改键留待后续版本 |
| `ScreenCaptureService` | `SCShareableContent` 枚举屏幕；`SCScreenshotManager` 逐屏抓一帧（一次性抓帧，不起持续推流） |
| `OverlayController` | 为每个 `NSScreen` 创建覆盖窗口（`NSPanel`，`.screenSaver` 级别、`canJoinAllSpaces + fullScreenAuxiliary`），窗口不透明承载冻结帧，其上由 SwiftUI 叠加半透明遮罩 |
| `SelectionView` | 冻结帧 + 35% 黑遮罩挖洞 + 选区白边 + 毛玻璃尺寸标签胶囊；十字光标 |
| `SelectionGeometry` | 纯逻辑坐标换算：NSScreen 左下原点 ↔ CGImage 像素、point ↔ pixel、任意方向拖拽归一化、最小选区阈值 |
| `ClipboardService` | 写 PNG + TIFF 到 `NSPasteboard` |
| `CaptureCoordinator` | 串联全流程；含权限引导弹窗（NSAlert + 直达系统设置）与错误提示 |

### 数据流

1. 用户按 ⌃⌘A，`HotKeyCenter` 回调收敛到 `@MainActor`
2. `ScreenCaptureService` 检查屏幕录制权限（`SCShareableContent.current`），无权限 → `PermissionGuide` 引导弹窗
3. 有权限 → 逐屏 `SCScreenshotManager.captureImage` 抓帧（异步并行）
4. `OverlayController` 为每屏创建 `NSPanel`，显示冻结帧与遮罩，置十字光标
5. 用户在任一屏拖拽；`SelectionView` 实时显示选区边框与尺寸标签
6. 松开鼠标：`SelectionGeometry` 把选区（point，AppKit 坐标）换算为该屏帧图像素矩形，裁剪
7. `ClipboardService` 写入剪贴板；关闭全部覆盖窗；播放轻反馈音
8. ESC 或无效松开（选区任一边 < 4pt）→ 取消，关窗

## 3. 交互细节

- 触发热键：**⌃⌘A**（Ctrl+Command+A）
- 按键后屏幕瞬间冻结；多屏时每屏都有覆盖窗，在哪块屏拖拽就截哪块
- 两段式框选（2026-09-15 用户迭代需求，取代初版「松开即截」）：
  1. 拖拽画出选区（实时白边 + 尺寸胶囊）；松开（选区 ≥ 4pt）进入**调整态**
  2. 调整态：8 个手柄（四角+四边中点）拖动缩放；选区内拖动整体平移；选区外点击拖拽可重画选区；调整中保持最小 4pt
  3. 确认：双击选区内 或 回车 → 截图入剪贴板；ESC 随时取消整个流程
- 选区有效阈值：任一边 < 4pt 视为误触（非调整态下取消）
- 成功反馈：系统截图声级别的轻提示，不做通知横幅
- 失败路径：
  - 权限被拒：菜单栏弹出引导窗，按钮直达系统设置的屏幕录制面板
  - ScreenCaptureKit 报错：alert 显示 SCError 错误码

## 4. 技术风险与对策

| 风险 | 对策 |
|---|---|
| Retina / 混合 DPI 多屏 | 不假设统一 scale；逐屏用 `backingScaleFactor` 换算；跨屏用 NSScreen 全局坐标 |
| AppKit（左下原点）与 CGImage（左上原点像素）坐标系不一致 | 集中在 `SelectionGeometry`，单元测试全覆盖 |
| Swift 6 严格并发 | Carbon 回调与 ScreenCaptureKit 异步结果统一收敛 `@MainActor` |
| 权限体验 | 首次触发热键时才请求 TCC 屏幕录制权限，而非启动即请求 |

## 5. 工程结构

SPM + 打包脚本（命令行全自动，无第三方构建工具）。

```
kacha/
  Package.swift              # executable target Kacha；test target KachaTests
  Sources/Kacha/
    KachaApp.swift           # 入口 + MenuBarExtra
    HotKeyCenter.swift
    ScreenCaptureService.swift
    OverlayController.swift
    SelectionView.swift
    SelectionGeometry.swift  # 纯逻辑，可测试
    ClipboardService.swift
    CaptureCoordinator.swift
  Tests/KachaTests/
    SelectionGeometryTests.swift
  Makefile                   # swift build → 打包 kacha.app
  support/Info.plist         # LSUIElement = true 等
  docs/superpowers/specs/    # 本文档
```

- 不沙盒、无 entitlements（屏幕录制是运行时 TCC 权限，非签名要求）
- ad-hoc 签名本机运行
- deployment target：macOS 26.0

## 6. 测试策略

- **单元测试（TDD）**：`SelectionGeometry` 全覆盖——point↔pixel 换算、坐标系翻转、任意方向拖拽归一化、最小阈值判定；组合多屏原点偏移与 2x/3x scale
- **手动冒烟清单**：热键触发、框选、剪贴板粘贴验证、ESC 取消、无效选区取消、双屏各自截取、权限拒绝引导
