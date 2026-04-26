# SwiftFloat — 快捷文本悬浮球

**一句话**：在任何 App 里，空输入框打 `/` 弹出快捷提示词列表，划词选中文本就弹出操作菜单。

---

## 两个核心触发

### Slash 触发

- 空输入框 → 输入 `/` → 弹出快捷文本列表
- 点击任意快捷文本 → 自动粘贴到当前输入框
- 从有内容删除到 `/` **不触发**（防止误触）

### 划词触发

- 拖拽 / 双击选中文本 → 弹出操作列表
- 操作类型：复制、翻译、快捷添加、自定义插入
- 输入框内选中**不触发**（避免干扰编辑）

---

## 两种展示模式

| 模式 | 触发方式 | 展示内容 |
|------|----------|----------|
| **Slash 模式** | 输入 `/` 或 Cmd+Shift+Space | 快捷文本列表 + 内联新增/编辑/删除 |
| **Selection 模式** | 选中文本 | 文本预览 + 操作按钮列表 |

---

## 按 App 智能分组

- 不同 App 显示不同的快捷文本和操作
- 支持 bundleID 分组（如 `com.tencent.qclaw`、`com.bytedance.lark`）
- 切换 App 自动切换分组，状态自动重置
- 无匹配时兜底使用 `default` 分组

---

## 应用白名单

配置 `~/.config/swiftfloat/apps.json`：

```json
{
  "apps": ["com.tencent.qclaw", "com.bytedance.lark", "com.apple.Safari"]
}
```

- 白名单非空 → 仅白名单内 App 生效
- 白名单为空 → 所有 App 均可触发

---

## 输入感知技术

| 路径 | 技术 | 适用场景 |
|------|------|----------|
| **主路径** | AXObserver | Mac 原生 App，可读输入框完整内容 |
| **降级** | CGEventTap | Electron App（飞书、微信等） |
| **兜底** | 0.3s 轮询 | AXObserver 失效补救 |

---

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+Shift+Space` | 显示/隐藏悬浮球 |
| `ESC` | 关闭悬浮球 |
| `回车` | 确认保存（内联表单中） |

---

## CLI 管理

```bash
# 添加快捷文本
swiftfloat add '代码审查' '请审查以下代码，指出潜在问题：'
swiftfloat add '周报' '本周工作总结：' --app com.bytedance.lark

# 查看列表
swiftfloat list
swiftfloat list --app com.tencent.qclaw

# 搜索
swiftfloat search 审查

# 删除
swiftfloat remove <id>
```

---

## 配置文件

### snippets.json

`~/.config/swiftfloat/snippets.json`

```json
{
  "default": [
    { "id": "1", "label": "帮我分析", "text": "请帮我分析以下内容：" }
  ],
  "com.tencent.qclaw": [
    { "id": "q1", "label": "深度思考", "text": "请深度思考以下问题，给出详细推理过程：" }
  ],
  "com.bytedance.lark": [
    { "id": "f1", "label": "周报", "text": "本周工作总结：\n1. " },
    { "id": "f2", "label": "会议纪要", "text": "会议纪要\n日期：\n参会人：\n议题：\n结论：" }
  ]
}
```

### actions.json

`~/.config/swiftfloat/actions.json`

```json
{
  "default": [
    { "id": "copy", "label": "复制", "actionType": "copy" },
    { "id": "translate", "label": "翻译", "actionType": "translate", "presetText": "请将以下内容翻译为中文：\n" },
    { "id": "quickAdd", "label": "快捷添加", "actionType": "quickAdd" }
  ]
}
```

---

## 剪贴板机制

- 粘贴前保存原剪贴板内容 → 写入提示词 → 模拟 Cmd+V → 2 秒后自动恢复
- 支持热加载：外部修改配置文件自动刷新，无需重启

---

## 权限要求

| 权限 | 用途 | 无权限时 |
|------|------|----------|
| 辅助功能（Accessibility） | AXObserver 读取输入框 | 弹窗引导设置，降级 CGEventTap |

---

## 构建

```bash
cd core/SwiftFloat
swift build
./.build/arm64-apple-macosx/debug/SwiftFloat
```

- Swift 5.9 / macOS 14.0+
- AppKit (NSPanel) / accessory 模式（无 Dock 图标，仅菜单栏）

---

## 注意事项

- 首次运行需授权**辅助功能权限**（系统设置 → 隐私与安全性 → 辅助功能）
- 权限不足时控制台输出 `kAXErrorCannotComplete`
