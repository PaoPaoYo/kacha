# Kacha 设置页 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 系统风格设置页（快捷键录制 / 托盘图标开关 / 开机自启），首启与 Reopen 打开

**Architecture:** SwiftUI Settings scene + openSettings；快捷键存 @AppStorage（keyCode+modifiers）驱动 HotKeyCenter 重注册；托盘经 SceneBuilder 条件渲染；首启/Reopen 各自打开设置窗。

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Carbon（热键）

**Spec:** `docs/superpowers/specs/2026-09-18-kacha-settings-design.md`

## Global Constraints

- 快捷键默认 ⌃⌘A（kVK_ANSI_A=0 + controlKey|cmdKey）；录制仅接受含 ≥1 个 ⌘/⌃/⌥ 的组合；Esc 取消录制
- `showMenuBarIcon` 默认 true；隐藏后 Reopen（applicationShouldHandleReopen）打开设置页
- 首启 flag `hasLaunchedOnce`：首次启动 openSettings（一次性）
- 圆角/模糊参数不进设置页
- 提交信息：中文 + Conventional Commits，末尾 `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- 既有 68 测试不得回归

---

### Task 1: 快捷键存储与显示（TDD）+ HotKeyCenter 重注册

**Files:**
- Create: `Sources/Kacha/HotKeyPreferences.swift`
- Modify: `Sources/Kacha/HotKeyCenter.swift`
- Test: `Tests/KachaTests/HotKeyPreferencesTests.swift`

**Interfaces:**
- Produces:
  - `struct HotKeyPreferences { var keyCode: UInt32; var modifiers: UInt32 }`，`static let defaultHotKey = .init(keyCode: 0, modifiers: controlKey|cmdKey)`
  - `HotKeyPreferences.load()` / `save()`（UserDefaults 读写，key `hotKeyCode`/`hotKeyModifiers`，缺省 default）
  - `HotKeyPreferences.displayString` -> String（"⌃⌘A" 形式：修饰符符号 + NSEvent.localizedString(for:) 键名）
  - `HotKeyPreferences.isValidCombination(modifiers:) -> Bool`（含 ⌘/⌃/⌥ 至少一个）
  - `HotKeyCenter.unregister()`（RemoveEventHotKey + handler 保留或一并移除按现有结构最小实现）；`register` 改为先 unregister；KachaApp 注册处改读 HotKeyPreferences.load()
- 单测 ≥5 例：默认值 round-trip、displayString（⌃⌘A / ⌥⇧S 类）、isValidCombination（无修饰 false / 含 ⌘ true / 含 ⌃ true）、save/load 覆写

- [ ] 测试 → RED → 实现 → 全过（68+N）→ 提交 `feat: 快捷键偏好存储与热键重注册（TDD）`

### Task 2: SettingsView + scene 接线 + 首启/Reopen

**Files:**
- Create: `Sources/Kacha/SettingsView.swift`
- Modify: `Sources/Kacha/KachaApp.swift`（Settings scene、条件 MenuBarExtra、菜单「设置…」项、首启 flag、Reopen、applicationDidFinishLaunching 热键读偏好）

**规格：**
- **SettingsView（Mos 式传统偏好窗口风格，作者提供参考图）**：
  - 顶部图标 Tab 栏：单 Tab「基础」（`gearshape` SF 图标 + 文字；选中态圆角高亮块 `.quaternary` 填充 + 细描边、文字 accent；为未来 OCR/翻译等 Tab 预留结构）——自定义 HStack 实现（非系统 TabView）
  - 两列表单（**无卡片、无分隔线、纯留白**）：标签列右对齐（固定宽 ~100pt）+ 控件列左对齐；行距 20-24pt；内容区左右大留白（~20%）
  - Toggle 用**复选框样式** `.toggleStyle(.checkbox)`；说明文字 caption `.secondary` 缩进对齐控件列
  - 三行：启动（复选框「在开机时启动」）；状态栏图标（复选框「隐藏状态栏图标」+ caption「再次运行咔嚓以显示状态栏图标」）；快捷键（当前组合 displayString + 「录制」按钮：录制态显示「按下新组合…」，NSEvent local monitor 捕获 keyDown——有效组合（含 ≥1 个 ⌘/⌃/⌥）则 save + HotKeyCenter 重注册；Esc 取消录制；「恢复默认」按钮）
- **KachaApp**：`Settings { SettingsView() }` scene；`@SceneBuilder` 中 `if showMenuBarIcon` 条件渲染 MenuBarExtra；菜单栏原自启 Toggle 移除、菜单加「设置…」经 openSettings 打开；applicationDidFinishLaunching：首启（!hasLaunchedOnce）→ set flag → 打开设置窗（`NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` 或实际 SDK 可用路径，报告注明）；`applicationShouldHandleReopen`：托盘隐藏时 → 打开设置页 + NSApp.activate
- `swift build && swift test` → `make install` → 用户冒烟（spec §5 清单）→ 提交 `feat: Mos 风格设置页与首启/Reopen 打开`
