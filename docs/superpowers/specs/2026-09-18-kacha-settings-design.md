# 咔嚓 Kacha — 设置页设计

日期：2026-09-18
状态：已与作者确认
前置：V1-V4

## 1. 概述

系统风格设置页（SwiftUI `Settings` scene）集中三项设置：自定义快捷键、显示托盘图标、开机自启。首次启动展示设置页；隐藏托盘图标后可通过再次打开 App 打开设置页。

## 2. 设置项

| 项 | 控件 | 存储 |
|---|---|---|
| 快捷键 | 当前组合显示 + 「录制」按钮（点击后按下一个组合即捕获，Esc 取消录制）+ 「恢复默认 ⌃⌘A」 | @AppStorage（keyCode: Int + modifiers: Int） |
| 显示托盘图标 | Toggle，默认开 | @AppStorage("showMenuBarIcon": Bool） |
| 开机自启 | Toggle（移自菜单栏） | 现有 SMAppService 逻辑 |

## 3. 交互

- **首次启动**：一次性 flag（`hasLaunchedBefore`）→ 打开设置页
- **隐藏托盘图标后再次打开 App**（Finder 双击 / `open -a Kacha`）→ `applicationShouldHandleReopen` 打开设置页并激活
- 托盘图标显示时：菜单栏菜单加「设置…」项（`openSettings`）
- 改快捷键立即生效：HotKeyCenter 注销旧热键再注册新键
- 圆角/模糊参数**不进**设置页（工具栏已有，作者明确排除）

## 4. 技术要点

- SwiftUI `Settings { SettingsView() }` scene + `@Environment(\.openSettings)`（macOS 14+）
- 托盘隐藏：`@SceneBuilder` 条件渲染 `MenuBarExtra`（App struct 的 @AppStorage 驱动 scene 重算）
- 快捷键录制：NSEvent local monitor（keyDown + modifierFlags 捕获；仅接受含 ⌘/⌃/⌥ 至少一个修饰键的组合，普通字符键忽略）
- HotKeyCenter：拆出 `unregister()`（RemoveEventHotKey + 清引用），`register` 前先 unregister；热键键位从 @AppStorage 读取（默认 ⌃⌘A）
- 设置窗为 key 时正常响应；LSUIElement app 的 Settings 窗可获焦

## 5. 测试

- 单测：快捷键存储编解码（keyCode+modifiers ↔ 显示字符串，如 "⌃⌘A"）纯函数
- 冒烟：首启弹设置；改热键立即生效（旧键失效新键触发）；录制/取消/恢复默认；隐藏托盘→再开 App 弹设置；开机自启开关；显示托盘后菜单「设置…」入口

## 6. UI 风格（2026-09-18 作者提供参考图）

Mos 式传统偏好窗口：顶部图标 Tab 栏（单 Tab「基础」，选中圆角高亮块，为未来 Tab 预留）；两列表单——标签右对齐固定宽 + 控件左对齐；复选框样式 Toggle；caption 副标题缩进；无卡片无分隔线纯留白。
