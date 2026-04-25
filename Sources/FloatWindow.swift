import AppKit
import ApplicationServices

// MARK: - FloatWindow

final class FloatWindow: NSPanel {
    private var selectedText: String?
    var currentBundleID: String = "default"
    private var escapeMonitor: Any?
    private let container = NSView()

    // 当前显示模式
    private enum DisplayMode {
        case slash       // slash command → snippet 列表
        case selection   // 划词 → 操作列表
    }
    private var displayMode: DisplayMode = .slash

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        self.level = .init(rawValue: Int(CGWindowLevelForKey(.floatingWindow))) + 1
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.hidesOnDeactivate = false

        setupContentView()
        setupCancelHandlers()
    }

    private func setupCancelHandlers() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Escape
                DispatchQueue.main.async {
                    FloatWindowManager.shared.hide()
                }
                return nil
            }
            return event
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func setupContentView() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 10
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        contentView.addSubview(container)
    }

    // MARK: - Build Slash View (snippet 列表)

    func buildSlashView() {
        displayMode = .slash
        container.subviews.forEach { $0.removeFromSuperview() }

        let snippets = SnippetStore.shared.snippets
        let windowW: CGFloat = 240
        let paddingX: CGFloat = 8
        let paddingY: CGFloat = 6
        let rowH: CGFloat = 28
        let spacing: CGFloat = 2
        let contentW = windowW - paddingX * 2

        var y = paddingY

        // 标题行
        let titleLabel = NSTextField(labelWithString: "快捷文本")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.sizeToFit()
        titleLabel.setFrameOrigin(NSPoint(x: paddingX, y: y + 3))
        container.addSubview(titleLabel)

        let closeBtn = NSButton(title: "✕", target: self, action: #selector(hideWindow))
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.font = NSFont.systemFont(ofSize: 12)
        closeBtn.contentTintColor = .tertiaryLabelColor
        closeBtn.sizeToFit()
        closeBtn.setFrameOrigin(NSPoint(x: windowW - paddingX - closeBtn.frame.width - 4, y: y))
        container.addSubview(closeBtn)

        y += 20

        // 分隔线
        let separator = NSView(frame: NSRect(x: paddingX, y: y, width: contentW, height: 0.5))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(separator)
        y += 6

        // Snippet 按钮
        for snippet in snippets {
            let btnW = contentW - 44
            let btn = NSButton(frame: NSRect(x: paddingX, y: y, width: btnW, height: rowH))
            btn.title = snippet.label
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 13)
            btn.alignment = .left
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 5
            btn.target = self
            btn.action = #selector(snippetClicked(_:))
            btn.toolTip = snippet.text
            // ✅ 使用 identifier 匹配，不再用 title
            btn.identifier = NSUserInterfaceItemIdentifier(snippet.id)
            container.addSubview(btn)

            // 删除按钮
            let delBtn = NSButton(frame: NSRect(x: paddingX + btnW + 4, y: y + 6, width: 16, height: 16))
            delBtn.title = "×"
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            delBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            delBtn.contentTintColor = .systemRed
            delBtn.target = self
            delBtn.action = #selector(deleteSnippet(_:))
            delBtn.identifier = NSUserInterfaceItemIdentifier(snippet.id)
            delBtn.toolTip = "删除"
            container.addSubview(delBtn)

            // 编辑按钮
            let editBtn = NSButton(frame: NSRect(x: paddingX + btnW + 22, y: y + 6, width: 16, height: 16))
            editBtn.title = "✎"
            editBtn.bezelStyle = .inline
            editBtn.isBordered = false
            editBtn.font = NSFont.systemFont(ofSize: 11)
            editBtn.contentTintColor = .secondaryLabelColor
            editBtn.target = self
            editBtn.action = #selector(editSnippet(_:))
            editBtn.identifier = NSUserInterfaceItemIdentifier(snippet.id)
            editBtn.toolTip = "编辑"
            container.addSubview(editBtn)

            y += rowH + spacing
        }

        // + 新增按钮
        let addBtn = NSButton(frame: NSRect(x: paddingX, y: y, width: contentW, height: rowH))
        addBtn.title = "＋ 新增快捷文本"
        addBtn.bezelStyle = .rounded
        addBtn.font = NSFont.systemFont(ofSize: 12)
        addBtn.alignment = .center
        addBtn.contentTintColor = .controlAccentColor
        addBtn.target = self
        addBtn.action = #selector(toggleAddForm)
        container.addSubview(addBtn)
        y += rowH + spacing

        // 内联表单
        let formH: CGFloat = 90
        let formView = buildAddForm(x: paddingX, y: y, w: contentW, h: formH)
        formView.isHidden = true
        container.addSubview(formView)
        addFormView = formView

        y += paddingY

        layoutContainer(width: windowW, height: y)
    }

    // MARK: - Build Selection View (划词操作列表)

    func buildSelectionView(text: String?) {
        displayMode = .selection
        selectedText = text
        container.subviews.forEach { $0.removeFromSuperview() }

        let actions = SelectionActionStore.shared.actions
        let windowW: CGFloat = 240
        let paddingX: CGFloat = 12
        let paddingY: CGFloat = 10
        let rowH: CGFloat = 32
        let contentW = windowW - paddingX * 2

        var y = paddingY

        // 标题 + 关闭
        let titleLabel = NSTextField(labelWithString: "已选中")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.sizeToFit()
        titleLabel.setFrameOrigin(NSPoint(x: paddingX, y: y + 4))
        container.addSubview(titleLabel)

        let closeBtn = NSButton(title: "✕", target: self, action: #selector(hideWindow))
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.font = NSFont.systemFont(ofSize: 14)
        closeBtn.contentTintColor = .tertiaryLabelColor
        closeBtn.sizeToFit()
        closeBtn.setFrameOrigin(NSPoint(x: windowW - paddingX - closeBtn.frame.width, y: y))
        container.addSubview(closeBtn)
        y += 24

        // 文本预览
        let previewText = text ?? "(无内容)"
        let preview = NSTextField(labelWithString: String(previewText.prefix(60)))
        preview.font = NSFont.systemFont(ofSize: 13)
        preview.textColor = .labelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.setFrameSize(NSSize(width: contentW, height: 18))
        preview.setFrameOrigin(NSPoint(x: paddingX, y: y))
        container.addSubview(preview)
        y += 24

        // 分隔线
        let separator = NSView(frame: NSRect(x: paddingX, y: y, width: contentW, height: 0.5))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(separator)
        y += 6

        // 操作按钮列表
        for action in actions {
            let btn = NSButton(frame: NSRect(x: paddingX, y: y, width: contentW, height: rowH))
            btn.title = action.label
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 13)
            btn.alignment = .left
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 5
            btn.target = self
            btn.action = #selector(actionClicked(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(action.id)
            btn.toolTip = action.label
            container.addSubview(btn)
            y += rowH + 2
        }

        y += paddingY

        layoutContainer(width: windowW, height: y)
    }

    // MARK: - Layout Helper

    private func layoutContainer(width: CGFloat, height: CGFloat) {
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let minH: CGFloat = 60
        let maxH: CGFloat = 400
        let newH = min(max(height, minH), maxH)

        var rect = frame
        rect.size.width = width
        rect.size.height = newH
        setFrame(rect, display: true)
    }

    // MARK: - Add Form

    private var addFormView: NSView?
    private var isAddFormOpen = false
    private var editingSnippetId: String? = nil

    private func buildAddForm(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let form = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        form.wantsLayer = true
        form.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        form.layer?.cornerRadius = 6

        let fieldW = w - 16
        let fieldX: CGFloat = 8

        let labelField = NSTextField(frame: NSRect(x: fieldX, y: h - 30, width: fieldW, height: 22))
        labelField.placeholderString = "标签（如：代码审查）"
        labelField.font = NSFont.systemFont(ofSize: 12)
        labelField.bezelStyle = .roundedBezel
        labelField.identifier = NSUserInterfaceItemIdentifier("addLabel")
        form.addSubview(labelField)

        let textField = NSTextField(frame: NSRect(x: fieldX, y: h - 60, width: fieldW, height: 22))
        textField.placeholderString = "提示词内容"
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.bezelStyle = .roundedBezel
        textField.identifier = NSUserInterfaceItemIdentifier("addText")
        form.addSubview(textField)

        let saveBtn = NSButton(frame: NSRect(x: fieldX, y: 6, width: fieldW, height: 22))
        saveBtn.title = "保存"
        saveBtn.bezelStyle = .rounded
        saveBtn.font = NSFont.systemFont(ofSize: 12)
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveNewSnippet)
        form.addSubview(saveBtn)

        return form
    }

    @objc private func toggleAddForm() {
        isAddFormOpen.toggle()
        buildSlashView()
        if isAddFormOpen, let form = addFormView {
            form.isHidden = false
            // 调整窗口高度
            let currentH = container.frame.height
            layoutContainer(width: 240, height: currentH + 92)
        }
    }

    @objc private func saveNewSnippet() {
        guard let form = addFormView else { return }
        let labelField = form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) as? NSTextField
        let textField  = form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addText" }) as? NSTextField

        let label = labelField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let text  = textField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""

        guard !label.isEmpty, !text.isEmpty else {
            // 抖动提示
            let emptyField = label.isEmpty ? labelField : textField
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.05
                emptyField?.animator().setFrameOrigin(NSPoint(x: emptyField!.frame.origin.x + 4, y: emptyField!.frame.origin.y))
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.05
                    emptyField?.animator().setFrameOrigin(NSPoint(x: emptyField!.frame.origin.x - 4, y: emptyField!.frame.origin.y))
                }
            }
            return
        }

        if let editId = editingSnippetId, !editId.isEmpty {
            SnippetStore.shared.updateSnippet(id: editId, label: label, text: text)
        } else {
            SnippetStore.shared.addSnippet(label: label, text: text)
        }

        editingSnippetId = nil
        isAddFormOpen = false
        buildSlashView()
    }

    // MARK: - Snippet Actions

    /// ✅ 使用 identifier 匹配（不再用 title）
    @objc private func snippetClicked(_ sender: NSButton) {
        guard let snippetId = sender.identifier?.rawValue,
              let matched = SnippetStore.shared.snippets.first(where: { $0.id == snippetId }) else { return }

        FloatWindowManager.shared.hide()
        ClipboardService.shared.insertText(matched.text)
    }

    @objc private func deleteSnippet(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        SnippetStore.shared.removeSnippet(id: id)
        buildSlashView()
    }

    @objc private func editSnippet(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let snippet = SnippetStore.shared.snippets.first(where: { $0.id == id }) else { return }

        editingSnippetId = id
        isAddFormOpen = true
        buildSlashView()

        // 填充表单
        if let form = addFormView {
            (form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) as? NSTextField)?.stringValue = snippet.label
            (form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addText" }) as? NSTextField)?.stringValue = snippet.text
            form.isHidden = false
        }
    }

    // MARK: - Selection Actions

    @objc private func actionClicked(_ sender: NSButton) {
        guard let actionId = sender.identifier?.rawValue else { return }
        let actions = SelectionActionStore.shared.actions
        guard let action = actions.first(where: { $0.id == actionId }) else { return }

        guard let text = selectedText, !text.isEmpty else { return }

        FloatWindowManager.shared.hide()

        switch action.actionType {
        case .copy:
            ClipboardService.shared.copyText(text)

        case .quickAdd:
            let label = String(text.prefix(10).replacingOccurrences(of: "\n", with: " "))
            let app = currentBundleID
            SnippetStore.shared.addSnippet(label: label, text: text, app: app)
            NSLog("[FloatWindow] quickAdd: saved '\(label)' to [\(app)]")

        case .translate:
            let combined = (action.presetText ?? "") + text
            ClipboardService.shared.insertText(combined)

        case .insert:
            let combined = (action.presetText ?? "") + text
            ClipboardService.shared.insertText(combined)
        }
    }

    @objc private func hideWindow() {
        FloatWindowManager.shared.hide()
    }
}

// MARK: - ClipboardService
/// 统一剪贴板操作：消除 FloatWindow 里重复的剪贴板保存/恢复逻辑

final class ClipboardService {
    static let shared = ClipboardService()

    private init() {}

    /// 复制文本到剪贴板（不模拟粘贴）
    func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        NSLog("[ClipboardService] copied: '\(text.prefix(20))'")
    }

    /// 插入文本到当前焦点输入框（剪贴板 → Cmd+V → 恢复剪贴板）
    func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simulatePaste()

            if let prev = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - FloatWindowManager
/// 统一窗口管理：消除 show/showForSlash/showForSelection 中重复的窗口定位逻辑

final class FloatWindowManager {
    static let shared = FloatWindowManager()

    private var window: FloatWindow?
    private var isShown = false
    private var clickOutsideMonitor: Any?
    private(set) var isSlashMode = false

    var isVisible: Bool { isShown }
    var windowFrame: NSRect? { window?.frame }

    private init() {}

    func hide() {
        window?.orderOut(nil)
        isShown = false
        isSlashMode = false
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// 手动显示（菜单栏触发）
    func show(at point: NSPoint) {
        ensureWindow()
        guard let win = window else { return }

        SnippetStore.shared.switchApp("default")
        win.buildSlashView()
        positionWindow(win, near: point)

        isSlashMode = false
        isShown = true
        scheduleClickOutsideMonitor()
    }

    /// Slash 模式：输入框只有 "/" 时显示
    func showForSlash(at point: NSPoint, bundleID: String = "default") {
        ensureWindow()
        guard let win = window else { return }

        SnippetStore.shared.switchApp(bundleID)
        win.currentBundleID = bundleID
        win.buildSlashView()
        positionWindow(win, near: point)

        isSlashMode = true
        isShown = true
        scheduleClickOutsideMonitor()
    }

    /// 划词模式：选中文本后显示
    func showForSelection(near point: NSPoint, selectedText: String?, bundleID: String = "default") {
        ensureWindow()
        guard let win = window else { return }

        SnippetStore.shared.switchApp(bundleID)
        SelectionActionStore.shared.switchApp(bundleID)
        win.currentBundleID = bundleID
        win.buildSelectionView(text: selectedText)
        positionWindow(win, near: point)

        isSlashMode = false
        isShown = true
        scheduleClickOutsideMonitor()
    }

    func toggle(at point: NSPoint) {
        if isShown {
            hide()
        } else {
            show(at: point)
        }
    }

    func rebuildIfNeeded() {
        guard let win = window, isShown else { return }
        if isSlashMode {
            win.buildSlashView()
        }
        // selection 模式不 rebuild（操作列表固定）
    }

    // MARK: - Private Helpers

    private func ensureWindow() {
        if window == nil {
            window = FloatWindow()
        }
    }

    /// ✅ 统一窗口定位逻辑（消除原来 3 处重复代码）
    private func positionWindow(_ win: FloatWindow, near point: NSPoint) {
        let windowW: CGFloat = 240
        let windowH = win.frame.height

        var originX = point.x - windowW / 2
        var originY = point.y + 20

        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        if let screen = targetScreen {
            let vf = screen.visibleFrame
            originX = min(max(originX, vf.minX), vf.maxX - windowW)
            originY = min(max(originY, vf.minY), vf.minY + vf.height - windowH)
        }

        win.setFrameOrigin(NSPoint(x: originX, y: originY))
        win.orderFront(nil)
        win.orderFrontRegardless()
    }

    private func scheduleClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startClickOutsideMonitor()
        }
    }

    private func startClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, let win = self.window, self.isShown else { return }
            let mouseLoc = NSEvent.mouseLocation
            if !win.frame.contains(mouseLoc) {
                NSLog("[FloatWindowManager] Click outside, hiding")
                self.hide()
            }
        }
    }
}