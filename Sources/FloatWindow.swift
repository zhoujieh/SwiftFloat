import AppKit

// MARK: - FloatWindow

final class FloatWindow: NSPanel {
    private var snippetButtons: [NSButton] = []
    private var addFormView: NSView?
    private var isAddFormOpen = false
    private var editingSnippetId: String? = nil  // 非 nil 表示编辑模式
    private var selectedText: String? = nil  // 当前选中文本（存入词库用）
    var currentBundleID: String = "default"  // 当前 App bundle ID（快捷添加时用）
    private var escapeMonitor: Any?
    private var clickMonitor: Any?

    private let container = NSView()

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
        // Escape 取消
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
        rebuildButtons(SnippetStore.shared.snippets)
    }

    func rebuildButtons(_ snippets: [Snippet]) {
        container.subviews.forEach { $0.removeFromSuperview() }
        snippetButtons.removeAll()

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

        // Snippet 按钮 + 删除/编辑
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
            btn.identifier = NSUserInterfaceItemIdentifier(snippet.id)
            snippetButtons.append(btn)
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

        // 内联表单（默认隐藏）
        let formH: CGFloat = 90
        let formView = buildAddForm(x: paddingX, y: y, w: contentW, h: formH)
        formView.isHidden = !isAddFormOpen
        container.addSubview(formView)
        addFormView = formView
        if isAddFormOpen {
            clearAddFormFields()
            y += formH + spacing
        }

        y += paddingY

        // 设置容器和窗口大小
        let totalH = y
        container.frame = NSRect(x: 0, y: 0, width: windowW, height: totalH)

        let minH: CGFloat = 60
        let maxH: CGFloat = 300
        let newH = min(max(totalH, minH), maxH)

        var rect = frame
        rect.size.width = windowW
        rect.size.height = newH
        setFrame(rect, display: true)

        NSLog("[SwiftFloat] rebuildButtons: \(snippets.count) snippets, windowH=\(newH)")
    }

    /// 框选文本后显示：预览 + 快捷添加按钮
    func rebuildWithSelection(_ text: String?) {
        container.subviews.forEach { $0.removeFromSuperview() }
        snippetButtons.removeAll()
        isAddFormOpen = false
        editingSnippetId = nil
        selectedText = text  // 存起来给「快捷添加」用

        let windowW: CGFloat = 240
        let paddingX: CGFloat = 12
        let paddingY: CGFloat = 10
        let rowH: CGFloat = 32
        let contentW = windowW - paddingX * 2

        var y = paddingY

        // 标题 + 关闭按钮
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

        // 文本预览（最多 60 字符）
        let previewText = text ?? "(无内容)"
        let preview = NSTextField(labelWithString: String(previewText.prefix(60)))
        preview.font = NSFont.systemFont(ofSize: 13)
        preview.textColor = .labelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.setFrameSize(NSSize(width: contentW, height: 18))
        preview.setFrameOrigin(NSPoint(x: paddingX, y: y))
        container.addSubview(preview)
        y += 24

        // 快捷添加按钮
        let addBtn = NSButton(frame: NSRect(x: paddingX, y: y, width: contentW, height: rowH))
        addBtn.title = "＋ 快捷添加"
        addBtn.bezelStyle = .rounded
        addBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        addBtn.alignment = .center
        addBtn.contentTintColor = .controlAccentColor
        addBtn.target = self
        addBtn.action = #selector(quickAddSelectedText)
        container.addSubview(addBtn)
        y += rowH + paddingY

        y += paddingY

        // 设置容器和窗口大小
        let totalH = y
        container.frame = NSRect(x: 0, y: 0, width: windowW, height: totalH)

        let minH: CGFloat = 80
        let newH = max(totalH, minH)

        var rect = frame
        rect.size.width = windowW
        rect.size.height = newH
        setFrame(rect, display: true)

        NSLog("[SwiftFloat] rebuildWithSelection: preview=\(previewText.prefix(20)), windowH=\(newH)")
    }

    /// 快捷添加：直接存入词库并关闭
    @objc private func quickAddSelectedText() {
        guard let text = selectedText, !text.isEmpty else {
            NSLog("[SwiftFloat] quickAdd: no text")
            return
        }
        // 生成标签：取前 10 个字符
        let label = String(text.prefix(10).replacingOccurrences(of: "\n", with: " "))
        let app = currentBundleID
        SnippetStore.shared.addSnippet(label: label, text: text, app: app)
        NSLog("[SwiftFloat] quickAdd: saved \"\(label)\" to [\(app)]")
        NSLog("[SwiftFloat] quickAdd: saved \"\(label)\"")
        hideWindow()
    }

    @objc private func copySelectedText(_ sender: NSButton) {
        guard let text = sender.identifier?.rawValue else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        FloatWindowManager.shared.hide()
    }

    @objc private func hideWindow() {
        isAddFormOpen = false
        FloatWindowManager.shared.hide()
    }

    // MARK: - Add Form

    private func buildAddForm(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let form = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        form.wantsLayer = true
        form.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        form.layer?.cornerRadius = 6

        let fieldW = w - 16
        let fieldX: CGFloat = 8

        // 标签输入框
        let labelField = NSTextField(frame: NSRect(x: fieldX, y: h - 30, width: fieldW, height: 22))
        labelField.placeholderString = "标签（如：代码审查）"
        labelField.font = NSFont.systemFont(ofSize: 12)
        labelField.bezelStyle = .roundedBezel
        labelField.identifier = NSUserInterfaceItemIdentifier("addLabel")
        form.addSubview(labelField)

        // 文本输入框
        let textField = NSTextField(frame: NSRect(x: fieldX, y: h - 60, width: fieldW, height: 22))
        textField.placeholderString = "提示词内容"
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.bezelStyle = .roundedBezel
        textField.identifier = NSUserInterfaceItemIdentifier("addText")
        form.addSubview(textField)

        // 保存按钮
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
        rebuildButtons(SnippetStore.shared.snippets)
    }

    private func clearAddFormFields() {
        guard let form = container.subviews.first(where: { $0.subviews.contains(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) }) else { return }
        (form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) as? NSTextField)?.stringValue = ""
        (form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addText" }) as? NSTextField)?.stringValue = ""
    }

    @objc private func saveNewSnippet() {
        guard let form = container.subviews.first(where: { $0.subviews.contains(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) }) else { return }
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
            // 编辑模式：更新现有
            SnippetStore.shared.updateSnippet(id: editId, label: label, text: text)
        } else {
            // 新增模式
            SnippetStore.shared.addSnippet(label: label, text: text)
        }

        // 重置状态
        editingSnippetId = nil
        isAddFormOpen = false
        rebuildButtons(SnippetStore.shared.snippets)
    }

    @objc private func snippetClicked(_ sender: NSButton) {
        guard let label = sender.title as String?,
              let matched = SnippetStore.shared.snippets.first(where: { $0.label == label }) else { return }

        FloatWindowManager.shared.hide()
        insertText(matched.text)
    }

    @objc private func deleteSnippet(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        SnippetStore.shared.removeSnippet(id: id)
        rebuildButtons(SnippetStore.shared.snippets)
    }

    @objc private func editSnippet(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let snippet = SnippetStore.shared.snippets.first(where: { $0.id == id }) else { return }
        // 打开表单并填充现有值
        editingSnippetId = id
        isAddFormOpen = true
        rebuildButtons(SnippetStore.shared.snippets)
        // 填充表单
        if let form = container.subviews.first(where: { $0.subviews.contains(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) }) {
            (form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addLabel" }) as? NSTextField)?.stringValue = snippet.label
            (form.subviews.first(where: { ($0 as? NSTextField)?.identifier?.rawValue == "addText" }) as? NSTextField)?.stringValue = snippet.text
        }
    }

    private func insertText(_ text: String) {
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

final class FloatWindowManager {
    static let shared = FloatWindowManager()

    private var window: FloatWindow?
    private var isShown = false
    private var clickOutsideMonitor: Any?

    var isVisible: Bool { isShown }
    var windowFrame: NSRect? { window?.frame }

    private init() {}

    func toggle(at point: NSPoint) {
        if isShown {
            hide()
        } else {
            show(at: point)
        }
    }

    func show(at point: NSPoint) {
        if window == nil {
            window = FloatWindow()
        }

        guard let win = window else { return }

        // 每次显示时用当前 App 的 snippets 重建按钮
        win.rebuildButtons(SnippetStore.shared.snippets)

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

        isShown = true
    }

    func hide() {
        window?.orderOut(nil)
        isShown = false
        // 移除点击监听
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// 框选文本后显示：带复制按钮 + snippets
    func showForSelection(near point: NSPoint, selectedText: String?, bundleID: String = "default") {
        if window == nil {
            window = FloatWindow()
        }

        guard let win = window else { return }
        win.currentBundleID = bundleID

        // 重建按钮 + 复制当前选中
        win.rebuildWithSelection(selectedText)

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
        isShown = true

        // 添加点击窗口外关闭的监听（延迟 0.3s 避免立即触发）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startClickOutsideMonitor()
        }
    }

    private func startClickOutsideMonitor() {
        // 先移除旧的
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, let win = self.window, self.isShown else { return }
            let mouseLoc = NSEvent.mouseLocation
            if !win.frame.contains(mouseLoc) {
                self.hide()
            }
        }
    }

    func rebuildIfNeeded() {
        guard let win = window, isShown else { return }
        win.rebuildButtons(SnippetStore.shared.snippets)
    }
}
