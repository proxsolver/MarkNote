import AppKit

final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: Store
    private var table: NSTableView!
    private var scroll: NSScrollView!
    private var search: NSSearchField!
    private var folderButton: NSButton!
    private var folderLabel: NSTextField!
    private var countLabel: NSTextField!
    private var updatingSelection = false

    // Sorting controls.
    private var sortPopup: NSPopUpButton!
    private var sortDirectionButton: NSButton!

    // "Notes that reference this one" panel under the document list.
    private var refsHeader: NSButton!
    private var refsBox: NSStackView!
    private var refsHeight: NSLayoutConstraint!
    private var refRows: [RefRowView] = []
    private var moreLabel: NSTextField!

    /// Rows the panel shows before it stops growing and starts scrolling.
    private static let visibleRefRows = 4

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "문서"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.wantsLayer = true

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let title = NSTextField(labelWithString: "문서")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let newButton = iconButton("doc.badge.plus", #selector(newDocument(_:)), "새 문서 (⌘N)")
        newButton.target = self
        let openButton = iconButton("folder", #selector(openFolder(_:)), "폴더 열기 (⌘O)")
        openButton.target = self
        let refreshButton = iconButton("arrow.clockwise", #selector(refresh(_:)), "폴더 새로 고침")
        refreshButton.target = self
        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(refreshButton)
        header.addArrangedSubview(openButton)
        header.addArrangedSubview(newButton)

        search = NSSearchField()
        search.placeholderString = "문서 검색"
        search.delegate = self
        search.font = .systemFont(ofSize: 12)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        (search.cell as? NSSearchFieldCell)?.searchMenuTemplate = nil

        table = NSTableView()
        table.style = .inset
        table.selectionHighlightStyle = .sourceList
        table.backgroundColor = .clear
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("doc"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.menu = contextMenu()
        table.registerForDraggedTypes([.fileURL])
        table.draggingDestinationFeedbackStyle = .regular

        scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        folderButton = NSButton(title: "", target: self, action: #selector(revealFolder(_:)))
        folderButton.bezelStyle = .inline
        folderButton.isBordered = false
        folderButton.font = .systemFont(ofSize: 10)
        folderButton.contentTintColor = .secondaryLabelColor
        folderButton.imagePosition = .imageLeading
        folderButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        folderButton.toolTip = "더블클릭: Finder에서 열기"

        folderLabel = NSTextField(labelWithString: "")
        folderLabel.font = .systemFont(ofSize: 10)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingHead
        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [folderButton, folderLabel, spacerLike(), countLabel])
        footer.orientation = .horizontal
        footer.spacing = 5
        footer.alignment = .centerY
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sortBar = makeSortBar()
        let refs = makeRefsPanel()

        let subs: [NSView] = [header, search, sortBar, scroll, refs.header, refs.box, footer]
        for sub in subs {
            sub.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 22),

            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),

            sortBar.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 7),
            sortBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            sortBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            sortBar.heightAnchor.constraint(equalToConstant: 20),

            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 18),

            refs.header.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            refs.header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            refs.header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            refs.header.heightAnchor.constraint(equalToConstant: 22),

            refs.box.topAnchor.constraint(equalTo: refs.header.bottomAnchor),
            refs.box.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 4),
            refs.box.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),

            refs.box.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),

            scroll.topAnchor.constraint(equalTo: sortBar.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        refsHeight = refs.box.heightAnchor.constraint(equalToConstant: 0)
        refsHeight.isActive = true

        view = effect
        bind()
        refresh()
    }

    private func spacerLike() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    private func iconButton(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.action = action
        button.toolTip = tip
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func bind() {
        store.on(.docs) { [weak self] in self?.refresh() }
        store.on(.document) { [weak self] in self?.refresh() }
        store.on(.ui) { [weak self] in self?.refresh() }
        store.on(.links) { [weak self] in self?.refreshRefs() }
    }

    // MARK: - Sorting

    /// Narrow row under the search field: 기준 선택 + 방향 토글. A popup keeps the
    /// choice visible, which three icon buttons in the header would not at 190pt.
    private func makeSortBar() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "정렬")
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 13).isActive = true

        sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sortPopup.controlSize = .small
        sortPopup.font = .systemFont(ofSize: 11)
        sortPopup.isBordered = false
        sortPopup.toolTip = "사이드바 정렬 기준"
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        sortPopup.addItems(withTitles: DocSort.allCases.map { $0.label })
        sortPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sortDirectionButton = iconButton("arrow.down", #selector(sortDirectionToggled(_:)), "오름차순 / 내림차순 전환")
        sortDirectionButton.target = self

        let spacer = spacerLike()
        row.addArrangedSubview(glyph)
        row.addArrangedSubview(sortPopup)
        row.addArrangedSubview(sortDirectionButton)
        row.addArrangedSubview(spacer)
        return row
    }

    @objc private func sortChanged(_ sender: Any?) {
        guard let sortPopup else { return }
        let index = sortPopup.indexOfSelectedItem
        guard index >= 0, index < DocSort.allCases.count else { return }
        let picked = DocSort.allCases[index]
        // Same key, only the label refreshed: don't rebuild the list for nothing.
        if store.sort != picked { store.sort = picked }
    }

    @objc private func sortDirectionToggled(_ sender: Any?) { store.sortAscending.toggle() }

    private func syncSortControls() {
        guard let sortPopup, let sortDirectionButton else { return }
        let index = DocSort.allCases.firstIndex(of: store.sort) ?? 1
        if sortPopup.indexOfSelectedItem != index { sortPopup.selectItem(at: index) }
        sortPopup.toolTip = "정렬 기준: \(store.sort.label)"
        sortDirectionButton.image = NSImage(systemSymbolName: store.sortAscending ? "arrow.up" : "arrow.down",
                                            accessibilityDescription: store.sortAscending ? "오름차순" : "내림차순")
        sortDirectionButton.toolTip = store.sortAscending ? "오름차순 — 클릭하면 내림차순" : "내림차순 — 클릭하면 오름차순"
    }

    // MARK: - Backlinks panel

    private func makeRefsPanel() -> (header: NSButton, box: NSStackView) {
        refsHeader = NSButton(title: "이 문서를 참조", target: self, action: #selector(toggleRefs(_:)))
        refsHeader.bezelStyle = .inline
        refsHeader.isBordered = false
        refsHeader.font = .systemFont(ofSize: 10.5, weight: .semibold)
        refsHeader.contentTintColor = .secondaryLabelColor
        refsHeader.imagePosition = .imageLeading
        refsHeader.alignment = .left

        refsBox = NSStackView()
        refsBox.orientation = .vertical
        refsBox.spacing = 0
        refsBox.alignment = .width
        refsBox.distribution = .fill
        refsBox.translatesAutoresizingMaskIntoConstraints = false

        moreLabel = NSTextField(labelWithString: "")
        moreLabel.font = .systemFont(ofSize: 10)
        moreLabel.textColor = .tertiaryLabelColor
        moreLabel.isHidden = true

        return (refsHeader, refsBox)
    }

    @objc private func toggleRefs(_ sender: Any?) { store.backlinksExpanded.toggle() }

    /// Rebuilds the rows for the open note. Cheap: at most a handful of rows, and
    /// reuse of `RefRowView` keeps the stack from churning on every keystroke.
    private func refreshRefs() {
        guard let refsHeader, let refsBox, let refsHeight else { return }
        let refs = store.current.map { store.backlinks(to: $0) } ?? []
        let shown = store.backlinksExpanded ? refs : []
        let visible = Array(shown.prefix(SidebarController.visibleRefRows))
        let extra = shown.count - visible.count

        refsHeader.title = refs.isEmpty ? "이 문서를 참조" : "이 문서를 참조 (\(refs.count))"
        refsHeader.image = NSImage(systemSymbolName: store.backlinksExpanded ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: nil)
        refsHeader.isEnabled = !refs.isEmpty || store.backlinksExpanded
        refsHeader.contentTintColor = refs.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor

        while refRows.count < visible.count {
            let row = RefRowView()
            refRows.append(row)
            refsBox.addArrangedSubview(row)
        }
        for (offset, row) in refRows.enumerated() {
            if offset < visible.count {
                row.configure(ref: visible[offset])
                row.onClick { [weak self] in self?.store.openReference(visible[offset]) }
                row.isHidden = false
            } else {
                row.isHidden = true
                row.onClick(nil)
            }
        }
        if !refsBox.arrangedSubviews.contains(moreLabel) { refsBox.addArrangedSubview(moreLabel) }
        moreLabel.stringValue = extra > 0 ? "외 \(extra)개" : ""
        moreLabel.isHidden = extra <= 0

        var height = CGFloat(visible.count) * SidebarMetrics.refRow
        if extra > 0 { height += 16 }
        if refs.isEmpty { height = 0 }
        refsHeight.constant = store.backlinksExpanded ? height : 0
        refsBox.isHidden = height == 0
    }

    func refresh() {
        table?.reloadData()
        selectRow(forCurrentDoc: true)
        folderLabel?.stringValue = store.folder?.lastPathComponent ?? ""
        folderLabel?.toolTip = store.folder?.path
        countLabel?.stringValue = store.docs.isEmpty ? "" : "\(store.docs.count)"
        syncSortControls()
        refreshRefs()
    }

    private func selectRow(forCurrentDoc: Bool) {
        guard let table, !updatingSelection else { return }
        let docs = store.visibleDocs
        guard let current = store.current, let index = docs.firstIndex(of: current) else {
            if forCurrentDoc { table.deselectAll(nil) }
            return
        }
        if table.selectedRow != index {
            updatingSelection = true
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if table.numberOfRows > index {
                table.scrollRowToVisible(index)
            }
            updatingSelection = false
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.visibleDocs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let docs = store.visibleDocs
        guard row < docs.count else { return nil }
        let doc = docs[row]
        let id = NSUserInterfaceItemIdentifier("DocCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DocCellView) ?? {
            let c = DocCellView()
            c.identifier = id
            return c
        }()
        let isCurrent = doc.id == store.current?.id
        cell.configure(title: doc.title,
                       subtitle: doc.modifiedShort,
                       selected: isCurrent,
                       dirty: isCurrent && store.isDirty)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        let docs = store.visibleDocs
        guard row < docs.count else { return }
        store.select(docs[row])
    }

    func controlTextDidChange(_ obj: Notification) {
        store.search = search.stringValue
    }

    // MARK: - Drag in

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let url = urls.first else { return false }
        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            store.setFolder(url)
        } else {
            store.openExternal(url.path)
        }
        return true
    }

    // MARK: - Menu / buttons

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Finder에서 보기", action: #selector(revealSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "이름 변경…", action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "휴지통으로 이동", action: #selector(deleteSelected(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    private func selectedDoc() -> Doc? {
        let row = table.selectedRow
        guard row >= 0, row < store.visibleDocs.count else { return nil }
        return store.visibleDocs[row]
    }

    @objc private func revealSelected(_ sender: Any?) {
        guard let doc = selectedDoc() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([doc.url])
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard let doc = selectedDoc() else { return }
        if doc.id != store.current?.id { store.select(doc) }
        store.renameCurrent()
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let doc = selectedDoc() else { return }
        if doc.id != store.current?.id { store.select(doc) }
        store.deleteCurrent()
    }

    @objc private func newDocument(_ sender: Any?) { store.newDocument() }
    @objc private func openFolder(_ sender: Any?) { store.openFolderPanel() }
    @objc private func refresh(_ sender: Any?) { store.reloadList(); NSApp.activate(ignoringOtherApps: true) }
    @objc private func revealFolder(_ sender: Any?) { store.openFolderInFinder() }
}

/// 참조 목록의 한 행: 누가 왜 이 노트를 가리키는지 보여주고, 클릭하면 그 노트로 갑니다.
/// `NSButton` 대신 직접 그리는 이유는 두 줄(제목 + 문맥) 레이아웃과 hover 배경 때문입니다.
private final class RefRowView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        snippet.font = .systemFont(ofSize: 9.5)
        snippet.textColor = .tertiaryLabelColor
        snippet.lineBreakMode = .byTruncatingTail
        for sub in [icon, title, snippet] { sub.translatesAutoresizingMaskIntoConstraints = false }

        let text = NSStackView(views: [title, snippet])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(text)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SidebarMetrics.refRow),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(ref: Reference) {
        icon.image = NSImage(systemSymbolName: ref.kind.symbol, accessibilityDescription: ref.kind.label)
        title.stringValue = ref.fromTitle
        snippet.stringValue = ref.snippet.isEmpty ? "줄 \(ref.line)" : ref.snippet
        toolTip = "\(ref.kind.label) · \(ref.fromTitle) \(ref.line)줄\n\(ref.snippet)"
        setAccessibilityLabel(ref.fromTitle)
    }

    func onClick(_ action: (() -> Void)?) { self.action = action }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { highlight(true) }
    override func mouseExited(with event: NSEvent) { highlight(false) }
    override func mouseDown(with event: NSEvent) { highlight(true, pressed: true) }

    override func mouseUp(with event: NSEvent) {
        highlight(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    private func highlight(_ on: Bool, pressed: Bool = false) {
        guard let layer else { return }
        if !on { layer.backgroundColor = NSColor.clear.cgColor; return }
        layer.backgroundColor = (pressed ? NSColor.selectedContentBackgroundColor : NSColor.quaternaryLabelColor).cgColor
        if pressed {
            title.textColor = .selectedMenuItemTextColor
            snippet.textColor = NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75)
        } else {
            title.textColor = .labelColor
            snippet.textColor = .tertiaryLabelColor
        }
    }
}

private enum SidebarMetrics { static let refRow: CGFloat = 32 }

private final class DocCellView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        subtitle.font = .systemFont(ofSize: 9.5)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(text)
        addSubview(dot)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            text.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String, selected: Bool, dirty: Bool) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        self.subtitle.isHidden = subtitle.isEmpty
        icon.image = NSImage(systemSymbolName: selected ? "doc.text.fill" : "doc.text", accessibilityDescription: nil)
        icon.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        self.title.textColor = selected ? .labelColor : .secondaryLabelColor
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.isHidden = !dirty
    }
}

extension Doc {
    var modifiedShort: String {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        return date.abbreviated
    }
}
