import AppKit

/// 사이드바의 참조 패널이 담을 수 있는 규모를 넘어서는 UI입니다. 히스토리는 행이 30개까지
/// 늘 수 있고, 되돌리기는 확인이 필요해서 창을 빌려 쓰는 편이 안전합니다. `⌃⌘H` 또는
/// 파일 ▸ 히스토리 ▸ 저장 히스토리… 로 부릅니다.
final class HistoryPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private let doc: Doc

    private var table: NSTableView!
    private var scroll: NSScrollView!
    private var caption: NSTextField!
    private var emptyLabel: NSTextField!
    private var restoreButton: NSButton!
    private var deleteButton: NSButton!

    /// 최신 → 오래된 순. 창을 여는 순간 한 번 읽고, 복원/비우기 뒤 다시 읽습니다.
    private(set) var rows: [Snapshot] = []

    static let rowHeight: CGFloat = 42

    init(store: Store, doc: Doc) {
        self.store = store
        self.doc = doc
        super.init(nibName: nil, bundle: nil)
        title = "저장 히스토리 · \(doc.title)"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))

        let heading = NSTextField(labelWithString: "『\(doc.title)』의 이전 버전")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        caption = NSTextField(labelWithString: "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let location = NSTextField(labelWithString:
            "보관 위치: \(NoteHistory.directoryName)/\(doc.title).snapshots · 최근 \(NoteHistory.limit)개")
        location.font = .systemFont(ofSize: 10)
        location.textColor = .tertiaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle

        table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.rowHeight = HistoryPanel.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        // 한 번 클릭으로 되돌려지는 사고를 막습니다 — 두 번 눌러야 동작합니다.
        table.doubleAction = #selector(rowActivated(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snap"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.layer?.borderWidth = 1
        scroll.layer?.cornerRadius = 6

        emptyLabel = NSTextField(labelWithString: "아직 이전 버전이 없습니다. 저장할 때마다 여기에 남습니다.")
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let texts = NSStackView(views: [heading, caption, location])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let folderButton = pushButton("히스토리 폴더", #selector(revealFolder(_:)))
        deleteButton = pushButton("히스토리 비우기", #selector(clearHistory(_:)))
        let close = pushButton("닫기", #selector(closeSheet(_:)))
        close.keyEquivalent = "\u{1b}"
        restoreButton = pushButton("이 버전으로 되돌리기", #selector(restoreSelected(_:)))
        restoreButton.keyEquivalent = "\r"
        restoreButton.isEnabled = false
        let buttons = NSStackView(views: [folderButton, deleteButton, spacerLike(), close, restoreButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for sub in [texts, scroll, emptyLabel, buttons] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),

            texts.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            texts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            texts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            scroll.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 가장 최신 버전을 미리 골라 두고, 버튼 문구로 대상을 밝힙니다. 실행은 확인창 뒤입니다.
        if snapshot(at: 0) != nil {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        syncRestoreButton()
    }

    private func pushButton(_ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: label, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11.5)
        return button
    }

    private func spacerLike() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: - Data

    /// 창을 열 때와 복원·비우기 후에 호출합니다. 개수가 바뀌면 문구도 같이 갱신합니다.
    func reload() {
        rows = store.historySnapshots(for: doc)
        caption.stringValue = HistoryRow.summary(rows)
        emptyLabel.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        deleteButton.isEnabled = !rows.isEmpty
        table?.reloadData()
        syncRestoreButton()
    }

    func snapshot(at row: Int) -> Snapshot? { rows.indices.contains(row) ? rows[row] : nil }

    private func syncRestoreButton() {
        guard let restoreButton else { return }
        let picked = snapshot(at: table?.selectedRow ?? -1)
        restoreButton.isEnabled = picked != nil
        restoreButton.title = picked.map { "되돌리기 · \($0.savedAt.historyStamp)" } ?? "이 버전으로 되돌리기"
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let snap = snapshot(at: row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("SnapCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SnapshotRowView) ?? {
            let c = SnapshotRowView()
            c.identifier = id
            return c
        }()
        cell.configure(title: HistoryRow.title(snap), preview: HistoryRow.preview(snap),
                       selected: tableView.selectedRow == row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { syncRestoreButton() }

    @objc private func rowActivated(_ sender: Any?) {
        guard let table, snapshot(at: table.clickedRow) != nil else { return }
        restoreSelected(sender)
    }

    // MARK: - Actions

    @objc private func restoreSelected(_ sender: Any?) {
        guard let snap = snapshot(at: table.selectedRow), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "이 버전으로 되돌릴까요?"
        alert.informativeText = """
        \(snap.savedAt.historyStamp) · \(HistoryRow.size(snap.bytes))
        지금 내용은 사라지지 않고 히스토리에 먼저 남습니다.
        """
        alert.addButton(withTitle: "되돌리기")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.store.restoreHistory(snap)
            self.endSheet()
        }
    }

    @objc private func revealFolder(_ sender: Any?) { store.revealHistoryFolder() }

    @objc private func clearHistory(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "이 문서의 히스토리를 지울까요?"
        alert.informativeText = """
        보관된 이전 버전 \(rows.count)개가 사라집니다. 문서 자체는 그대로입니다.
        \(NoteHistory.directoryName)/\(doc.title).snapshots
        """
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.store.clearHistory(of: self.doc)
            self.reload()
        }
    }

    @objc private func closeSheet(_ sender: Any?) { endSheet() }

    private func endSheet() {
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }
}

/// 히스토리의 한 행: 날짜·크기·경과와 그 버전의 첫 줄을 두 줄로 보여줍니다.
private final class SnapshotRowView: NSView {
    private let icon = NSImageView()
    private let main = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5

        icon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "이전 버전")
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor

        main.font = .systemFont(ofSize: 11.5, weight: .medium)
        main.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 10)
        preview.textColor = .tertiaryLabelColor
        preview.lineBreakMode = .byTruncatingMiddle

        let texts = NSStackView(views: [main, preview])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        addSubview(icon)
        addSubview(texts)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HistoryPanel.rowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, preview text: String, selected: Bool) {
        main.stringValue = title
        preview.stringValue = text.isEmpty ? "첫 줄 없음" : text
        layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        main.textColor = selected ? .selectedMenuItemTextColor : .labelColor
        preview.textColor = selected
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : .tertiaryLabelColor
        icon.contentTintColor = selected ? .selectedMenuItemTextColor : .secondaryLabelColor
        setAccessibilityLabel(title)
    }
}

extension HistoryPanel {
    /// 시트로 띄우기. 열어 둔 문서가 없으면(= 부팅 전) 조용히 무시됩니다.
    /// 호출자는 항상 메인 스레드(메뉴 액션)이며, 다른 컨트롤러들과 같은 관례를 따릅니다.
    static func present(store: Store, window: NSWindow) {
        guard let doc = store.current else { return }
        let panel = HistoryPanel(store: store, doc: doc)
        let sheet = NSWindow(contentViewController: panel)
        sheet.styleMask = [.titled, .resizable]
        sheet.tabbingMode = .disallowed
        sheet.title = "저장 히스토리"
        sheet.setContentSize(NSSize(width: 560, height: 420))
        window.beginSheet(sheet)
    }
}
