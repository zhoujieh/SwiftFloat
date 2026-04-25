import ApplicationServices
import AppKit

// MARK: - TriggerEvent

/// 输入事件的统一封装
enum TriggerType {
    case slash     // 输入框只有 "/"
    case selection // 选中了文本
}

struct TriggerContext {
    let type: TriggerType
    let bundleID: String
    let position: NSPoint
    let selectedText: String?
    let element: AXUIElement?  // AX 路径才有，CGEvent 路径为 nil
}

// MARK: - InputContext
/// 统一输入层：合并 FocusMonitor + SelectionMonitor
/// - AXObserver: 优先，完整上下文（能读输入框内容）
/// - CGEventTap: Electron fallback，只知道按键，不知输入框完整内容
/// - 状态重置: 切换 App 时自动清空 slash 状态
/// 两种触发路径统一通过 onTrigger(_:) 派发

final class InputContext {
    static let shared = InputContext()

    // MARK: - Callbacks

    /// 统一触发回调（由 FloatWindowManager 订阅）
    var onTrigger: ((TriggerContext) -> Void)?

    // MARK: - State

    private var currentApp: String = ""
    private var slashState: SlashState = .idle
    private var isMonitoring = false

    /// slash 模式下的状态机
    private enum SlashState {
        case idle
        case slashDetected  // 检测到 "/"，等待后续输入
        case active       // 面板已显示，用户正在输入
    }

    /// slash 模式下用户已输入的额外字符数（用于判断是否退回 idle）
    private var extraCharsAfterSlash: Int = 0

    /// 记录之前的输入框文本（用于判断「从空→/」触发）
    private var previousFieldText: String = ""

    /// CGEvent 路径专用：记录 "/" 触发前输入框是否为空
    /// 解决 Electron 无法用 AX 读取时的触发判断
    private var preSlashFieldWasEmpty: Bool = true

    /// 记录焦点元素的哈希（区分不同输入框）
    private var focusedElementHash: Int = 0

    /// CGEvent 路径：记录焦点变化后按下的非修饰键数（用于 Electron 判断 "/" 是否首键）
    private var keysPressedSinceFocus: Int = 0

    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    // AX Observer
    private var observedElement: AXUIElement?
    private var observer: AXObserver?
    private var observerRunSource: CFRunLoopSource?

    // CGEvent tap
    private var keyEventTap: CFMachPort?
    private var keyEventRunSource: CFRunLoopSource?

    // Mouse monitor (用于划词)
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseDownPoint: NSPoint?

    // Poll timer
    private var pollTimer: Timer?

    private init() {}

    // MARK: - Start / Stop

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let trusted = AXIsProcessTrusted()
        NSLog("[InputContext] AXIsProcessTrusted = \(trusted)")

        if !trusted {
            // 权限不足时，弹出系统偏好设置引导用户授权
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "SwiftFloat 需要辅助功能权限来监控输入框。\n\n请在「系统偏好设置 → 隐私与安全性 → 辅助功能」中添加 SwiftFloat，然后重新启动应用。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统偏好设置")
            alert.addButton(withTitle: "稍后")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
            // 仍启动 CGEvent tap 作为降级方案
            NSLog("[InputContext] Running without accessibility — CGEvent tap only")
        }

        // 轮询兜底：每 0.3s 检查焦点（当 AXObserver 失效时补救）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollFocus()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)

        // CGEvent tap：Electron 应用的键盘输入
        startKeyEventTap()

        // 鼠标监听：选中文本后显示
        startMouseMonitor()

        NSLog("[InputContext] started.")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        stopKeyEventTap()
        stopMouseMonitor()
        removeObserver()

        isMonitoring = false
        slashState = .idle
        currentApp = ""
        NSLog("[InputContext] stopped.")
    }

    // MARK: - App Switching

    /// 切换 App 时重置状态
    private func switchAppIfNeeded(_ bundleID: String) {
        guard bundleID != currentApp else { return }
        currentApp = bundleID
        // 切换 App → 重置 slash 状态（这是关键！ISSUE #4 根因）
        if slashState != .idle {
            NSLog("[InputContext] App switched from slash mode, resetting. bundleID=\(bundleID)")
        }
        slashState = .idle
        extraCharsAfterSlash = 0
        previousFieldText = ""
        preSlashFieldWasEmpty = true
        focusedElementHash = 0
        keysPressedSinceFocus = 0
    }

    // MARK: - AX Observer

    private func installObserverForElement(_ element: AXUIElement) {
        // 同一元素不重复注册
        if let observed = observedElement, CFHash(element) == CFHash(observed) {
            return
        }

        removeObserver()

        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)
        guard elementPID != ownPID else { return }

        // 新元素 → 读取当前值作为基准状态
        focusedElementHash = Int(CFHash(element))
        previousFieldText = readFieldText(from: element)
        preSlashFieldWasEmpty = previousFieldText.isEmpty
        keysPressedSinceFocus = 0
        NSLog("[InputContext] installObserver: new element, previousFieldText='\(previousFieldText.prefix(20))', preSlashWasEmpty=\(preSlashFieldWasEmpty)")

        var obs: AXObserver? = nil
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverCreate(elementPID, axObserverCallback, &obs)

        guard result == .success, let observer = obs else {
            NSLog("[InputContext] AXObserverCreate failed: \(result.rawValue)")
            return
        }

        // 监听选中文本变化
        if AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, selfPtr) != .success {
            NSLog("[InputContext] AXObserverAddNotification failed (selectedTextChanged)")
        }

        // 监听值变化（检测 "/" 输入）
        if AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, selfPtr) != .success {
            NSLog("[InputContext] AXObserverAddNotification failed (valueChanged)")
        }

        let runSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)

        observedElement = element
        self.observer = observer
        self.observerRunSource = runSource

        NSLog("[InputContext] AXObserver installed.")
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

    // MARK: - Trigger Handler

    private func dispatch(_ context: TriggerContext) {
        DispatchQueue.main.async { [weak self] in
            // 切换 App 时重置状态
            self?.switchAppIfNeeded(context.bundleID)
            self?.onTrigger?(context)
        }
    }

    // MARK: - Slash Detection

    /// 读取焦点元素的完整值（仅 kAXValueAttribute）
    private func readFieldText(from element: AXUIElement) -> String {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if err == .success, let str = value as? String {
            return str
        }
        return ""
    }

    /// 读取选中文本
    private func readSelectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        if err == .success, let text = value as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// 检查焦点元素是否是文本输入框（划词时不显示悬浮框）
    private func isTextInputElement(_ element: AXUIElement) -> Bool {
        let roleStr = getElementRole(element)

        // AXStaticText 是静态文本（如网页正文），不算输入框
        let textInputRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        return textInputRoles.contains(roleStr)
    }

    /// 获取元素角色
    private func getElementRole(_ element: AXUIElement) -> String {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) ?? ""
    }

    /// 检查焦点元素是否是 WebArea（网页内容区，可以响应）
    private func isWebArea(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = (role as? String) ?? ""
        return roleStr == "AXWebArea"
    }

    /// AX Observer 回调派发
    fileprivate func handleAXNotification(element: AXUIElement, notification: String) {
        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)
        guard elementPID != ownPID else { return }

        let bundleID = NSRunningApplication(processIdentifier: elementPID)?.bundleIdentifier ?? ""

        // 白名单检查
        if !SnippetStore.shared.watchedApps.isEmpty && !SnippetStore.shared.watchedApps.contains(bundleID) {
            return
        }

        // 严格角色检查：非文本输入元素跳过
        if !isTextInputElement(element) && !isWebArea(element) {
            return
        }

        switch notification {
        case kAXSelectedTextChangedNotification as String:
            handleSelectionChanged(element: element, bundleID: bundleID)

        case kAXValueChangedNotification as String:
            handleValueChanged(element: element, bundleID: bundleID)

        default:
            break
        }
    }

    private func handleSelectionChanged(element: AXUIElement, bundleID: String) {
        guard let text = readSelectedText(from: element), !text.isEmpty else {
            // 选中文字消失 → 不派发（由 FloatWindowManager 决定是否隐藏）
            return
        }

        // 输入框内划词不显示悬浮框（避免干扰正常编辑）
        if isTextInputElement(element) {
            NSLog("[InputContext] selection in text input, skipped. role=\(getElementRole(element))")
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

        let context = TriggerContext(
            type: .selection,
            bundleID: bundleID,
            position: mouseLoc,
            selectedText: text,
            element: element
        )

        NSLog("[InputContext] selection: '\(text.prefix(20))' bundleID=\(bundleID)")
        dispatch(context)
    }

    private func handleValueChanged(element: AXUIElement, bundleID: String) {
        let fieldText = readFieldText(from: element)

        switch slashState {
        case .idle:
            // 严格判断：只有「之前为空」+「现在只有 /」时才触发
            // 即：空输入框 → 输入 "/" 才显示
            // 从 "abc" 删除到 "/" → 不显示（previousFieldText 不为空）
            if fieldText == "/" && previousFieldText.isEmpty {
                NSLog("[InputContext] slash detected (empty→/). previous='\(previousFieldText)', current='/'. bundleID=\(bundleID)")
                slashState = .slashDetected
                extraCharsAfterSlash = 0

                let context = TriggerContext(
                    type: .slash,
                    bundleID: bundleID,
                    position: NSEvent.mouseLocation,
                    selectedText: nil,
                    element: element
                )
                dispatch(context)
            }

        case .slashDetected, .active:
            // 面板已显示 → 检查输入框状态
            if fieldText.isEmpty {
                // 输入框空了 → 退回 idle
                slashState = .idle
                extraCharsAfterSlash = 0
            } else if fieldText != "/" {
                // 有其他字符 → 退回 idle（FloatWindowManager 隐藏面板）
                slashState = .idle
                extraCharsAfterSlash = 0
            }
            // 如果 fieldText == "/" 且面板已显示 → 保持状态，不重置
        }

        // 更新之前的状态（用于下次判断）
        previousFieldText = fieldText
    }

    // MARK: - Poll (AX fallback)

    private func pollFocus() {
        // 不轮询时跳过（窗口显示时暂定轮询，优化后续加）
        guard isMonitoring else { return }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard err == .success, let element = focusedElement else {
            // AX API 失败 → Electron 应用由 CGEventTap 处理
            return
        }

        let axElement = element as! AXUIElement
        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        if elementPID == ownPID { return }

        let bundleID = NSRunningApplication(processIdentifier: elementPID)?.bundleIdentifier ?? ""

        // 白名单检查
        if !SnippetStore.shared.watchedApps.isEmpty && !SnippetStore.shared.watchedApps.contains(bundleID) {
            return
        }

        // 跟踪焦点元素变化：切换元素时更新 previousFieldText
        let currentHash = Int(CFHash(axElement))
        if currentHash != focusedElementHash {
            // 焦点切换到新元素 → 读取当前值作为基准
            focusedElementHash = currentHash
            previousFieldText = readFieldText(from: axElement)
            preSlashFieldWasEmpty = previousFieldText.isEmpty
            NSLog("[InputContext] pollFocus: element changed, previousFieldText='\(previousFieldText.prefix(20))', preSlashWasEmpty=\(preSlashFieldWasEmpty)")
        }

        // 注册 AXObserver 监听变化
        installObserverForElement(axElement)
    }

    // MARK: - CGEvent Tap (Electron fallback)

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
            NSLog("[InputContext] CGEventTapCreate failed - need accessibility permission")
            return
        }

        keyEventTap = tap
        let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyEventRunSource = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSLog("[InputContext] CGEvent tap started.")
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

    /// CGEvent 回调：Electron 应用无法用 AX 获取输入框内容时，通过 CGEvent 检测 "/"
    /// 注意：CGEvent 只知道按键，不知道输入框完整内容 → 优先用 AX 读取，fallback 到按键计数
    fileprivate func handleKeyEvent(keyCode: Int64, chars: String) {
        let activeApp = NSWorkspace.shared.frontmostApplication
        let bundleID = activeApp?.bundleIdentifier ?? ""

        guard SnippetStore.shared.watchedApps.contains(bundleID) else { return }

        // 尝试通过 AX 读取输入框当前内容（更可靠）
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let axErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        var axFieldText: String? = nil

        if axErr == .success, let element = focusedElement {
            let axElement = element as! AXUIElement
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                axFieldText = text
            }
        }

        // "/" 键检测
        if chars == "/" || keyCode == 44 {
            NSLog("[InputContext] slash key via CGEvent: bundleID=\(bundleID), axFieldText=\(axFieldText ?? "nil"), previousFieldText='\(previousFieldText)', preSlashWasEmpty=\(preSlashFieldWasEmpty), keysPressed=\(keysPressedSinceFocus)")

            // 严格判断：只有「之前为空」+「当前只有 /」才触发
            if let currentText = axFieldText {
                // AX 能读到值 → 用 AX 值判断
                if currentText == "/" && preSlashFieldWasEmpty {
                    previousFieldText = currentText
                    preSlashFieldWasEmpty = false  // 已有内容，不再为空
                    NSLog("[InputContext] slash triggered via CGEvent+AX (empty→/)")
                    let context = TriggerContext(
                        type: .slash,
                        bundleID: bundleID,
                        position: NSEvent.mouseLocation,
                        selectedText: nil,
                        element: nil
                    )
                    dispatch(context)
                    return
                } else {
                    NSLog("[InputContext] slash skipped via CGEvent+AX: current='\(currentText)', preSlashWasEmpty=\(preSlashFieldWasEmpty)")
                    // 更新状态
                    previousFieldText = currentText
                    preSlashFieldWasEmpty = currentText.isEmpty
                    return
                }
            }

            // AX 读不到值 → 用 preSlashFieldWasEmpty 标志判断
            // 只有「焦点进入时为空」+「没有按过其他键」才触发
            if !preSlashFieldWasEmpty {
                NSLog("[InputContext] slash skipped: preSlashFieldWasEmpty=false (field was not empty before)")
                return
            }

            if keysPressedSinceFocus > 0 {
                NSLog("[InputContext] slash skipped: non-first key (keys pressed=\(keysPressedSinceFocus))")
                return
            }

            NSLog("[InputContext] slash triggered via CGEvent only (no AX, empty field, first key)")
            preSlashFieldWasEmpty = false  // 触发后标记为非空
            let context = TriggerContext(
                type: .slash,
                bundleID: bundleID,
                position: NSEvent.mouseLocation,
                selectedText: nil,
                element: nil
            )
            dispatch(context)
            return
        }

        // 记录非修饰键的输入（用于判断 "/" 是否首键）
        let isModifierKey = (keyCode >= 54 && keyCode <= 62)
        if !isModifierKey && !chars.isEmpty {
            keysPressedSinceFocus += 1
            // 按了非 "/" 键 → 输入框不再为空
            if preSlashFieldWasEmpty {
                preSlashFieldWasEmpty = false
                NSLog("[InputContext] non-slash key pressed, preSlashFieldWasEmpty → false")
            }
        }

        // slash 模式下其他键处理
        if slashState == .slashDetected || slashState == .active {
            if !chars.isEmpty && chars.first?.isASCII == true {
                slashState = .idle
                extraCharsAfterSlash = 0
            }
        }
    }

    // MARK: - Mouse Monitor (划词)

    private func startMouseMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func stopMouseMonitor() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let win = event.window {
                mouseDownPoint = win.convertPoint(toScreen: event.locationInWindow)
            } else {
                mouseDownPoint = NSEvent.mouseLocation
            }

        case .leftMouseUp:
            guard let startPoint = mouseDownPoint else { return }
            mouseDownPoint = nil

            let endPoint = NSEvent.mouseLocation
            let isDoubleClick = event.clickCount == 2

            let dx = abs(endPoint.x - startPoint.x)
            let dy = abs(endPoint.y - startPoint.y)
            let isDrag = dx > 10 || dy > 10

            if !isDrag && !isDoubleClick {
                return  // 单击 → 不是选中文本操作
            }

            // 延迟等待选中文本完成
            let delay = isDoubleClick ? 0.1 : 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.triggerSelectionAtPoint(endPoint)
            }

        default:
            break
        }
    }

    /// 在指定点触发划词事件（优先 AX，fallback simulateCopy）
    private func triggerSelectionAtPoint(_ point: NSPoint) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard err == .success, let element = focusedElement else {
            simulateCopyAtPoint(point)
            return
        }

        let axElement = element as! AXUIElement
        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        if elementPID == ownPID { return }

        // 输入框内划词不显示悬浮框
        if isTextInputElement(axElement) {
            NSLog("[InputContext] triggerSelectionAtPoint: in text input, skipped. role=\(getElementRole(axElement))")
            return
        }

        if let text = readSelectedText(from: axElement), !text.isEmpty {
            let bundleID = NSRunningApplication(processIdentifier: elementPID)?.bundleIdentifier ?? ""
            let context = TriggerContext(
                type: .selection,
                bundleID: bundleID,
                position: point,
                selectedText: text,
                element: axElement
            )
            dispatch(context)
        } else {
            simulateCopyAtPoint(point)
        }
    }

    /// simulateCopy fallback
    private func simulateCopyAtPoint(_ point: NSPoint) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "default"
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        pasteboard.clearContents()

        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let copied = pasteboard.string(forType: .string)

            if let restored = savedString {
                pasteboard.clearContents()
                pasteboard.setString(restored, forType: .string)
            }

            if let text = copied, !text.isEmpty {
                let context = TriggerContext(
                    type: .selection,
                    bundleID: bundleID,
                    position: point,
                    selectedText: text,
                    element: nil
                )
                self?.dispatch(context)
            }
        }
    }
}

// MARK: - CGEvent Callback

private func keyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

    let monitor = Unmanaged<InputContext>.fromOpaque(refcon).takeUnretainedValue()

    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        monitor.handleKeyEvent(keyCode: keyCode, chars: chars)
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
    let monitor = Unmanaged<InputContext>.fromOpaque(ctx).takeUnretainedValue()
    monitor.handleAXNotification(element: element, notification: notification as String)
}