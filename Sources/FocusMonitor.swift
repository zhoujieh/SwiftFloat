import ApplicationServices
import AppKit

// MARK: - FocusMonitor
// 检测两种场景显示悬浮框：
// 1. 划词选中文本 → 显示
// 2. 输入框只有 "/" → 显示（slash command 模式）
// 其他情况 → 隐藏

final class FocusMonitor {
    static let shared = FocusMonitor()

    private var pollTimer: Timer?
    private var isMonitoring = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    var watchedApps: [String] = []
    private var suppressHideUntil: Date = .distantPast

    // AXObserver 相关
    private var observedElement: AXUIElement?
    private var observer: AXObserver?
    private var observerRunSource: CFRunLoopSource?

    // CGEvent tap（Electron 应用 AX 不可用时检测 "/" 键）
    private var keyEventTap: CFMachPort?
    private var keyEventRunSource: CFRunLoopSource?
    // Electron slash 模式：记录按 "/" 后输入的其他字符数
    private var slashModeExtraChars: Int = 0

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
        watchedApps = obj["apps"] as? [String] ?? []
        NSLog("[SwiftFloat] apps config loaded: apps=\(watchedApps)")
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

        // 启动 CGEvent tap（用于 Electron 应用）
        startKeyEventTap()

        isMonitoring = true
        NSLog("[SwiftFloat] FocusMonitor started (polling 0.3s + CGEventTap).")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isMonitoring = false
        removeObserver()
        stopKeyEventTap()
    }

    // MARK: - CGEvent Tap (for Electron apps)

    private func startKeyEventTap() {
        guard keyEventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: keyEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[SwiftFloat] CGEventTapCreate failed - need accessibility permission")
            return
        }

        keyEventTap = tap
        let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyEventRunSource = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSLog("[SwiftFloat] CGEvent tap started for keyDown events")
    }

    private func stopKeyEventTap() {
        if let tap = keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = keyEventRunSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        keyEventTap = nil
        keyEventRunSource = nil
    }

    /// CGEvent tap 回调：检测 "/" 键（Electron 应用用）
    /// 接收从 keyEventCallback 同步提取的 keyCode 和 chars，避免异步引用 CGEvent
    func handleKeyEvent(keyCode: Int64, chars: String) {
        let activeApp = NSWorkspace.shared.frontmostApplication
        let bundleID = activeApp?.bundleIdentifier ?? "unknown"

        guard watchedApps.contains(bundleID) else { return }

        // 检测 "/" 键
        if chars == "/" || keyCode == 44 {
            NSLog("[SwiftFloat] Slash key detected in \(bundleID) (Electron)")
            slashModeExtraChars = 0
            let position = NSEvent.mouseLocation
            SnippetStore.shared.switchApp(bundleID)
            FloatWindowManager.shared.showForSlash(at: position, bundleID: bundleID)
            return
        }

        // slash 模式下按了其他键
        if FloatWindowManager.shared.isSlashMode {
            // 退格键 (keyCode 51)：减少字符数，如果回退到只有 "/" 则重新显示
            if keyCode == 51 {
                slashModeExtraChars = max(0, slashModeExtraChars - 1)
                if slashModeExtraChars == 0 {
                    // 回到只有 "/" 的状态，重新显示
                    let position = NSEvent.mouseLocation
                    FloatWindowManager.shared.showForSlash(at: position, bundleID: bundleID)
                }
                return
            }

            // 其他可打印键：字段不再只有 "/"，隐藏
            if !chars.isEmpty {
                slashModeExtraChars += 1
                NSLog("[SwiftFloat] Extra char after slash, hiding (extraChars=\(slashModeExtraChars))")
                FloatWindowManager.shared.hide()
            }
        }
    }

    // MARK: - Poll

    private func pollFocus() {
        // 如果鼠标在悬浮框上，不做处理
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
            // AX API 失败（Electron 等）— 由 CGEvent tap 处理
            let activeApp = NSWorkspace.shared.frontmostApplication
            let bundleID = activeApp?.bundleIdentifier ?? "unknown"

            if !watchedApps.contains(bundleID) {
                // 非白名单应用 → 隐藏
                hideIfNeeded()
            }
            // 白名单 Electron 应用：由 CGEvent tap 控制，这里不干预
            removeObserver()
            return
        }

        let axElement = (element as! AXUIElement)

        // 跳过自身
        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        if elementPID == ownPID {
            return
        }

        // 白名单检查
        let bundleID = NSRunningApplication(processIdentifier: elementPID)?.bundleIdentifier ?? "unknown"
        if !watchedApps.isEmpty && !watchedApps.contains(bundleID) {
            hideIfNeeded()
            removeObserver()
            return
        }

        // 检查是否有选中文本
        var selectedText: CFTypeRef?
        let selErr = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedText)

        if selErr == .success, let text = selectedText as? String, !text.isEmpty {
            // 有选中文本 → 显示悬浮框
            NSLog("[SwiftFloat] pollFocus: selection found '\(text.prefix(30))' in \(bundleID)")

            if !FloatWindowManager.shared.isVisible {
                let position = NSEvent.mouseLocation
                SnippetStore.shared.switchApp(bundleID)
                FloatWindowManager.shared.showForSelection(near: position, selectedText: text, bundleID: bundleID)
            }
        } else {
            // 无选中文本，检查输入框是否只有 "/"
            let fieldText = getAXValue(axElement)
            if fieldText == "/" {
                // 输入框恰好只有 "/" → 显示（slash command 模式）
                NSLog("[SwiftFloat] pollFocus: slash-only detected in \(bundleID)")
                if !FloatWindowManager.shared.isVisible {
                    let position = NSEvent.mouseLocation
                    SnippetStore.shared.switchApp(bundleID)
                    FloatWindowManager.shared.showForSlash(at: position, bundleID: bundleID)
                }
            } else {
                // 无选中且字段不是只有 "/" → 隐藏
                hideIfNeeded()
            }
        }

        // 注册 AXObserver 监听选中/值变化
        installObserverForElement(axElement, id: CFHash(axElement))
    }

    private func hideIfNeeded() {
        if Date() < suppressHideUntil {
            return
        }

        if FloatWindowManager.shared.isVisible {
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

        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)

        var obs: AXObserver? = nil
        let result = AXObserverCreate(elementPID, axObserverCallback, &obs)

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

        // 监听值变化（检测 "/" 输入）
        let valueNotifResult = AXObserverAddNotification(
            observer,
            element,
            kAXValueChangedNotification as CFString,
            selfPtr
        )
        if valueNotifResult != .success {
            NSLog("[SwiftFloat] AXObserverAddNotification (valueChanged) failed: \(valueNotifResult.rawValue)")
        }

        // 添加到主 run loop
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
            AXObserverRemoveNotification(obs, element, kAXValueChangedNotification as CFString)
        }
        if let source = observerRunSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        observedElement = nil
        observer = nil
        observerRunSource = nil
    }

    /// 读取选中文字
    func getSelectedText(from element: AXUIElement) -> String? {
        var selectedText: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        if err == .success, let text = selectedText as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// 读取输入框值（仅 kAXValueAttribute，不 fallback 到 selectedText）
    private func getAXValue(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if err == .success, let str = value as? String {
            return str
        }
        // 不 fallback 到 kAXSelectedTextAttribute：selectedText 是选中的子串，不是字段值
        // AX 获取字段值失败时返回空字符串，Electron 应用由 CGEvent tap 处理
        return ""
    }
}

// MARK: - CGEvent Tap Callback

private func keyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

    let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .keyDown {
        // 同步提取值，避免异步引用 CGEvent 导致悬垂引用
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        DispatchQueue.main.async {
            monitor.handleKeyEvent(keyCode: keyCode, chars: chars)
        }
    }

    return Unmanaged.passUnretained(event)
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

    DispatchQueue.main.async {
        monitor.handleAXNotification(element: element, notification: notification as String)
    }
}

// MARK: - AX Notification Handler

extension FocusMonitor {
    func handleAXNotification(element: AXUIElement, notification: String) {
        // 跳过自身
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == ownPID { return }

        // 白名单检查
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        if !watchedApps.isEmpty && !watchedApps.contains(bundleID) { return }

        switch notification {
        case kAXSelectedTextChangedNotification as String:
            handleSelectionChanged(element: element)
        case kAXValueChangedNotification as String:
            handleValueChanged(element: element, bundleID: bundleID)
        default:
            break
        }
    }

    private func handleSelectionChanged(element: AXUIElement) {
        guard let selectedText = getSelectedText(from: element), !selectedText.isEmpty else {
            // 选中文字消失 → 隐藏
            hideIfNeeded()
            return
        }

        var position: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)

        var mouseLoc = NSEvent.mouseLocation

        if posErr == .success, let posValue = position {
            var axPoint = CGPoint.zero
            if AXValueGetValue(posValue as! AXValue, .cgPoint, &axPoint) {
                mouseLoc = NSPoint(x: axPoint.x, y: axPoint.y)
            }
        }

        NSLog("[SwiftFloat] AXObserver selection: \"\(selectedText.prefix(30))\" at (\(mouseLoc.x), \(mouseLoc.y))")

        suppressHide(seconds: 2)

        FloatWindowManager.shared.showForSelection(near: mouseLoc, selectedText: selectedText)
    }

    private func handleValueChanged(element: AXUIElement, bundleID: String) {
        let fieldText = getAXValue(element)

        if fieldText == "/" {
            // 输入框恰好只有 "/" → 显示
            NSLog("[SwiftFloat] AXObserver: slash-only detected in \(bundleID)")
            let position = NSEvent.mouseLocation
            SnippetStore.shared.switchApp(bundleID)
            FloatWindowManager.shared.showForSlash(at: position, bundleID: bundleID)
        } else if FloatWindowManager.shared.isSlashMode {
            // 字段不再只有 "/" → 隐藏
            NSLog("[SwiftFloat] AXObserver: field no longer slash-only, hiding. text='\(fieldText.prefix(20))'")
            hideIfNeeded()
        }
    }
}
