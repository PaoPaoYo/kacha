# 标注对象编辑 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在截图标注会话中实现箭头、矩形、椭圆和画笔的对象选择、编辑、删除以及操作级撤销/重做。

**Architecture:** 新建纯 Swift 的 `AnnotationEditor` 与 `AnnotationHistory`，集中处理命中、手柄、变换、样式、按 ID 删除和快照历史。`SelectionView` 仅持有 UI 选择状态并把鼠标事件路由到编辑层或既有截图选区调整层；选中辅助线与手柄只在预览 overlay 中渲染，`AnnotationRenderer` 保持最终位图合成职责。

**Tech Stack:** Swift 6、SwiftUI、AppKit、CoreGraphics、XCTest、macOS 26.0。

**Spec:** `docs/superpowers/specs/2026-09-22-annotation-editor-design.md`

## Global Constraints

- 目标平台为 macOS 26.0，且不引入第三方依赖。
- 可编辑对象仅限箭头、矩形、椭圆与画笔；模糊标注本轮创建后不可编辑。
- 椭圆保持自由宽高比例，不改为严格圆形。
- 所有标注坐标继续使用截图选区中的 `0...1` 归一化坐标并 clamp。
- 选择优先级必须为：已选控制点、顶层可编辑标注、截图选区手柄、截图选区移动。
- 矩形和椭圆只通过描边命中，内部空白不命中；重叠对象以数组末尾为顶层。
- 选中框、控制点、辅助线和光标均不能进入 `AnnotationRenderer` 导出结果。
- 拖拽一次只生成一条历史记录；`⌘Z` 撤销，`⌘⇧Z` 重做；新操作清空 redo。
- 当前 `Makefile` 的未提交“install 后清理 `build/Kacha.app`”修改不属于本计划，不得纳入标注相关提交。

---

## File Structure

- Create `Sources/Kacha/AnnotationEditor.swift` — 纯逻辑的编辑目标、命中、手柄、变换和按 ID 文档操作。
- Create `Sources/Kacha/AnnotationHistory.swift` — 标注文档快照、操作级 undo/redo。
- Modify `Sources/Kacha/Annotation.swift` — 补充编辑层共用的可见 bounds、路径描边辅助 API；不改变导出模型语义。
- Modify `Sources/Kacha/SelectionView.swift` — 选择状态、编辑手势、预览手柄、样式/删除/undo-redo 控件绑定与光标。
- Modify `Tests/KachaTests/AnnotationTests.swift` — 增加纯几何与编辑变换覆盖。
- Create `Tests/KachaTests/AnnotationEditorTests.swift` — 命中、手柄、变换、样式与删除的编辑层测试。
- Create `Tests/KachaTests/AnnotationHistoryTests.swift` — 快照历史、undo/redo、拖拽单步提交测试。
- Modify `Tests/KachaTests/AnnotationRendererTests.swift` — 编辑后箭头、椭圆、画笔和叠放顺序导出回归测试。

### Task 1: 标注编辑几何与文档操作

**Files:**
- Create: `Sources/Kacha/AnnotationEditor.swift`
- Modify: `Sources/Kacha/Annotation.swift`
- Create: `Tests/KachaTests/AnnotationEditorTests.swift`
- Modify: `Tests/KachaTests/AnnotationTests.swift`

**Interfaces:**
- Produces `enum AnnotationEditTarget: Equatable { case move; case arrowStart; case arrowEnd; case resize(AnnotationResizeHandle) }`。
- Produces `enum AnnotationResizeHandle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }`。
- Produces `struct AnnotationEditor` with `hitTest(annotations:point:selectionSize:) -> Annotation.ID?`、`target(at:annotation:selectionSize:) -> AnnotationEditTarget?`、`transformed(_:target:from:to:) -> Annotation`、`updatingStyle(_:color:lineWidth:) -> Annotation`、`removing(id:from:) -> [Annotation]`。
- Consumes现有 `Annotation.Kind`、`AnnotationGeometry.path` 与归一化坐标转换。

- [ ] **Step 1: 写入命中顺序与空心形状的失败测试**

```swift
func test_hitTestPrefersLastOverlappingEditableAnnotation() {
    let bottom = Annotation(kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)), color: .red, lineWidth: 4)
    let top = Annotation(kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)), color: .blue, lineWidth: 4)

    XCTAssertEqual(
        AnnotationEditor.hitTest(
            annotations: [bottom, top],
            point: CGPoint(x: 0.2, y: 0.45),
            selectionSize: CGSize(width: 1000, height: 1000)
        ),
        top.id
    )
}

func test_hitTestDoesNotSelectRectInterior() {
    let annotation = Annotation(kind: .rect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)), color: .red, lineWidth: 4)

    XCTAssertNil(
        AnnotationEditor.hitTest(
            annotations: [annotation],
            point: CGPoint(x: 0.45, y: 0.45),
            selectionSize: CGSize(width: 1000, height: 1000)
        )
    )
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AnnotationEditorTests`

Expected: 编译失败，提示 `AnnotationEditor` 未定义。

- [ ] **Step 3: 实现命中与手柄 API**

在 `AnnotationEditor.swift` 实现以下规则：

```swift
static func hitTest(
    annotations: [Annotation],
    point: CGPoint,
    selectionSize: CGSize
) -> Annotation.ID? {
    annotations.reversed().first { annotation in
        isEditable(annotation) && pathContains(
            annotation: annotation,
            point: point,
            selectionSize: selectionSize
        )
    }?.id
}
```

- 箭头、矩形、椭圆和画笔使用 `AnnotationGeometry.path` 的 `copy(strokingWithWidth:lineCap:lineJoin:miterLimit:transform:)` 扩展描边后判断 `contains`。
- 由 `max(annotation.lineWidth, 8)` 计算交互命中宽度，转换为归一化坐标对应的 local point 宽度。
- `.blur` 返回不可编辑/不可命中。
- 为箭头返回两个控制点；矩形/椭圆返回八个 bounds 控制点；画笔返回空数组。

- [ ] **Step 4: 为变换与样式写失败测试**

```swift
func test_transformMovesArrowBothEndpointsAndClampsToSelection() {
    let arrow = Annotation(kind: .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.8, y: 0.7)), color: .red, lineWidth: 4)

    let result = AnnotationEditor.transformed(
        arrow,
        target: .move,
        from: CGPoint(x: 0.5, y: 0.5),
        to: CGPoint(x: 0.9, y: 0.9)
    )

    XCTAssertEqual(result.kind, .arrow(start: CGPoint(x: 0.3, y: 0.4), end: CGPoint(x: 1, y: 0.9)))
}

func test_transformUpdatesArrowEndOnly() {
    let arrow = Annotation(kind: .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.8, y: 0.7)), color: .red, lineWidth: 4)

    let result = AnnotationEditor.transformed(
        arrow,
        target: .arrowEnd,
        from: CGPoint(x: 0.8, y: 0.7),
        to: CGPoint(x: 0.6, y: 0.4)
    )

    XCTAssertEqual(result.kind, .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.6, y: 0.4)))
}
```

- [ ] **Step 5: 实现变换、样式和删除**

- `.move` 对箭头两端、画笔全部 points、矩形/椭圆 origin 施加同一归一化 delta；保留对象原有尺寸并将整体移动限制到 `0...1`。
- `.arrowStart` 与 `.arrowEnd` 只更新对应点并 clamp。
- resize 根据起始 bounds 与固定对边/对角计算新的 `CGRect`，允许拖过对边后使用 `standardized` 归一化为正尺寸；宽高最小为 `0.01`。
- `updatingStyle` 保留 ID 与 kind，仅替换 color/lineWidth。
- `removing` 通过 `id` 过滤数组。

- [ ] **Step 6: 补充矩形/椭圆 resize、画笔移动、删除和样式测试**

```swift
func test_resizeNormalizesRectWhenDraggedAcrossOppositeCorner() { /* topLeft 拖过 bottomRight 后仍返回正 CGRect */ }
func test_resizeEllipseChangesWidthAndHeightIndependently() { /* right handle 仅改 width */ }
func test_movePenTranslatesEveryPoint() { /* 所有 points 加相同 delta */ }
func test_updatingStylePreservesAnnotationIdentityAndKind() { /* id/kind 不变 */ }
func test_removingDeletesOnlyMatchingAnnotationID() { /* 保留其他笔 */ }
```

每个测试都以现有 `Annotation` 构造对象，并对归一化 `Kind`、ID、色值、线宽断言。

- [ ] **Step 7: 运行编辑层测试**

Run: `swift test --filter 'Annotation(Editor|Tests)'`

Expected: PASS，所有新增命中、手柄、变换、样式与删除测试为 0 failures。

- [ ] **Step 8: 提交 Task 1**

```bash
git add Sources/Kacha/Annotation.swift Sources/Kacha/AnnotationEditor.swift Tests/KachaTests/AnnotationTests.swift Tests/KachaTests/AnnotationEditorTests.swift
git commit -m "feat: add annotation editing geometry"
```

### Task 2: 操作级标注历史

**Files:**
- Create: `Sources/Kacha/AnnotationHistory.swift`
- Create: `Tests/KachaTests/AnnotationHistoryTests.swift`

**Interfaces:**
- Produces `struct AnnotationDocumentState: Equatable { var annotations: [Annotation]; var selectedAnnotationID: Annotation.ID? }`。
- Produces `struct AnnotationHistory` with `init(initial:)`、`var current: AnnotationDocumentState`、`var canUndo: Bool`、`var canRedo: Bool`、`mutating func commit(_:)`、`mutating func undo() -> AnnotationDocumentState?`、`mutating func redo() -> AnnotationDocumentState?`。
- Consumes Task 1 的稳定 `Annotation.ID` 与不可变文档快照。

- [ ] **Step 1: 写入 undo/redo 失败测试**

```swift
func test_commitUndoAndRedoRestoreAnnotationsAndSelection() {
    let first = Annotation(kind: .rect(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)), color: .red, lineWidth: 4)
    let second = Annotation(kind: .ellipse(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)), color: .blue, lineWidth: 8)
    var history = AnnotationHistory(initial: .init(annotations: [first], selectedAnnotationID: first.id))

    history.commit(.init(annotations: [first, second], selectedAnnotationID: second.id))

    XCTAssertEqual(history.undo(), .init(annotations: [first], selectedAnnotationID: first.id))
    XCTAssertEqual(history.redo(), .init(annotations: [first, second], selectedAnnotationID: second.id))
}

func test_commitAfterUndoClearsRedo() {
    var history = AnnotationHistory(initial: .init(annotations: [], selectedAnnotationID: nil))
    let first = Annotation(kind: .pen(points: [.zero, CGPoint(x: 0.1, y: 0.1)]), color: .red, lineWidth: 2)
    let second = Annotation(kind: .pen(points: [.zero, CGPoint(x: 0.2, y: 0.2)]), color: .blue, lineWidth: 4)

    history.commit(.init(annotations: [first], selectedAnnotationID: first.id))
    _ = history.undo()
    history.commit(.init(annotations: [second], selectedAnnotationID: second.id))

    XCTAssertFalse(history.canRedo)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AnnotationHistoryTests`

Expected: 编译失败，提示 `AnnotationHistory` 未定义。

- [ ] **Step 3: 实现快照式历史**

```swift
struct AnnotationHistory {
    private var undoStack: [AnnotationDocumentState] = []
    private var redoStack: [AnnotationDocumentState] = []
    private(set) var current: AnnotationDocumentState

    mutating func commit(_ state: AnnotationDocumentState) {
        guard state != current else { return }
        undoStack.append(current)
        current = state
        redoStack.removeAll()
    }

    mutating func undo() -> AnnotationDocumentState? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        return current
    }
}
```

实现对称的 `redo()`，并将 `canUndo`/`canRedo` 映射到对应栈非空。不得把鼠标帧或 UI 状态写入历史；调用端只在完整操作完成时 `commit`。

- [ ] **Step 4: 增加 no-op、删除与样式编辑快照测试并运行**

```swift
func test_committingSameStateDoesNotCreateUndoEntry() { /* commit current 后 canUndo 为 false */ }
func test_undoRestoresDeletedAnnotationAndSelectedID() { /* 删除后 undo 恢复对象和选择 */ }
func test_undoRestoresPreviousStyle() { /* color/lineWidth 改动可撤销 */ }
```

Run: `swift test --filter AnnotationHistoryTests`

Expected: PASS，0 failures。

- [ ] **Step 5: 提交 Task 2**

```bash
git add Sources/Kacha/AnnotationHistory.swift Tests/KachaTests/AnnotationHistoryTests.swift
git commit -m "feat: add annotation undo redo history"
```

### Task 3: SelectionView 选择、编辑与预览辅助层

**Files:**
- Modify: `Sources/Kacha/SelectionView.swift`
- Modify: `Sources/Kacha/AnnotationEditor.swift`（仅当 Task 1 API 无法表示真实手势输入时）
- Modify: `Tests/KachaTests/AnnotationEditorTests.swift`

**Interfaces:**
- Consumes Task 1 的 `AnnotationEditor` 与 Task 2 的 `AnnotationHistory`/`AnnotationDocumentState`。
- Produces SelectionView 中的 `selectedAnnotationID`、拖拽操作状态和 `commitAnnotationState()`。
- Produces预览专用 `annotationSelectionOverlay`，不向 `OverlayController` 回调添加编辑辅助对象。

- [ ] **Step 1: 在 SelectionView 加入文档与编辑状态**

将当前直接管理的 `annotations` 改为从 `AnnotationHistory.current.annotations` 读取，并增加：

```swift
@State private var annotationHistory = AnnotationHistory(initial: .init(annotations: [], selectedAnnotationID: nil))
@State private var activeAnnotationEdit: AnnotationEditTarget?
@State private var annotationEditStartPoint: CGPoint?
@State private var annotationEditStartValue: Annotation?

private var annotations: [Annotation] { annotationHistory.current.annotations }
private var selectedAnnotationID: Annotation.ID? { annotationHistory.current.selectedAnnotationID }
```

通过 `commitAnnotationState(annotations:selectedAnnotationID:)` 生成新 `AnnotationDocumentState` 并调用 `annotationHistory.commit`；不得再直接 append/remove 历史数组。

- [ ] **Step 2: 实现选择工具的命中与手势路由**

在现有 select 模式鼠标处理前执行：

```swift
if let selected = selectedAnnotation,
   let target = AnnotationEditor.target(at: normalizedPoint, annotation: selected, selectionSize: selection.size) {
    beginAnnotationEdit(target, at: normalizedPoint, annotation: selected)
    return
}

if let id = AnnotationEditor.hitTest(annotations: annotations, point: normalizedPoint, selectionSize: selection.size),
   let annotation = annotations.first(where: { $0.id == id }) {
    commitAnnotationState(annotations: annotations, selectedAnnotationID: id)
    beginAnnotationEdit(.move, at: normalizedPoint, annotation: annotation)
    return
}
```

仅当这两个路径均未命中时继续当前截图选区手柄与移动处理。非 select 创建工具保持现有全选区绘制层逻辑，并在切换工具时清除 selectedAnnotationID。

- [ ] **Step 3: 实现拖拽更新与单步提交**

鼠标拖动时仅基于 `annotationEditStartValue` 调用：

```swift
let preview = AnnotationEditor.transformed(
    annotationEditStartValue,
    target: activeAnnotationEdit,
    from: annotationEditStartPoint,
    to: currentNormalizedPoint
)
```

以临时 preview 状态渲染，不调用 `AnnotationHistory.commit`。鼠标抬起时将 preview 替换到同 ID 数组元素，且只有与起始对象不同才提交一次新状态。取消或无几何变化时不产生历史条目。

- [ ] **Step 4: 添加预览专用选中 overlay**

在现有 annotation Canvas 上方添加仅视觉的层：

- 箭头：两个 `Circle` 控制点；
- 矩形/椭圆：虚线 bounds 与八个 `Circle` 控制点；
- 画笔：虚线 bounds，无控制点；
- overlay 必须 `.allowsHitTesting(false)`，真实鼠标路由继续在专用透明 hit 区处理；
- 不修改 `AnnotationRenderer`、`OverlayController` 的输出回调或保存链路。

- [ ] **Step 5: 实现删除、样式与键盘命令**

- 有可编辑选中对象时，颜色与宽度 getter 从对象读取；setter 用 `AnnotationEditor.updatingStyle` 替换并一次 `commit`。
- 无选择时，颜色与宽度控件继续写入新建默认值。
- `Delete`/`Backspace` 调用 `AnnotationEditor.removing` 并提交 selected ID 为 nil 的状态。
- `⌘Z` 调用 `annotationHistory.undo()`；`⌘⇧Z` 调用 `annotationHistory.redo()`；现有 removeLast 语义删除。
- 工具栏新增删除按钮，绑定 selected 可编辑对象；未选中或模糊对象时禁用。

- [ ] **Step 6: 更新光标与纯逻辑手势回归测试**

- arrow start/end 使用 crosshair；move 使用 open/closed hand；rect/ellipse 依据八个 handle 返回现有方向 resize 光标。
- 在 `AnnotationEditorTests` 加入“控制点优先于路径”、“交叠对象末尾优先”、“拖拽中间帧不提交历史”的可测试 helper 断言。

- [ ] **Step 7: 运行相关测试**

Run: `swift test --filter 'Annotation(Editor|History|Tests)'`

Expected: PASS，0 failures。

- [ ] **Step 8: 提交 Task 3**

```bash
git add Sources/Kacha/SelectionView.swift Sources/Kacha/AnnotationEditor.swift Tests/KachaTests/AnnotationEditorTests.swift
git commit -m "feat: edit selected annotations"
```

### Task 4: 导出回归与端到端验证

**Files:**
- Modify: `Tests/KachaTests/AnnotationRendererTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes Task 1 编辑后的 `Annotation` 与 Task 3 的选中视觉隔离原则。
- Produces回归保证：编辑后模型导出正确，且编辑辅助状态不会传入 renderer。

- [ ] **Step 1: 写编辑后导出的失败测试**

```swift
func test_compositeRendersMovedArrowAtEditedPosition() {
    let original = Annotation(kind: .arrow(start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.3, y: 0.1)), color: .red, lineWidth: 4)
    let moved = AnnotationEditor.transformed(original, target: .move, from: CGPoint(x: 0.2, y: 0.1), to: CGPoint(x: 0.5, y: 0.4))

    let image = AnnotationRenderer.composite(baseImage: testImage, annotations: [moved], selectionSize: CGSize(width: 100, height: 100))

    XCTAssertNotEqual(pixel(image, x: 20, y: 10), pixel(image, x: 50, y: 40))
}
```

同时为变形后的椭圆、改色后的画笔和两笔叠放顺序编写像素断言；断言采样点必须位于预期 stroke 内外，避免抗锯齿边界。

- [ ] **Step 2: 运行 renderer 测试确认新增覆盖有效**

Run: `swift test --filter AnnotationRendererTests`

Expected: 新增案例在 Task 1 变换逻辑存在时通过；若测试暴露渲染比例或路径问题，先修复导出模型问题而不是改弱断言。

- [ ] **Step 3: 更新 README 功能与快捷键说明**

在标注功能说明中加入“点击选择标注、移动、删除、调整箭头端点/框椭圆大小、修改颜色线宽”；把撤销说明改为“`⌘Z` 撤销操作，`⌘⇧Z` 重做”。明确画笔仅支持整体移动和样式调整，模糊仍不可二次编辑。

- [ ] **Step 4: 运行完整验证**

Run: `swift test && swift build -c release && git diff --check`

Expected: 全量测试通过、release 构建成功、无 diff whitespace 错误。

- [ ] **Step 5: 人工 smoke 测试签名应用**

Run: `pkill -x kacha 2>/dev/null || true && make install`

检查：

1. 创建重叠的箭头、矩形、椭圆和画笔，点击顶层对象并验证选择边框；
2. 拖动箭头首尾、框/椭圆八个控制点与画笔整体，验证拖拽后导出位置正确；
3. 对选中对象改色/线宽、Delete 删除、`⌘Z`/`⌘⇧Z` 恢复与重做；
4. 未命中标注时仍可移动/缩放截图选区；
5. 切换绘制工具后清除选择，创建工具仍可连续画；
6. 保存/复制/钉图结果不含虚线边框或控制点。

- [ ] **Step 6: 提交 Task 4**

```bash
git add Tests/KachaTests/AnnotationRendererTests.swift README.md
git commit -m "test: cover edited annotation output"
```

## Self-Review

- **Spec coverage:** Task 1 完成所有对象命中、变换、样式和删除的纯逻辑；Task 2 为所有对象编辑提供操作级历史；Task 3 将选择优先级、辅助视觉、样式/删除和键盘命令接入截图 overlay；Task 4 覆盖最终导出与用户文档。模糊不进入编辑路径、椭圆自由比例、导出不含辅助 UI 均有明确任务约束。
- **Placeholder scan:** 计划不含 TBD/TODO、未定义接口或泛化的“补充测试”步骤；每项测试均指定目标行为与命令。
- **Type consistency:** `AnnotationEditTarget`、`AnnotationResizeHandle`、`AnnotationDocumentState`、`AnnotationHistory` 与 `AnnotationEditor` 的方法名在后续 SelectionView 和测试任务中一致。
