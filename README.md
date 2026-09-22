# 咔嚓 Kacha

![macOS](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20Liquid%20Glass-blue)
![Tests](https://img.shields.io/badge/tests-68%2F68-brightgreen)
![License](https://img.shields.io/badge/license-personal-orange)

一个 macOS 截图工具：**按一下 → 冻结屏幕 → 鼠标直接操作**。悬停自动识别窗口，点击即截；拖拽自由框选；截完直接标注、打码、钉在桌面。UI 采用 macOS 26 原生 Liquid Glass 系统组件风格。

## ✨ 功能

### 截图
- ⌨️ 全局热键 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>A</kbd> 一键触发，全屏瞬间冻结（物理分辨率，窗口阴影保真）
- 🪟 鼠标悬停自动高亮窗口，**点击即截整窗**；拖拽则自由框选
- ✂️ 框选后可二次调整：四角/整边缩放、整体平移
- 📋 一键**复制**到剪贴板 / **保存**为 PNG / **钉图**置顶桌面

### 标注
- 🖍️ 箭头 · 矩形 · 椭圆 · 画笔 · **高斯模糊打码**（涂抹式）
- 🖱️ 点击选择标注后可移动、删除、调整箭头端点/矩形与椭圆大小，以及修改颜色和线宽；画笔仅支持整体移动和样式调整，模糊不可二次编辑
- 🎨 8 色板 + 三档粗细；模糊工具专属双滑块（半径/笔宽，跨会话记忆）
- ↩️ `⌘Z` 撤销操作，`⌘⇧Z` 重做
- 🔵 截图**圆角**实时调节，透明角输出

### 钉图
- 📌 选区内容钉在桌面**原位置**，置顶跨 Space
- 🪄 拖动移动 · 边缘隐形拖拽**等比**缩放（无手柄，与系统窗口手感一致）
- ⎋ 点击获焦后 <kbd>Esc</kbd> 关闭；支持多开

### 其他
- 🌙 液态玻璃工具栏：可拖动避让、按钮按工具自动显隐（右缘恒定、向左平滑展开）
- 🚀 支持开机自启、圆角/模糊参数跨会话记忆
- 🖥️ 多显示器：每屏独立覆盖窗

## 🚀 安装

```bash
git clone git@github.com:PaoPaoYo/kacha.git
cd kacha
make install    # 构建并安装到 /Applications
```

首次触发截屏时 macOS 会请求**屏幕录制**权限，允许后重开应用即可（之后更新不再重复授权）。

## ⌨️ 快捷键

| 按键 | 作用 |
|---|---|
| <kbd>⌃</kbd><kbd>⌘</kbd><kbd>A</kbd> | 触发截图 |
| <kbd>Enter</kbd> / 双击选区 | 确认（复制） |
| <kbd>⌘</kbd><kbd>Z</kbd> | 撤销操作 |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>Z</kbd> | 重做操作 |
| <kbd>Esc</kbd> / 右键 | 取消截图 / 关闭钉图 |

## 🛠️ 开发

```bash
make test       # 运行测试
make app        # 构建打包 kacha.app
make install    # 打包并安装到 /Applications（自动退出旧实例）
```

零第三方依赖——仅 SwiftUI / AppKit / ScreenCaptureKit / CoreImage / Carbon。

## 🗺️ 版本

| 版本 | 内容 |
|---|---|
| V1 | 冻结框选 → 剪贴板/保存，物理分辨率 |
| V2 | 窗口悬停识别、圆角、开机自启、阴影保真引擎 |
| V3 | 五种标注 + 模糊打码、液态玻璃工具栏 |
| V4 | 钉图置顶 |

设计文档与实现计划见 [`docs/superpowers/`](docs/superpowers/)。

## 📝 TODO

- [ ] 文本工具
- [ ] OCR
- [ ] 翻译
- [ ] 取色
