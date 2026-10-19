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

    /// `#태그` 칩 칸 — 검색/정렬 바와 문서 목록 사이.
    private var tagBar: TagChipBar!

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
        tagBar = TagChipBar(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        tagBar.onPick = { [weak self] key in self?.pickTag(key) }
        let refs = makeRefsPanel()

        let subs: [NSView] = [header, search, sortBar, tagBar, scroll, refs.header, refs.box, footer]
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

            scroll.topAnchor.constraint(equalTo: tagBar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            // 높이는 칩 칸이 intrinsic content size로 스스로 정합니다 — 태그가 없으면 0.
            tagBar.topAnchor.constraint(equalTo: sortBar.bottomAnchor, constant: 5),
            tagBar.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            tagBar.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
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
        store.on(.links) { [weak self] in
            self?.refreshRefs()
            self?.refreshTagBar()
        }
    }

    // MARK: - 태그 필터

    /// 칩을 누른 동작. nil은 "필터 해제" 칸입니다.
    private func pickTag(_ key: String?) {
        guard let key else {
            store.clearTagFilter()
            store.toast = "태그 필터 해제"
            return
        }
        store.toggleTag(key)
    }

    /// 인덱스가 갱신될 때마다(저장·폴더 갱신) 칩 칸을 다시 채웁니다. 목록 자체는
    /// `tagFilter`가 바뀔 때 `.docs`를 보내므로 여기서 `reloadData`를 부르지 않습니다.
    private func refreshTagBar() {
        guard let tagBar else { return }
        let chips = store.tagChips
        tagBar.set(entries: chips, selected: store.tagFilter)
        countLabel?.stringValue = chips.isEmpty
            ? "\(store.docs.count)"
            : "\(store.visibleDocs.count)/\(store.docs.count)"
        countLabel?.toolTip = store.tagFilter.map { "#\($0) 로 필터 중 — 칩을 다시 누르면 해제" }
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
        syncSortControls()
        refreshRefs()
        refreshTagBar()
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

/// 태그 칩이 줄지어 서는 칸.
///
/// 사이드바는 190pt 남짓이라 칩이 세로로 길게 늘어서면 문서 목록이 화면에서 사라집니다.
/// 그래서 폭에 맞춰 스스로 접고, `maxRows`를 넘으면 나머지를 "+N" 하나로 접어버립니다.
/// 높이는 intrinsic content size로 주니 상위 제약식(정렬 바 ↔ 목록 사이)은 모른 채로 끝납니다.
final class TagChipBar: NSView {
    /// 칩을 누르면 호출된다. nil은 "필터 해제".
    var onPick: ((String?) -> Void)?
    /// 지금 목록에 실제로 표시된 키(하나라도 잘려나갔는지 확인용).
    private(set) var shownKeys: [String] = []

    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private static let rowHeight: CGFloat = 18
    private static let gap: CGFloat = 4
    private static let sidePadding: CGFloat = 8
    /// 접히기 시작하는 줄. 3줄이면 목록이 아직 보인다.
    static let maxRows = 3

    private var specs: [Spec] = []
    private var chips: [NSButton] = []
    private var height: CGFloat = 0

    private struct Spec {
        let key: String?
        let label: String
        let on: Bool
        let clear: Bool
        var width: CGFloat {
            TagChipBar.measuredWidth(of: label) + (clear ? 2 : 0)
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func set(entries: [Tag], selected: String?) {
        var built: [Spec] = []
        if selected != nil {
            built.append(Spec(key: nil, label: "필터 해제", on: false, clear: true))
        }
        for tag in entries {
            let name = "#" + tag.name + (tag.count > 1 ? " \(tag.count)" : "")
            built.append(Spec(key: tag.key, label: name, on: tag.key == selected, clear: false))
        }
        specs = built
        // 즉시 배치합니다. 창 밖(테스트)에서도 높이가 정해져야 하고, 폭이 바뀌지 않는
        // 한 AppKit은 레이아웃을 다시 시키지 않아 칩 칸이 비어 보일 수 있습니다.
        layout()
    }

    override func layout() {
        super.layout()
        let available = max(72, bounds.width)
        let visible = plan(specs, available: available)

        while chips.count < visible.count {
            let chip = makeChip()
            chips.append(chip)
            addSubview(chip)
        }
        shownKeys = visible.compactMap { $0.key }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row = 0
        for (index, spec) in visible.enumerated() {
            if x > 0, x + spec.width > available {
                x = 0
                row += 1
                y = CGFloat(row) * (Self.rowHeight + Self.gap)
            }
            let button = chips[index]
            button.frame = NSRect(x: x, y: y, width: spec.width, height: Self.rowHeight)
            configure(button, spec: spec)
            x += spec.width + Self.gap
        }
        for index in visible.count..<chips.count { chips[index].isHidden = true }

        let rows = Self.rows(visible, available: available)
        let final = visible.isEmpty ? 0
            : CGFloat(rows) * Self.rowHeight + CGFloat(max(0, rows - 1)) * Self.gap
        if final != height {
            height = final
            invalidateIntrinsicContentSize()
        }
    }

    /// 전부 담으려는 시도부터 한 개씩 접어, `maxRows`에 들어오는 첫 모양을 고릅니다.
    /// 접힌 개수는 "+N" 칩 하나로 표시되니, 접을 때마다 자리 하나를 더 비워야 합니다.
    private func plan(_ list: [Spec], available: CGFloat) -> [Spec] {
        for keep in stride(from: list.count, through: 0, by: -1) {
            var candidate = Array(list.prefix(keep))
            if keep < list.count {
                candidate.append(Spec(key: nil, label: "+\(list.count - keep)", on: false, clear: true))
            }
            if Self.rows(candidate, available: available) <= Self.maxRows { return candidate }
        }
        return []
    }

    /// 폭 안에서 칩이 몇 줄이 되는지 — 배치와 같은 계산을 쓰면 재는 것과 어긋나지 않습니다.
    private static func rows(_ list: [Spec], available: CGFloat) -> Int {
        guard !list.isEmpty else { return 0 }
        var x: CGFloat = 0, rows = 1
        for spec in list {
            if x > 0, x + spec.width > available {
                x = 0
                rows += 1
            }
            x += spec.width + gap
        }
        return rows
    }

    private static func measuredWidth(of text: String) -> CGFloat {
        ceil(text.size(withAttributes: [.font: font]).width) + sidePadding * 2
    }

    private func makeChip() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(pick(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.font = Self.font
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = true
        return button
    }

    private func configure(_ button: NSButton, spec: Spec) {
        button.isHidden = false
        button.title = spec.label
        button.identifier = NSUserInterfaceItemIdentifier(spec.key ?? "")
        button.tag = spec.on ? 1 : 0
        let on = spec.on
        let clear = spec.clear
        button.layer?.backgroundColor = (on ? NSColor.controlAccentColor
                                            : clear ? NSColor.quaternaryLabelColor
                                                    : NSColor.controlColor.withAlphaComponent(0.6)).cgColor
        button.contentTintColor = on ? .white : (clear ? .secondaryLabelColor : .labelColor)
        button.toolTip = clear ? (spec.label == "필터 해제" ? "태그 필터를 걷어냅니다" : "태그가 많아 접혔습니다")
                              : "\(spec.label) — 클릭하면 이 태그만 봅니다"
        button.setAccessibilityLabel(spec.label)
    }

    @objc private func pick(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        onPick?(raw.isEmpty ? nil : raw)
    }
}

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
