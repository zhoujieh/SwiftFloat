import AppKit

// MARK: - SelectionAction
/// 划词模式下可执行的操作
struct SelectionAction: Identifiable, Codable {
    let id: String
    let label: String
    let icon: String
    let actionType: ActionType

    enum ActionType: String, Codable {
        case copy           // 复制到剪贴板
        case quickAdd      // 快捷添加到 snippet 库
        case translate     // 翻译提示词
        case insert       // 插入预设文本
    }

    // 预设文本（用于 insert / translate 类型）
    let presetText: String?
}

/// SelectionActionStore
/// 管理划词模式下的操作列表，支持按 App 分组配置
final class SelectionActionStore {
    static let shared = SelectionActionStore()

    private(set) var appActions: [String: [SelectionAction]] = [:]
    private(set) var currentApp: String = "default"

    /// 当前 App 的操作列表
    var actions: [SelectionAction] {
        return appActions[currentApp] ?? appActions["default"] ?? []
    }

    /// 切换 App
    func switchApp(_ bundleID: String) {
        currentApp = appActions[bundleID] != nil ? bundleID : "default"
    }

    private init() {
        load()
    }

    private func load() {
        let url = configURL

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                if let decoded = try? JSONDecoder().decode([String: [SelectionAction]].self, from: data) {
                    self.appActions = decoded
                    return
                }
            } catch {
                NSLog("[SelectionActionStore] Load failed: \(error)")
            }
        }

        self.appActions = Self.defaults
    }

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/swiftfloat/actions.json")
    }

    /// 默认操作列表
    private static let defaults: [String: [SelectionAction]] = [
        "default": [
            SelectionAction(id: "copy", label: "复制", icon: "doc.on.doc", actionType: .copy, presetText: nil),
            SelectionAction(id: "translate", label: "翻译", icon: "character.book.closed", actionType: .translate, presetText: "请将以下内容翻译为中文:\n"),
            SelectionAction(id: "quickAdd", label: "快捷添加", icon: "plus.circle", actionType: .quickAdd, presetText: nil),
        ],
        // QClaw 专属操作
        "com.tencent.qclaw": [
            SelectionAction(id: "copy", label: "复制", icon: "doc.on.doc", actionType: .copy, presetText: nil),
            SelectionAction(id: "translate", label: "翻译", icon: "character.book.closed", actionType: .translate, presetText: "请将以下内容翻译为中文:\n"),
            SelectionAction(id: "quickAdd", label: "快捷添加", icon: "plus.circle", actionType: .quickAdd, presetText: nil),
        ],
    ]
}