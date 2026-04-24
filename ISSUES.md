# SwiftFloat 逻辑缺陷清单

**审查时间**: 2026-04-24 00:11  
**版本**: v0.2.0 (commit c2ded3c)

---

## 🔴 P0 — 严重（功能错误）

### #5 `getAXValue` fallback 返回 selectedText 而非字段值

**文件**: FocusMonitor.swift  
**位置**: `getAXValue(_:)` 方法

**问题**: 当 `kAXValueAttribute` 获取失败时，fallback 到 `kAXSelectedTextAttribute`。但 `selectedText` 是选中的子串，不是整个字段值。

**场景**: 用户在输入框输入 `/hello` 然后选中了 `hello`，`getAXValue` 返回 `hello` 而非 `/hello`，slash 检测逻辑完全错乱。

**修复**: 删除 `kAXSelectedTextAttribute` fallback。AX 获取字段值失败时，返回空字符串，由 CGEvent tap 处理 Electron 应用。

---

### #2 CGEvent tap 回调中异步引用 CGEvent 导致悬垂引用

**文件**: FocusMonitor.swift  
**位置**: `keyEventCallback` 函数

**问题**: `keyEventCallback` 中 `DispatchQueue.main.async { monitor.handleKeyEvent(event) }` — `event` 是 CGEvent 引用，异步执行时原始事件可能已被系统回收/复用。

**修复**: 在回调线程同步创建 `NSEvent(cgEvent:)` 或提取 keyCode/chars，再 async 派发提取后的值。

---

## 🟡 P1 — 中等（边界情况/体验问题）

### #1 FocusMonitor 与 SelectionMonitor 双重触发

**问题**: 用户双击选中文本时，SelectionMonitor 先触发 `showForSelection`，0.3s 后 FocusMonitor `pollFocus` 再次触发。AXObserver 的 `handleSelectionChanged` 也不检查可见性就直接 `showForSelection`，可能覆盖用户正在操作的状态。

### #4 `slashModeExtraChars` 在切换应用后不重置

**问题**: 在 QClaw 按 "/" → 进入 slash 模式 → 切到另一个白名单应用 → `slashModeExtraChars` 残留旧值 → 新应用 slash 检测行为错误。

### #6/8 `pollFocus`/`handleValueChanged` 不检查焦点元素是否是文本输入框

**问题**: 对按钮、滑块、菜单项等非文本元素也检查 `kAXValueAttribute`，若其 value 恰好是 `"/"` 会误触发 slash 模式。

### #3 AX 路径与 CGEvent 路径状态不同步

**问题**: Electron 应用 AX 行为不稳定时，同一应用可能交替走两条路径，各自维护独立状态（`isSlashMode` vs `slashModeExtraChars`）。

### #7 AXObserver 的 `element` 比较用 `CFHash` 不可靠

**问题**: 不同元素可能 hash 碰撞，导致不重复注册的守卫失效。

### #9 点击外部隐藏与 slash 模式冲突

**问题**: slash 模式下悬浮框弹出后，0.3s 内用户点到框外（位置偏移），窗口会消失。

### #10 `simulateCopy` 和 `insertText` 剪贴板恢复竞态

**问题**: 两个操作短时间内连续触发时剪贴板状态混乱。

---

## 🟢 P2 — 轻微（代码质量/潜在隐患）

### #12 CGEvent tap 回调返回 `passRetained` 导致引用计数泄漏

**问题**: 应返回 `Unmanaged.passUnretained(event)`。

### #13 `snippetClicked` 用 `sender.title` 匹配 snippet

**问题**: label 相同时总匹配第一个。应改用 `sender.identifier`。

### #14 `rebuildWithSelection` 没有显示已有 snippet 列表

**问题**: 划词选中后只有「快捷添加」，无法直接插入已有 snippet。

### #11 CGEvent tap 用 `passUnretained` 传 self

**问题**: FocusMonitor 是单例所以实际安全，但设计上脆弱。

---

## 修复状态

| # | 优先级 | 描述 | 状态 |
|---|--------|------|------|
| 5 | P0 | getAXValue fallback 错误 | ✅ 已修 |
| 2 | P0 | CGEvent 回调悬垂引用 | ✅ 已修 |
| 12 | P2 | passRetained 泄漏 | ✅ 已修（随 #2 一起修复） |
| 1 | P1 | 双重触发 | ⬜ 待修 |
| 4 | P1 | slashModeExtraChars 不重置 | ⬜ 待修 |
| 6/8 | P1 | 不检查元素角色 | ⬜ 待修 |
| 3 | P1 | AX/CGEvent 状态不同步 | ⬜ 待修 |
| 7 | P1 | CFHash 不可靠 | ⬜ 待修 |
| 9 | P1 | 点击外部与 slash 冲突 | ⬜ 待修 |
| 10 | P1 | 剪贴板竞态 | ⬜ 待修 |
| 12 | P2 | passRetained 泄漏 | ⬜ 待修 |
| 13 | P2 | snippetClicked 匹配 | ⬜ 待修 |
| 14 | P2 | 选中模式无 snippet 列表 | ⬜ 待修 |
| 11 | P2 | passUnretained self | ⬜ 待修 |
