import AppKit
import Carbon.HIToolbox

// MARK: - Snippet Data Model

struct Snippet: Codable, Identifiable {
    let id: String
    let label: String
    let text: String
}

// MARK: - SnippetStore (支持按 App 分组)

final class SnippetStore {
    static let shared = SnippetStore()

    /// 按 bundleID 分组的 snippets,key = bundleID,"default" = 兜底
    private(set) var appSnippets: [String: [Snippet]] = [:]

    /// 当前激活的 App bundleID
    private(set) var currentApp: String = "default"

    /// 当前应显示的 snippets
    var snippets: [Snippet] {
        return appSnippets[currentApp] ?? appSnippets["default"] ?? []
    }

    /// 配置文件变更回调
    var onConfigChanged: (() -> Void)?

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileWatcherFD: Int32 = -1

    private init() {
        load()
        startFileWatcher()
    }

    private var configURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(".config/swiftfloat/snippets.json")
    }

    /// 切换当前 App,返回 snippets 是否有变化
    @discardableResult
    func switchApp(_ bundleID: String) -> Bool {
        let target = appSnippets[bundleID] != nil ? bundleID : "default"
        let changed = target != currentApp
        currentApp = target
        return changed
    }

    func load() {
        let url = configURL

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                // 尝试解析为按 App 分组的格式
                if let decoded = try? JSONDecoder().decode([String: [Snippet]].self, from: data) {
                    self.appSnippets = decoded
                    return
                }
                // 兼容旧格式(纯数组)
                if let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
                    self.appSnippets = ["default": decoded]
                    return
                }
            } catch {
                NSLog("[SwiftFloat] Load config failed: \(error)")
            }
        }

        // 内置默认
        self.appSnippets = Self.defaults
        ensureConfigDir()
    }

    func reload() {
        load()
    }

    /// 删除 snippet
    func removeSnippet(id: String) {
        let app = currentApp
        guard var list = appSnippets[app] else { return }
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count < before else { return }
        appSnippets[app] = list.isEmpty ? nil : list
        if list.isEmpty { appSnippets.removeValue(forKey: app) }
        save()
        onConfigChanged?()
        NSLog("[SwiftFloat] Removed snippet: \(id) from [\(app)]")
    }

    /// 更新 snippet
    func updateSnippet(id: String, label: String, text: String) {
        let app = currentApp
        guard var list = appSnippets[app] else { return }
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx] = Snippet(id: id, label: label, text: text)
        appSnippets[app] = list
        save()
        onConfigChanged?()
        NSLog("[SwiftFloat] Updated snippet: \(id) [\(label)]")
    }

    /// 新增 snippet 并持久化
    func addSnippet(label: String, text: String, app: String = "default") {
        let id = "s_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 100...999))"
        let newSnippet = Snippet(id: id, label: label, text: text)

        if appSnippets[app] != nil {
            appSnippets[app]!.append(newSnippet)
        } else {
            appSnippets[app] = [newSnippet]
        }

        save()
        onConfigChanged?()
        NSLog("[SwiftFloat] Added snippet: \(label) [\(id)] to [\(app)]") 
    }

    /// 持久化到磁盘
    private func save() {
        let url = configURL
        ensureConfigDir()
        do {
            let data = try JSONEncoder().encode(appSnippets)
            // 用原子写入防止半写
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[SwiftFloat] Save config failed: \(error)")
        }
    }

    // MARK: - File Watcher

    private func startFileWatcher() {
        let path = configURL.path
        fileWatcherFD = open(path, O_EVTONLY)
        guard fileWatcherFD >= 0 else {
            NSLog("[SwiftFloat] File watcher: cannot open \(path)")
            return
        }

        let queue = DispatchQueue(label: "com.swiftfloat.filewatcher", qos: .utility)
        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileWatcherFD,
            eventMask: .write,
            queue: queue
        )

        fileWatcher?.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                NSLog("[SwiftFloat] snippets.json changed, reloading...")
                self?.load()
                self?.onConfigChanged?()
            }
        }

        fileWatcher?.setCancelHandler { [weak self] in
            if let fd = self?.fileWatcherFD, fd >= 0 {
                close(fd)
            }
        }

        fileWatcher?.resume()
        NSLog("[SwiftFloat] File watcher started on \(path)")
    }

    deinit {
        fileWatcher?.cancel()
    }

    private func ensureConfigDir() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static let defaults: [String: [Snippet]] = [
        "default": [
            Snippet(id: "1", label: "帮我分析", text: "请帮我分析以下内容:"),
            Snippet(id: "2", label: "翻译", text: "请将以下内容翻译为中文:"),
            Snippet(id: "3", label: "总结", text: "请总结以下内容的要点:"),
            Snippet(id: "4", label: "代码审查", text: "请审查以下代码,指出潜在问题:"),
            Snippet(id: "5", label: "格式化", text: "请将以下内容格式化输出:"),
            Snippet(id: "6", label: "解释", text: "请解释以下概念:"),
        ],
        "com.tencent.qclaw": [
            Snippet(id: "q1", label: "帮我分析", text: "请帮我分析以下内容:"),
            Snippet(id: "q2", label: "总结", text: "请总结以下内容的要点:"),
            Snippet(id: "q3", label: "深度思考", text: "请深度思考以下问题,给出详细推理过程:"),
        ],
        "com.bytedance.lark": [
            Snippet(id: "f1", label: "周报", text: "本周工作总结:\n1. "),
            Snippet(id: "f2", label: "会议纪要", text: "会议纪要\n日期:\n参会人:\n议题:\n结论:"),
            Snippet(id: "f3", label: "反馈", text: "关于此事的反馈:\n优点:\n建议改进:"),
        ],
    ]
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupGlobalHotkey()
        startFocusMonitor()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "SwiftFloat")
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开悬浮球", action: #selector(showFloatPanel), keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "重新加载配置", action: #selector(reloadSnippets), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func statusItemClicked() {
        statusItem.button?.performClick(nil)
    }

    // MARK: - Global Hotkey (Cmd+Shift+Space)

    private func setupGlobalHotkey() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == kVK_Space {
                DispatchQueue.main.async {
                    self?.showFloatPanel()
                }
            }
        }
    }

    private func startFocusMonitor() {
        FocusMonitor.shared.start()

        // 选中文本监控
        SelectionMonitor.shared.start()

        // snippets.json 被外部修改时自动刷新 UI
        SnippetStore.shared.onConfigChanged = {
            FloatWindowManager.shared.rebuildIfNeeded()
            FocusMonitor.shared.reloadConfig()
        }
    }

    // MARK: - Actions

    @objc private func showFloatPanel() {
        FloatWindowManager.shared.toggle(at: NSEvent.mouseLocation)
    }

    @objc private func reloadSnippets() {
        SnippetStore.shared.reload()
        FocusMonitor.shared.reloadConfig()
        FloatWindowManager.shared.rebuildIfNeeded()
        NSLog("[SwiftFloat] Config reloaded. watchedApps=\(FocusMonitor.shared.watchedApps)")
    }
}
