import ApplicationServices
import AppKit

// MARK: - FocusMonitor
// 轮询焦点 + AXObserver 监听选中文字变化

final class FocusMonitor {
    static let shared = FocusMonitor()

    private var pollTimer: Timer?
    private var isMonitoring = false
    private var lastFocusedElementID: CFHashCode?
    private var lastBundleID: String?
    private var lastFieldWasEmpty: Bool = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    var watchedApps: [String] = []
    var autoShowEnabled = true
    private var suppressHideUntil: Date = .distantPast

    // AXObserver 相关
    private var observedElement: AXUIElement?
    private var observer: AXObserver?
    private var observerRunSource: CFRunLoopSource?

    func suppressHide(seconds: TimeInterval) {
        suppressHideUntil = Date().addingTimeInterval(seconds)
    }

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
        autoShowEnabled = obj["autoShow"] as? Bool ?? true
        watchedApps = obj["apps"] as? [String] ?? []
        NSLog("[SwiftFloat] apps config loaded: autoShow=\(autoShowEnabled), apps=\(watchedApps)")
    }

    func reloadConfig() {
        loadConfig()
    }

    // MARK: - Start / Stop

    func start() {
        guard !isMonitoring else {
            NSLog("[SwiftFloat] FocusMonitor already running.")
            return
        }

        let trusted = AXIsProcessTrusted()
        NSLog("[SwiftFloat] AXIsProcessTrusted = \(trusted)")

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollFocus()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)

        isMonitoring = true
        NSLog("[SwiftFloat] FocusMonitor started (polling 0.3s + AXObserver).")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isMonitoring = false
        removeObserver()
    }

    // MARK: - Poll

    private func pollFocus() {
        guard autoShowEnabled else { return }

        if FloatWindowManager.shared.isVisible {
            let mouseLoc = NSEvent.mouseLocation
            if let winFrame = FloatWindowManager.shared.windowFrame, NSMouseInRect(mouseLoc, winFrame, false) {
                return
            }
        }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard err == .success, let element = focusedElement else {
            hideIfNeeded()
            removeObserver()
            return
        }

        var axElement = (element as! AXUIElement)

        // 🔧 Electron/Web 应用焦点穿透：如果直接焦点不是文本框，尝试在子元素中找
        var directRole: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &directRole)
        let directRoleStr = (directRole as? String) ?? ""
        var directSubrole: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &directSubrole)
        let directSubroleStr = (directSubrole as? String) ?? ""
        let directIsText = isTextInput(role: directRoleStr, subrole: directSubroleStr, element: axElement)

        // Electron 应用的 wrapper 元素列表
        let webWrapperRoles = ["AXGroup", "AXScrollArea", "AXWebArea"]
        let webWrapperSubroles = ["AXWebApplication", "AXWebArea"]

        if !directIsText && (webWrapperRoles.contains(directRoleStr) || webWrapperSubroles.contains(directSubroleStr)) {
            if let textField = findTextFieldIn(axElement, depth: 0) {
                var foundRole: CFTypeRef?
                AXUIElementCopyAttributeValue(textField, kAXRoleAttribute as CFString, &foundRole)
                NSLog("[SwiftFloat] findTextField: FOUND role=\(foundRole as? String ?? "?") in \(directRoleStr)")
                axElement = textField
            } else {
                NSLog("[SwiftFloat] findTextField: NOT FOUND in \(directRoleStr)")
            }
        }

        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        if elementPID == ownPID {
            return
        }

        let elementID = CFHash(axElement)

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        let roleStr = (role as? String) ?? "unknown"

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole)
        let subroleStr = (subrole as? String) ?? "none"

        let isText = isTextInput(role: roleStr, subrole: subroleStr, element: axElement)

        // 详细诊断日志：每个焦点都记录（但过滤自身 App）
        var focusPID: pid_t = 0
        AXUIElementGetPid(axElement, &focusPID)
        let focusBundleID = (focusPID > 0) ? (NSRunningApplication(processIdentifier: focusPID)?.bundleIdentifier ?? "unknown") : "unknown"
        if focusBundleID != "com.apple.SwiftFloat" && focusBundleID != "unknown" {
            NSLog("[SwiftFloat] pollFocus: bundle=\(focusBundleID) role=\(roleStr) subrole=\(subroleStr) isText=\(isText) pid=\(focusPID)")
        }

        if isText {
            var pid: pid_t = 0
            AXUIElementGetPid(axElement, &pid)
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"

            if !watchedApps.isEmpty && !watchedApps.contains(bundleID) {
                hideIfNeeded()
                removeObserver()
                return
            }

            // 读取输入框当前值（用于判断是否刚清空）
            let fieldText = getAXValue(axElement)
            let isEmpty = fieldText.isEmpty
            let elementChanged = elementID != lastFocusedElementID || bundleID != lastBundleID
            let emptied = (lastFocusedElementID == elementID) && !lastFieldWasEmpty

            // 显示条件：元素变化 或 刚清空
            if elementChanged || emptied {
                lastFocusedElementID = elementID
                lastBundleID = bundleID
                lastFieldWasEmpty = isEmpty

                SnippetStore.shared.switchApp(bundleID)

                let position = NSEvent.mouseLocation
                NSLog("[SwiftFloat] Focus: role=\(roleStr), app=\(bundleID), isEmpty=\(isEmpty), snippets=\(SnippetStore.shared.snippets.count)")
                FloatWindowManager.shared.show(at: position)
            }

            // 注册 selection 监听（每次都更新，确保监听正确的元素）
            installObserverForElement(axElement, id: elementID)
        } else {
            hideIfNeeded()
            removeObserver()
        }
    }

    private func hideIfNeeded() {
        if Date() < suppressHideUntil {
            return
        }

        if FloatWindowManager.shared.isVisible {
            lastFocusedElementID = nil
            lastBundleID = nil
            FloatWindowManager.shared.hide()
        }
    }

    // MARK: - AXObserver

    private func installObserverForElement(_ element: AXUIElement, id: CFHashCode) {
        // 同一元素不重复注册
        if observedElement != nil && CFHash(element) == id {
            return
        }

        removeObserver()

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var obs: AXObserver? = nil
        let result = AXObserverCreate(0, axObserverCallback, &obs)

        guard result == .success, let observer = obs else {
            NSLog("[SwiftFloat] AXObserverCreate failed: \(result.rawValue)")
            return
        }

        // 监听选中文字变化
        let notifResult = AXObserverAddNotification(
            observer,
            element,
            kAXSelectedTextChangedNotification as CFString,
            selfPtr
        )

        if notifResult != .success {
            NSLog("[SwiftFloat] AXObserverAddNotification failed: \(notifResult.rawValue)")
            return
        }

        // 添加到主 run loop（kCFRunLoopCommonModes 确保各种模式下都能触发）
        let runSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)

        observedElement = element
        self.observer = observer
        self.observerRunSource = runSource

        NSLog("[SwiftFloat] AXObserver installed for element \(id)")
    }

    private func removeObserver() {
        if let element = observedElement, let obs = observer {
            AXObserverRemoveNotification(obs, element, kAXSelectedTextChangedNotification as CFString)
        }
        if let source = observerRunSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        observedElement = nil
        observer = nil
        observerRunSource = nil
    }

    // MARK: - Text Input Detection

    private func isTextInput(role: String, subrole: String, element: AXUIElement) -> Bool {
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return true
        case "AXStaticText", "AXButton", "AXImage", "AXMenu", "AXMenuItem",
             "AXMenuBar", "AXMenuBarItem", "AXPopUpButton", "AXSplitGroup",
             "AXScrollArea", "AXGroup", "AXRow", "AXColumn", "AXTable",
             "AXList", "AXOutline", "AXBrowser", "AXTabGroup", "AXToolbar",
             "AXDrawer", "AXSheet", "AXDockItem", "AXLink", "AXSlider",
             "AXCheckBox", "AXRadioGroup", "AXRadioButton", "AXValueIndicator",
             "AXDisclosureTriangle", "AXGrid", "AXGrowArea", "AXHandle",
             "AXIncrementor", "AXLayoutArea", "AXLayoutItem", "AXLevelIndicator",
             "AXMatte", "AXPopover", "AXRatingIndicator", "AXRelevanceIndicator",
             "AXRuler", "AXRulerMarker", "AXTabButton", "AXTouchBar":
            return false
        default:
            break
        }

        var editable: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable)
        if err == .success, let val = editable as? Bool, val == true {
            return true
        }

        return false
    }

    /// 从 Electron/Web wrapper 元素递归查找文本输入框
    private func findTextFieldIn(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }  // 放宽深度限制

        var children: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard err == .success, let childArray = children as? [AXUIElement] else { return nil }

        if depth < 3 {
            NSLog("[SwiftFloat] findTextField: depth=\(depth), scanning \(childArray.count) children of \(element)")
        }

        for child in childArray {
            var role: CFTypeRef?
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
            let roleStr = (role as? String) ?? "?"
            let subroleStr = (subrole as? String) ?? "?"

            if depth < 2 {
                NSLog("[SwiftFloat] findTextField: child role=\(roleStr) subrole=\(subroleStr)")
            }

            // 直接可编辑的文本框
            if roleStr == "AXTextField" || roleStr == "AXTextArea" || roleStr == "AXComboBox" {
                var editable: CFTypeRef?
                AXUIElementCopyAttributeValue(child, "AXEditable" as CFString, &editable)
                if let val = editable as? Bool, val {
                    NSLog("[SwiftFloat] findTextField: ✅ FOUND AXEditable \(roleStr)")
                    return child
                }
            }

            // 可编辑的静态文本
            if roleStr == "AXStaticText" {
                var editable: CFTypeRef?
                AXUIElementCopyAttributeValue(child, "AXEditable" as CFString, &editable)
                if let val = editable as? Bool, val {
                    NSLog("[SwiftFloat] findTextField: ✅ FOUND AXEditable \(roleStr)")
                    return child
                }
            }

            // contenteditable div 通常没有 AXRole，用 AXValue 判断
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &value)
            if let str = value as? String, !str.isEmpty, roleStr != "?" {
                // 有值且有 role，考虑为可编辑
                NSLog("[SwiftFloat] findTextField: ✅ FOUND with value, role=\(roleStr) valueLen=\(str.count)")
                return child
            }

            // 递归搜索子元素
            if let found = findTextFieldIn(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - Read AX Value

    private func getAXValue(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if err == .success, let str = value as? String {
            return str
        }
        var selectedText: CFTypeRef?
        err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        if err == .success, let str = selectedText as? String {
            return str
        }
        return ""
    }

    /// 读取选中文字（供 AXObserver 回调和外部使用）
    func getSelectedText(from element: AXUIElement) -> String? {
        var selectedText: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        if err == .success, let text = selectedText as? String, !text.isEmpty {
            return text
        }
        return nil
    }
}

// MARK: - AXObserver Callback

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    context: UnsafeMutableRawPointer?
) {
    guard let ctx = context else { return }

    let monitor = Unmanaged<FocusMonitor>.fromOpaque(ctx).takeUnretainedValue()

    // 确保在主线程
    DispatchQueue.main.async {
        monitor.handleSelectionChanged(element: element)
    }
}

// MARK: - Selection Handler Extension

extension FocusMonitor {
    /// AXObserver 回调：选中文字变化时触发
    func handleSelectionChanged(element: AXUIElement) {
        guard autoShowEnabled else { return }

        // 跳过自身
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == ownPID { return }

        // 白名单检查
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        if !watchedApps.isEmpty && !watchedApps.contains(bundleID) { return }

        // 读取选中文字
        guard let selectedText = getSelectedText(from: element), !selectedText.isEmpty else {
            return
        }

        // 获取光标位置（用于定位悬浮框）
        var position: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)

        var mouseLoc = NSEvent.mouseLocation

        if posErr == .success, let posValue = position {
            var axPoint = CGPoint.zero
            if AXValueGetValue(posValue as! AXValue, .cgPoint, &axPoint) {
                // AX 坐标是屏幕坐标，直接使用
                mouseLoc = NSPoint(x: axPoint.x, y: axPoint.y)
            }
        }

        NSLog("[SwiftFloat] AXObserver selection: \"\(selectedText.prefix(30))...\" at (\(mouseLoc.x), \(mouseLoc.y))")

        // 阻止 FocusMonitor 隐藏 2 秒
        suppressHide(seconds: 2)

        // 显示悬浮框
        FloatWindowManager.shared.showForSelection(near: mouseLoc, selectedText: selectedText)
    }
}
