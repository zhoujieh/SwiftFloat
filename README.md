# SwiftFloat — 快捷文本悬浮球

macOS 原生悬浮工具，在任何文本输入框激活时自动弹出，提供点击即粘贴的快捷文本功能。

## 功能特性

- **自动弹出**：检测到文本输入框时在光标附近显示悬浮球
- **快捷键呼出**：`Cmd+Shift+Space` 手动切换悬浮球
- **按 App 分组**：不同 App 显示不同的快捷文本
- **内联录入**：直接在悬浮球内新增快捷文本
- **热加载**：配置文件变更自动刷新，无需重启
- **CLI 管理**：`swiftfloat add/list/remove/search` 任意 Agent 远程管理

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+Shift+Space` | 显示/隐藏悬浮球 |
| `ESC` | 关闭悬浮球 |
| `回车` | 确认保存（新增表单中） |

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

## 配置文件

`~/.config/swiftfloat/snippets.json`

```json
{
  "default": [
    { "id": "1", "label": "帮我分析", "text": "请帮我分析以下内容：" }
  ],
  "com.tencent.qclaw": [
    { "id": "q1", "label": "深度思考", "text": "请深度思考以下问题，给出详细推理过程：" }
  ]
}
```

## 构建

```bash
cd core/SwiftFloat
swift build
./.build/arm64-apple-macosx/debug/SwiftFloat
```

## 注意事项

- 首次运行需要授权辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）
- 权限问题会导致焦点检测失败，控制台输出 `kAXErrorCannotComplete`