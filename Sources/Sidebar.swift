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

        let subs: [NSView] = [header, search, scroll, footer]
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

            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 18),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
        ])

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
    }

    func refresh() {
        table?.reloadData()
        selectRow(forCurrentDoc: true)
        folderLabel?.stringValue = store.folder?.lastPathComponent ?? ""
        folderLabel?.toolTip = store.folder?.path
        countLabel?.stringValue = store.docs.isEmpty ? "" : "\(store.docs.count)"
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
