# Changelog

All notable changes to SwiftFloat will be documented in this file.

## [0.2.0] - 2026-04-24

### Added
- Slash command 模式：输入框只有 "/" 时自动显示悬浮框
  - AX 可用应用：pollFocus 读取字段值 + AXObserver 监听 kAXValueChangedNotification
  - Electron 应用：CGEvent tap 检测 "/" 键，退格回到 "/" 重新显示
- CGEvent tap 键盘监听（Electron 应用 AX API 不可用的 fallback）
- FloatWindowManager.isSlashMode 状态标记
- FloatWindowManager.showForSlash() 方法

### Changed
- FocusMonitor 完全重写：从「焦点到文本框即显示」简化为「划词选中显示 / slash-only 显示」
- 移除 autoShowEnabled 配置项，改为更精确的双模式触发
- 移除 isTextInput / findTextFieldIn 等 Electron 穿透代码（AX 不可用时由 CGEvent tap 处理）
- AXObserver 增加 kAXValueChangedNotification 监听
- AXObserverCreate 使用正确的 elementPID 替代硬编码 0
- SelectionMonitor.isCurrentAppAllowed 增加 NSWorkspace fallback（AX 失败时也能判断白名单）
- simulateCopy 延迟从 0.1s 增加到 0.3s，提高可靠性
- 编译工具链：swift-tools-version 5.9 → 5.7，macOS 14 → 12，适配 Command Line Tools 环境
- make_app.sh BUILD_DIR 从 debug 改为 release

### Fixed
- 悬浮框自动消失：isSelectionMode 标志区分选中模式和焦点模式
- 点击外部隐藏：划词模式下点击外部直接隐藏
- 白名单应用判断：Electron 应用 AX 失败时不再误隐藏

### Removed
- autoShowEnabled 配置
- isTextInput / findTextFieldIn Electron 穿透逻辑
- lastFocusedElementID / lastBundleID / lastFieldWasEmpty 状态追踪

## [0.1.0] - 2026-04-23

### Added
- 全局文本选中监听（AXObserver API）
- 悬浮球显示选中文本摘要和快捷文本
- 快捷文本管理：新增/编辑/删除
- CLI 工具支持：`swiftfloat add/list/remove/search`
- 文件监听热加载快捷文本
- Xcode 项目配置（Package.swift + project.yml）
- TCC 权限配置（Accessibility + AppleEvents）

### Technical
- 基于 Swift 5.9 + SwiftUI
- AXObserver 实现全局文本选中监听
- NSWindow 悬浮球窗口管理
- JSON 文件持久化快捷文本

---

## 版本命名规则

- **主版本号 (MAJOR)**：不兼容的 API 变更
- **次版本号 (MINOR)**：向后兼容的功能新增
- **修订号 (PATCH)**：向后兼容的问题修复

## 更新日志格式

每次推送前更新 CHANGELOG.md：
```markdown
## [版本号] - YYYY-MM-DD

### Added
- 新增功能

### Changed
- 功能变更

### Fixed
- Bug 修复

### Removed
- 移除功能
```
