# Changelog

All notable changes to SwiftFloat will be documented in this file.

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
