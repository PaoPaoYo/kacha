# 咔嚓 Kacha — V3 标注工具设计

日期：2026-09-17
状态：已与作者确认
前置：V1（mvp）、V2（窗口识别）

## 1. 概述

调整态选区内绘制标注：箭头、矩形、椭圆、画笔（自由折线），颜色 8 色板点选、粗细三档点选（2/4/8pt），支持撤销最后一笔。标注在确认时按像素比例合成到输出图（在圆角化之前）。标注几何用归一化坐标（相对选区 0–1），选区移动/缩放时标注跟随（画笔随形变拉伸，所见即所得）。

## 2. 交互模型

```
工具栏新行：[选择|箭头|矩形|椭圆|画笔] ‖ [8色板] ‖ [细|中|粗] ‖ [撤销]
（与现有 [圆角滑条|保存|复制] 行堆叠为两行组，整组锚定选区右下，贴底收内侧）
```

- 「选择」工具（默认）= 现有行为：选区内拖动平移、边/角缩放
- 标注工具激活：选区内拖动 = 绘制当前形状（实时预览，坐标 clamp 选区内）；选区缩放/平移操作让位
- 绘制完成停留当前工具（连画多笔）；撤销按钮删除最后一笔
- 标注不影响圆角滑条/双击/回车/右键/ESC 语义

## 3. 模块

| 模块 | 职责 |
|---|---|
| `Annotation`（新，纯数据+纯几何） | Kind（arrow/rect/ellipse/pen）、RGBA 分量、lineWidth(pt)；归一化坐标 ↔ 选区局部 point 换算静态函数（可单测）；箭头头部几何（头长 = max(3×lineWidth, 10pt)，头角 30°）静态函数 |
| `SelectionView` | `@State annotations: [Annotation]`、`@State activeTool: AnnotationTool`、`@State annotationColor: RGBA`、`@State annotationWidth: CGFloat`、`@State drawingAnnotation: Annotation?`（进行中）；工具行 UI（5 工具钮/8 色板/3 粗细/撤销）；绘制手势（标注工具激活时接管选区内拖动）；ForEach Shape 实时渲染 |
| `OverlayController` | confirm/save 链路增加标注合成调用（裁剪后、圆角化前） |
| `AnnotationRenderer`（新） | CGContext 像素级合成：annotations + 像素尺寸 + scale → 重绘到 CGImage（箭头/矩形/椭圆/画笔与屏幕预览同构） |

色板（固定 8 色）：红 `#FF3B30`、橙 `#FF9500`、黄 `#FFCC00`、绿 `#34C759`、蓝 `#007AFF`、紫 `#AF52DE`、黑 `#000000`、白 `#FFFFFF`（白配细描边保证深色背景可见）。

## 4. 关键技术点

- **归一化坐标**：绘制时记录 (局部 point − selection.origin) / selection.size ∈ [0,1]；渲染/合成都乘回当前选区尺寸 → 选区形变自动跟随
- **绘制手势接管**：标注工具激活时在选区命中层之上加绘制层（DragGesture minimumDistance 0，.named("sel") 坐标），move/边/角手势层被覆盖让位（渲染顺序控制）；「选择」工具时绘制层移除
- **clamp**：绘制坐标 clamp 到选区 bounds（arrow/rect/ellipse 端点、pen 采样点）
- **画笔采样**：onChanged 连续 append 点（去重：与上一点距离 > 1pt）
- **合成顺序**：裁剪图 → AnnotationRenderer（线宽×scale，箭头头长同步缩放）→ 圆角化 → 输出
- **_RGBA_ 存储**：`struct RGBA: Equatable { var r, g, b, a: Double }`（Codable 可选），预览与 CGContext 各自转换

## 5. 测试策略

- **单元测试（TDD）**：归一化↔局部换算（含选区移动/缩放后跟随）、绘制 clamp（四类）、箭头头几何（头长下限、方向角）、pen 去重
- **冒烟**：四工具绘制手感；色板/粗细切换即时生效；撤销逐笔；选区移动/缩放标注跟随；输出放大核对颜色线宽像素正确；标注+圆角并存；选择工具恢复平移缩放；双击/回车/右键/ESC 无回归

## 6. 不做（YAGNI）

- 标注的选中/编辑/删除单笔（仅撤销最后一笔）、文字标注、马赛克、高亮笔（半透明）、多撤销栈/重做
- 标注样式记忆（跨会话）——颜色/粗细每次会话默认（红/中），可后续加 @AppStorage
