import ApplicationServices
import AppKit

// MARK: - SelectionMonitor
// 监听鼠标拖拽选中文本 → 在选区附近显示悬浮球

final class SelectionMonitor {
    static let shared = SelectionMonitor()

    private var mouseDownPoint: NSPoint?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isMonitoring = false

    var selectionShowEnabled = true
    private var watchedApps: [String] = []

    private init() {
        loadConfig()
    }

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/swiftfloat/apps.json")
    }

    private func loadConfig() {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        watchedApps = obj["apps"] as? [String] ?? []
        NSLog("[SwiftFloat] SelectionMonitor config: apps=\(watchedApps)")
    }

    func reloadConfig() { loadConfig() }

    /// 当前焦点 App 是否在白名单内（白名单为空 = 全部放行）
    private func isCurrentAppAllowed() -> Bool {
        guard !watchedApps.isEmpty else { return true }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard err == .success, let element = focusedElement else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid((element as! AXUIElement), &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return false }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        return watchedApps.contains(bundleID)
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // 全局监听（其他应用）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        // 本地监听（自身窗口内）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }

        NSLog("[SwiftFloat] SelectionMonitor started.")
    }

    func stop() {
        if let mon = globalMonitor {
            NSEvent.removeMonitor(mon)
            globalMonitor = nil
        }
        if let mon = localMonitor {
            NSEvent.removeMonitor(mon)
            localMonitor = nil
        }
        isMonitoring = false
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard selectionShowEnabled else { return }
        guard isCurrentAppAllowed() else { return }

        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = event.locationInWindow
            // 转换到屏幕坐标
            if let win = event.window {
                mouseDownPoint = win.convertPoint(toScreen: event.locationInWindow)
            } else {
                mouseDownPoint = NSEvent.mouseLocation
            }

        case .leftMouseUp:
            guard let startPoint = mouseDownPoint else { return }
            let endPoint = NSEvent.mouseLocation
            let isDoubleClick = (event.clickCount == 2)

            // 拖拽距离太小 且 不是双击 → 不是选择
            let dx = abs(endPoint.x - startPoint.x)
            let dy = abs(endPoint.y - startPoint.y)
            let isDrag = (dx > 10 || dy > 10)
            guard isDrag || isDoubleClick else {
                mouseDownPoint = nil
                return
            }

            mouseDownPoint = nil

            // 延迟一小段时间让文本选择完成（双击/三击时系统需要时间处理）
            let delay = isDoubleClick ? 0.05 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // 优先用 AX API 读取选中文本（不会误触发 Finder 文件选择）
                if let text = self.getSelectedText(), !text.isEmpty {
                    let pos = isDrag ? endPoint : NSEvent.mouseLocation
                    self.showSelectionBubble(near: pos, selected: text)
                    return
                }

                // 兜底：模拟 Cmd+C 获取（某些 App 不暴露 AXSelectedText）
                self.simulateCopy { selectedText in
                    if let text = selectedText, !text.isEmpty {
                        // 二次校验：确保焦点在文本元素上，不是文件/图标选择
                        if self.isFocusedElementText() {
                            self.showSelectionBubble(near: endPoint, selected: text)
                        }
                    }
                }
            }

        default:
            break
        }
    }

    /// 检查当前焦点元素是否是文本类
    private func isFocusedElementText() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard err == .success, let element = focusedElement else { return false }
        let axElement = element as! AXUIElement

        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return false }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        let roleStr = (role as? String) ?? ""

        // Finder 文件列表的 role 是 AXOutline/AXList/AXRow，不是文本
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXStaticText", "AXWebArea"]
        return textRoles.contains(roleStr)
    }

    private func getSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard err == .success, let element = focusedElement else { return nil }

        let axElement = element as! AXUIElement

        // 跳过自身
        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        // 检查是否是文本元素
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        let roleStr = (role as? String) ?? ""

        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXStaticText"]
        guard textRoles.contains(roleStr) else { return nil }

        // 获取选中文本
        var selectedText: CFTypeRef?
        let err2 = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        guard err2 == .success, let text = selectedText as? String, !text.isEmpty else {
            return nil
        }

        return text
    }

    private func showSelectionBubble(near point: NSPoint, selected: String?) {
        // 不在自身窗口上方显示
        if FloatWindowManager.shared.isVisible {
            let mouseLoc = NSEvent.mouseLocation
            if let winFrame = FloatWindowManager.shared.windowFrame,
               NSMouseInRect(mouseLoc, winFrame, false) {
                return
            }
        }

        NSLog("[SwiftFloat] Selection detected, showing bubble at (\(point.x), \(point.y))")

        // 阻止 FocusMonitor 隐藏悬浮球 2 秒
        FocusMonitor.shared.suppressHide(seconds: 2)

        // 获取当前 App bundle ID
        var bundleID = "default"
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if err == .success, let element = focusedElement {
            var pid: pid_t = 0
            AXUIElementGetPid((element as! AXUIElement), &pid)
            bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "default"
        }

        // 显示悬浮球
        FloatWindowManager.shared.showForSelection(near: point, selectedText: selected, bundleID: bundleID)
    }

    // 模拟 Cmd+C 获取选中文本
    private func simulateCopy(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        pasteboard.clearContents()

        // 模拟 Cmd+C
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // 等待剪贴板更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let copied = pasteboard.string(forType: .string)
            
            // 恢复剪贴板
            if let saved = savedString {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
            
            completion(copied)
        }
    }
}