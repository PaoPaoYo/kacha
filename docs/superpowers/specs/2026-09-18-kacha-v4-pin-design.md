# 咔嚓 Kacha — V4 钉图设计

日期：2026-09-18
状态：已与作者确认
前置：V1（mvp）、V2（窗口识别）、V3（标注）

## 1. 概述

截图确认时可将选区内容（含标注 + 圆角合成后的最终图）钉在桌面：置顶浮动小窗，可拖动移动、边缘拖拽等比调整大小，点击获得焦点后 ESC 关闭。支持多开（每次钉图一个独立窗口）。

## 2. 交互（作者原话为源）

1. 保存按钮左边加**钉图按钮**（`pin` 图标，probe 定）
2. 点击 → 选区最终图显示为置顶浮动窗；主截图流程随之关闭
3. **调整大小：无手柄，边缘拖拽与系统窗口手感一致**——鼠标移到窗口边缘出方向缩放光标（四边直向 / 四角对角），拖动等比调整（保持横纵比，锚定对边/对角）
4. **关闭按钮默认隐藏，鼠标移入窗口才显示**（右上角小圆钮，液态玻璃风格）
5. **点击钉图窗口使其成为焦点（key window）后，ESC 关闭该窗**；点击不抢走其他窗口焦点的取舍——钉图需可 key（ESC 语义依赖），故点击即激活
6. 内容区拖动 = 移动窗口（setFrameOrigin，钉图标配）

## 3. 技术要点

- **PinWindow = borderless NSPanel**：`isFloatingPanel = true`（置顶）、`canBecomeKey = true`（ESC）、`.canJoinAllSpaces`（跨 Space 置顶）、非激活外观（`titlebarAppearsTransparent`/无标题）
- **等比 resize 数学**（`PinGeometry` 纯函数，单测）：拖动量 → 按纵横比换算新尺寸（锚定对边/对角），clamp 最小 64×64、不超屏
- **PinView（SwiftUI 内容）**：最终图显示；`.onContinuousHover` 检测边缘区（内 8pt）切换光标 + 起拖；拖动手势分派（边缘 = resize、内部 = 移动）；hover 任意位置显示关闭钮（右上，点击 `orderOut` 释放）
- **PinWindowController**（@MainActor）：`pin(_ image: CGImage, initialSize:)` 开窗并纳入数组；窗口关闭（ESC/关闭钮）即移除释放；app 终止全清
- **链路**：工具栏钉图钮 → `onPin(selection, cornerRadius, annotations)` → OverlayController 走与复制/保存相同合成（裁剪 → AnnotationRenderer → 圆角化）→ CaptureCoordinator 调 PinWindowController 开窗 + dismissAll 主流程
- 初始尺寸 = 选区 point 尺寸 clamp 屏内

## 4. 测试

- **单元测试（TDD）**：`PinGeometryTests`——等比换算（角/边锚定、最小/最大 clamp、比例保持精度）
- **冒烟**：钉图置顶（覆盖其他 app 之上）；拖动移动；边缘光标 + 等比缩放（四角四边）；hover 出关闭钮/移出隐藏；ESC（先点击钉图获焦）；多开互不干扰；标注+圆角内容正确；主流程关闭

## 5. 不做（YAGNI）

- 钉图再标注/编辑、阴影效果、多钉图对齐吸附、钉图内容实时刷新
