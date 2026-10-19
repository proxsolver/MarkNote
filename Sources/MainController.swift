import AppKit

final class MainController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private let store = Store.shared

    private var rootVC: NSViewController!
    private var welcomeVC: WelcomeController!
    private(set) var sidebar: SidebarController!
    private(set) var editor: EditorController!
    private(set) var preview: PreviewController!
    private var splitVC: NSSplitViewController!
    private var previewItem: NSSplitViewItem!

    private var dot: NSView!
    private var pathLabel: NSTextField!
    private var toastLabel: NSTextField!
    private var savedLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var showingWelcome = false
    private var scrollObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.minSize = NSSize(width: 700, height: 420)
        window.tabbingMode = .disallowed
        window.title = "MarkNote"
        window.setFrameAutosaveName("MarkNoteMainWindow")
        window.titlebarAppearsTransparent = false
        window.center()
        store.window = window

        buildInterface()
        bind()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Interface

    private func buildInterface() {
        guard let window else { return }

        sidebar = SidebarController(store: store)
        editor = EditorController(store: store)
        preview = PreviewController(store: store)

        let detail = NSSplitViewController()
        detail.splitView.isVertical = true
        detail.splitView.dividerStyle = .thin

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 320
        editorItem.canCollapse = false
        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 260
        previewItem.canCollapse = true
        self.previewItem = previewItem
        detail.addSplitViewItem(editorItem)
        detail.addSplitViewItem(previewItem)

        splitVC = NSSplitViewController()
        splitVC.splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        splitVC.addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
        splitVC.addSplitViewItem(detailItem)

        let bar = makeStatusBar()

        rootVC = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 700))
        container.wantsLayer = true
        rootVC.view = container

        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitVC.view)
        container.addSubview(bar)
        rootVC.addChild(splitVC)

        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),
        ])

        welcomeVC = WelcomeController(store: store)
        welcomeVC.view.translatesAutoresizingMaskIntoConstraints = false

        window.contentViewController = welcomeVC
        showingWelcome = true

        let toolbar = NSToolbar(identifier: "MarkNoteToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        wireScrollSync()
    }

    private func wireScrollSync() {
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: editor.scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self, Store.shared.scrollSync, !self.editor.isScrollQuiet else { return }
            self.preview.setFraction(self.editor.scrollFraction)
        }
        preview.onScroll = { [weak self] fraction in
            guard let self, Store.shared.scrollSync else { return }
            self.editor.setScrollFraction(fraction)
        }
    }

    private func makeStatusBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.state = .active
        bar.blendingMode = .withinWindow

        dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = label(font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), color: .secondaryLabelColor)
        toastLabel = label(font: .systemFont(ofSize: 11), color: .labelColor)
        savedLabel = label(font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor)
        statsLabel = label(font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor)

        let stack = NSStackView(views: [dot, pathLabel, toastLabel, savedLabel, statsLabel])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        toastLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func label(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: - Binding

    private func bind() {
        store.on(.document) { [weak self] in self?.refreshChrome() }
        store.on(.ui) { [weak self] in self?.refreshChrome() }
        store.on(.text) { [weak self] in self?.refreshStatus() }
        store.on(.docs) { [weak self] in self?.refreshRecentMenu() }
        refreshChrome()
    }

    func bootstrap() {
        store.bootstrap()
        refreshChrome()
        refreshStatus()
    }

    private func refreshChrome() {
        showWelcomeIfNeeded()
        previewItem.isCollapsed = !store.previewVisible
        refreshTitle()
        refreshStatus()
        refreshRecentMenu()
    }

    private func showWelcomeIfNeeded() {
        let shouldShow = store.folder == nil && store.current == nil
        guard shouldShow != showingWelcome else { return }
        guard let window else { return }
        if shouldShow {
            window.contentViewController = welcomeVC
        } else {
            window.contentViewController = rootVC
        }
        showingWelcome = shouldShow
        if shouldShow { welcomeVC.reload() }
    }

    private func refreshTitle() {
        guard let window else { return }
        if let doc = store.current {
            window.title = doc.title
            window.representedURL = doc.url
        } else {
            window.title = "MarkNote"
            window.representedURL = store.folder
        }
    }

    private func refreshStatus() {
        pathLabel.stringValue = store.relativePath
        statsLabel.stringValue = store.current == nil ? "" : store.stats
        if let saved = store.savedAt, store.current != nil {
            savedLabel.stringValue = store.isDirty ? "저장 중…" : "· \(saved.timeAgoShort) 저장"
        } else {
            savedLabel.stringValue = ""
        }
        dot.layer?.backgroundColor = (store.isDirty ? NSColor.systemOrange : NSColor.systemGreen.withAlphaComponent(0.7)).cgColor
        toastLabel.stringValue = store.toast ?? ""
    }

    // MARK: - Recent menu

    private func refreshRecentMenu() {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "파일" })?.submenu,
              let recent = fileMenu.items.first(where: { $0.submenu?.title == "최근 문서" })?.submenu
        else { return }
        recent.removeAllItems()
        let items = store.recents
        if items.isEmpty {
            let empty = NSMenuItem(title: "최근 문서 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recent.addItem(empty)
            return
        }
        for doc in items.prefix(10) {
            let item = NSMenuItem(title: doc.title, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = doc.url.path
            item.toolTip = doc.url.path
            recent.addItem(item)
        }
        recent.addItem(.separator())
        let clear = NSMenuItem(title: "최근 기록 지우기", action: #selector(clearRecentItems(_:)), keyEquivalent: "")
        clear.target = self
        recent.addItem(clear)
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newDocument, .openFolder, .separator, .previewToggle, .exportMenu]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newDocument, .openFolder, .previewToggle, .exportMenu, .separator, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = nil
        switch id {
        case .newDocument:
            item.image = symbol("doc.badge.plus")
            item.label = "새 문서"
            item.paletteLabel = "새 문서 (⌘N)"
            item.action = #selector(newDocument(_:))
        case .openFolder:
            item.image = symbol("folder")
            item.label = "폴더 열기"
            item.paletteLabel = "폴더 열기 (⌘O)"
            item.action = #selector(openFolder(_:))
        case .previewToggle:
            item.image = symbol(store.previewVisible ? "eye.slash" : "eye")
            item.label = "미리보기"
            item.paletteLabel = "미리보기 토글 (⌘R)"
            item.action = #selector(togglePreview(_:))
        case .exportMenu:
            let menu = NSMenu()
            menu.addItem(withTitle: "HTML로 내보내기…", action: #selector(exportHTML(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "시각화 포함 HTML 내보내기…", action: #selector(exportHTMLRich(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "브라우저로 미리보기", action: #selector(openInBrowser(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "HTML로 복사", action: #selector(copyHTML(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "PDF로 내보내기…", action: #selector(exportPDF(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "인쇄…", action: #selector(printNote(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Finder에서 보기", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "이름 변경…", action: #selector(renameDocument(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "휴지통으로 이동", action: #selector(deleteDocument(_:)), keyEquivalent: "")
            for i in menu.items where i.action != nil { i.target = nil }
            let picker = NSMenuToolbarItem(itemIdentifier: id)
            picker.menu = menu
            picker.image = symbol("square.and.arrow.up")
            picker.label = "내보내기"
            picker.paletteLabel = "내보내기 / 문서 작업"
            picker.showsIndicator = true
            picker.isBordered = true
            return picker
        default:
            return nil
        }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)
    }

    // MARK: - Actions

    @objc func newDocument(_ sender: Any?) { store.newDocument() }
    @objc func openFolder(_ sender: Any?) { store.openFolderPanel() }
    @objc func useDefaultFolder(_ sender: Any?) { store.useDefaultFolder() }
    @objc func saveDocument(_ sender: Any?) { store.saveNow() }
    @objc func revertToDisk(_ sender: Any?) { store.reloadFromDisk() }
    @objc func showHistory(_ sender: Any?) {
        guard let window, store.current != nil else { return }
        HistoryPanel.present(store: store, window: window)
    }
    @objc func toggleHistoryKeeping(_ sender: Any?) { store.toggleHistoryKeeping() }
    @objc func revealHistoryFolder(_ sender: Any?) { store.revealHistoryFolder() }
    @objc func clearCurrentHistory(_ sender: Any?) {
        guard let doc = store.current, let window else { return }
        let count = store.historySnapshots.count
        let alert = NSAlert()
        alert.messageText = "'\(doc.fileName)'의 히스토리를 지울까요?"
        alert.informativeText = count == 0
            ? "보관된 이전 버전이 없습니다."
            : "이전 버전 \(count)개가 사라집니다. 문서 자체는 그대로 있습니다."
        alert.addButton(withTitle: count == 0 ? "확인" : "지우기")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, count > 0 else { return }
            self.store.clearHistory(of: doc)
        }
    }
    @objc func renameDocument(_ sender: Any?) { store.renameCurrent() }
    @objc func deleteDocument(_ sender: Any?) { store.deleteCurrent() }
    @objc func revealInFinder(_ sender: Any?) { store.revealInFinder() }
    @objc func openFolderInFinder(_ sender: Any?) { store.openFolderInFinder() }
    @objc func exportHTML(_ sender: Any?) { store.exportHTML() }
    @objc func exportHTMLRich(_ sender: Any?) { store.exportHTMLRich() }
    /// A4 PDF로 저장 — 뽑을 때만 라이트 팔레트로 다시 그립니다.
    @objc func exportPDF(_ sender: Any?) { store.exportPDF() }
    @objc func printNote(_ sender: Any?) { store.printCurrent() }
    @objc func openInBrowser(_ sender: Any?) { store.openInBrowser() }
    @objc func copyHTML(_ sender: Any?) { store.copyHTML() }
    @objc func copyMarkdown(_ sender: Any?) { store.copyPlainMarkdown() }

    @objc func boldText(_ sender: Any?) { store.run(.bold) }
    @objc func italicText(_ sender: Any?) { store.run(.italic) }
    @objc func strikeText(_ sender: Any?) { store.run(.strike) }
    @objc func inlineCodeText(_ sender: Any?) { store.run(.inlineCode) }
    @objc func codeBlockText(_ sender: Any?) { store.run(.codeBlock) }
    @objc func insertLink(_ sender: Any?) { store.run(.link) }
    @objc func insertWikiLink(_ sender: Any?) { store.run(.wikiLink) }
    /// 본문에 흩어진 '제목 언급'을 실제 `[[링크]]`로 바꿉니다(되돌리기는 ⌘Z).
    @objc func promoteMentions(_ sender: Any?) { store.promoteMentions() }
    @objc func heading1(_ sender: Any?) { store.run(.heading(1)) }
    @objc func heading2(_ sender: Any?) { store.run(.heading(2)) }
    @objc func heading3(_ sender: Any?) { store.run(.heading(3)) }
    @objc func clearHeading(_ sender: Any?) { store.run(.clearHeading) }
    @objc func bulletList(_ sender: Any?) { store.run(.ul) }
    @objc func numberList(_ sender: Any?) { store.run(.ol) }
    @objc func blockQuote(_ sender: Any?) { store.run(.quote) }
    @objc func horizontalRule(_ sender: Any?) { store.run(.hr) }

    @objc func togglePreview(_ sender: Any?) { store.togglePreview() }
    @objc func toggleScrollSync(_ sender: Any?) { store.scrollSync.toggle() }
    @objc func toggleVisualRender(_ sender: Any?) { store.visualEnabled.toggle() }
    @objc func sortByTitle(_ sender: Any?) { store.sort = .title }
    @objc func sortByModified(_ sender: Any?) { store.sort = .modified }
    @objc func sortByCreated(_ sender: Any?) { store.sort = .created }
    @objc func toggleSortDirection(_ sender: Any?) { store.sortAscending.toggle() }
    @objc func toggleBacklinks(_ sender: Any?) { store.backlinksExpanded.toggle() }
    @objc func toggleAutosave(_ sender: Any?) { store.toggleAutosave() }
    @objc func largerText(_ sender: Any?) { store.changeFontSize(1) }
    @objc func smallerText(_ sender: Any?) { store.changeFontSize(-1) }
    @objc func defaultTextSize(_ sender: Any?) { store.resetFontSize() }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        store.openRecent(Doc(url: URL(fileURLWithPath: path)))
    }

    @objc func clearRecentItems(_ sender: Any?) { store.clearRecents() }

    @objc func showSettings(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "설정"
        alert.informativeText = "모든 내용은 이 맥 안에만 저장됩니다."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let autosave = NSButton(checkboxWithTitle: "타이핑 중 자동 저장", target: self, action: #selector(settingAutosave(_:)))
        autosave.state = store.autosaveEnabled ? .on : .off
        let sync = NSButton(checkboxWithTitle: "편집기·미리보기 스크롤 동기화", target: self, action: #selector(settingSync(_:)))
        sync.state = store.scrollSync ? .on : .off
        let visual = NSButton(checkboxWithTitle: "미리보기에서 머메이드·구문 색상·수식 렌더링",
                             target: self, action: #selector(settingVisual(_:)))
        visual.state = store.visualEnabled ? .on : .off
        if !Vendor.available {
            visual.state = .off
            visual.title = "미리보기 시각화 렌더링 (앱에 번들 없음)"
        }
        visual.isEnabled = Vendor.available
        let history = NSButton(checkboxWithTitle: "저장할 때마다 이전 버전 보관 (노트 옆 \(NoteHistory.directoryName), 최근 \(NoteHistory.limit)개)",
                               target: self, action: #selector(settingHistory(_:)))
        history.state = store.historyEnabled ? .on : .off
        stack.addArrangedSubview(autosave)
        stack.addArrangedSubview(sync)
        stack.addArrangedSubview(visual)
        stack.addArrangedSubview(history)
        alert.accessoryView = stack
        alert.addButton(withTitle: "완료")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func settingAutosave(_ sender: NSButton) {
        if store.autosaveEnabled != (sender.state == .on) { store.toggleAutosave() }
    }

    @objc private func settingSync(_ sender: NSButton) {
        store.scrollSync = sender.state == .on
    }

    @objc private func settingVisual(_ sender: NSButton) {
        store.visualEnabled = sender.state == .on
    }

    @objc private func settingHistory(_ sender: NSButton) {
        guard store.historyEnabled != (sender.state == .on) else { return }
        store.historyEnabled = sender.state == .on
    }

    @objc func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "단축키"
        alert.informativeText = """
        파일     ⌘N 새 문서 · ⌘O 폴더 열기 · ⌘S 저장 · ⌥⌘R Finder에서 보기
        서식    ⌘B 굵게 · ⌘I 기울임 · ⌘K 링크 · ⌥⌘K 위키 링크 · ⌘E 인라인 코드 · ⇧⌘K 코드 블록
        제목    ⌘1 ⌘2 ⌘3 · ⌘0 제목 해제
        목록    ⌥⌘L 글머리 · ⇧⌘L 번호 · ⇧⌘Q 인용구 · ⇧⌘D 구분선
        태그    본문에 #태그 · 사이드바 칩이나 미리보기 칩을 누르면 그 태그만 좁혀 봅니다
        연결    ⌥⌘M 다른 노트 제목으로 적힌 곳을 [[링크]]로 · ⌘Z로 되돌리기
        보기    ⌘R 미리보기 토글 · ⌘+ / ⌘- 글자 크기 · ⌃⌘S 사이드바
        정렬    ⌥⌘1 이름 · ⌥⌘2 최근 수정 · ⌥⌘3 생성일 · ⇧⌥⌘S 방향 · ⌥⌘B 참조 목록
        히스토리 ⌃⌘H 저장 히스토리 · ⇧⌥⌘H 히스토리 폴더 · 되돌리기는 확인 후 실행
        편집    ⌘F 찾기 · ⌥⌘F 바꾸기 · Tab 들여쓰기 · Enter 목록 자동 이어짐
        내보내기 ⇧⌘E HTML 저장 · ⌥⇧⌘E 그림·수식 포함 · ⇧⌘B 브라우저 미리보기
        사진     ⌘V 붙여넣기 · 편집기에 끌어놓기 → 노트 옆 assets/에 저장하고 그 자리에 링크
        종이     ⌘P 인쇄 · ⇧⌘P PDF로 저장 — 화면이 다크해도 종이는 언제나 흰 바탕에 검은 글자
        시각화  머메이드 · 코드 구문 색상 · LaTeX 수식 (보기 메뉴에서 켜고 끄기)
        """
        alert.addButton(withTitle: "확인")
        alert.beginSheetModal(for: Store.shared.window ?? NSWindow(), completionHandler: nil)
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let needsDoc: Set<Selector> = [
            #selector(saveDocument(_:)), #selector(revertToDisk(_:)), #selector(renameDocument(_:)),
            #selector(deleteDocument(_:)), #selector(revealInFinder(_:)), #selector(exportHTML(_:)),
            #selector(exportHTMLRich(_:)), #selector(exportPDF(_:)), #selector(printNote(_:)),
            #selector(openInBrowser(_:)), #selector(copyHTML(_:)), #selector(copyMarkdown(_:)),
            #selector(boldText(_:)), #selector(italicText(_:)), #selector(strikeText(_:)),
            #selector(inlineCodeText(_:)), #selector(codeBlockText(_:)), #selector(insertLink(_:)),
            #selector(insertWikiLink(_:)), #selector(promoteMentions(_:)),
            #selector(heading1(_:)), #selector(heading2(_:)), #selector(heading3(_:)),
            #selector(clearHeading(_:)), #selector(bulletList(_:)), #selector(numberList(_:)),
            #selector(blockQuote(_:)), #selector(horizontalRule(_:)),
            #selector(showHistory(_:)), #selector(revealHistoryFolder(_:)), #selector(clearCurrentHistory(_:)),
        ]
        if let action, needsDoc.contains(action), store.current == nil { return false }
        if let action {
            switch action {
            case #selector(toggleAutosave(_:)): menuItem.state = store.autosaveEnabled ? .on : .off
            case #selector(toggleScrollSync(_:)): menuItem.state = store.scrollSync ? .on : .off
            case #selector(toggleVisualRender(_:)):
                menuItem.state = store.visualEnabled ? .on : .off
                guard Vendor.available else {
                    menuItem.state = .off
                    return false
                }
            case #selector(togglePreview(_:)): menuItem.state = store.previewVisible ? .on : .off
            case #selector(sortByTitle(_:)): menuItem.state = store.sort == .title ? .on : .off
            case #selector(sortByModified(_:)): menuItem.state = store.sort == .modified ? .on : .off
            case #selector(sortByCreated(_:)): menuItem.state = store.sort == .created ? .on : .off
            case #selector(toggleSortDirection(_:)):
                menuItem.state = .off
                menuItem.title = store.sortAscending ? "내림차순으로" : "오름차순으로"
            case #selector(toggleBacklinks(_:)): menuItem.state = store.backlinksExpanded ? .on : .off
            case #selector(promoteMentions(_:)):
                // 몇 개를 바꿀 수 있는지 메뉴에 적어 둡니다. 눌렀을 때 아무 일도 일어나지
                // 않는 명령이 제일 혼란스럽습니다.
                let count = store.promotableCount
                menuItem.state = .off
                menuItem.title = count > 0 ? "제목 언급을 위키링크로 (\(count))" : "제목 언급을 위키링크로"
                return count > 0
            case #selector(toggleHistoryKeeping(_:)): menuItem.state = store.historyEnabled ? .on : .off
            case #selector(clearCurrentHistory(_:)):
                // 비울 것이 없으면 메뉴 회색으로 — "지웠습니다" 토스트가 거짓말이 되지 않게.
                menuItem.state = .off
                return !store.historySnapshots.isEmpty
            default: break
            }
        }
        return true
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        store.flush()
    }
}

extension NSToolbarItem.Identifier {
    static let newDocument = NSToolbarItem.Identifier("MarkNote.newDocument")
    static let openFolder = NSToolbarItem.Identifier("MarkNote.openFolder")
    static let previewToggle = NSToolbarItem.Identifier("MarkNote.previewToggle")
    static let exportMenu = NSToolbarItem.Identifier("MarkNote.exportMenu")
}
