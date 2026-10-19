import AppKit
import Quartz
import UniformTypeIdentifiers

struct Doc: Hashable, Identifiable {
    let url: URL
    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var fileName: String { url.lastPathComponent }
    var parentName: String { url.deletingLastPathComponent().lastPathComponent }
    var isNested: Bool { url.deletingLastPathComponent().lastPathComponent != "" }
}

enum FormatCommand {
    case bold, italic, strike, inlineCode, codeBlock, link, wikiLink, hr, quote, ul, ol, clearHeading
    case heading(Int)
}

enum StoreEvent {
    case docs, document, text, ui, links
}

/// Sidebar ordering. `created` falls back to the modification date on volumes
/// that do not carry a birth time.
enum DocSort: String, CaseIterable {
    case title, modified, created

    var label: String {
        switch self {
        case .title: return "이름"
        case .modified: return "최근 수정"
        case .created: return "생성일"
        }
    }
}

private enum Keys {
    static let folder = "folderPath"
    static let lastDoc = "lastDocPath"
    static let preview = "previewVisible"
    static let recents = "recentDocs"
    static let fontSize = "editorFontSize"
    static let autosave = "autosaveEnabled"
    static let sync = "scrollSync"
    static let visual = "visualEnabled"
    static let sort = "docsSort"
    static let sortAsc = "docsSortAscending"
    static let refsExpanded = "backlinksExpanded"
    static let history = "historyEnabled"
}

/// All app state and file work lives here. Views subscribe with `on(_:)`.
final class Store: NSObject {
    static let shared = Store()

    weak var window: NSWindow?
    weak var editor: NSTextView?

    private(set) var folder: URL?
    private(set) var docs: [Doc] = []
    private(set) var current: Doc?
    private(set) var text = ""
    private(set) var isDirty = false
    private(set) var savedAt: Date?
    private(set) var externallyChanged = false

    var search = "" { didSet { emit(.docs) } }

    var previewVisible: Bool {
        didSet { defaults.set(previewVisible, forKey: Keys.preview); emit(.ui) }
    }

    var autosaveEnabled: Bool {
        didSet {
            defaults.set(autosaveEnabled, forKey: Keys.autosave)
            emit(.ui)
            if autosaveEnabled { scheduleSave() }
        }
    }

    var scrollSync: Bool {
        didSet { defaults.set(scrollSync, forKey: Keys.sync); emit(.ui) }
    }

    /// Mermaid / 코드 색상 / 수식 렌더링. 꺼 두면 순수 텍스트 미리보기로 돌아갑니다.
    var visualEnabled: Bool {
        didSet {
            defaults.set(visualEnabled, forKey: Keys.visual)
            emit(.document)
            emit(.ui)
        }
    }

    var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: Keys.fontSize); Theme.size = fontSize; emit(.ui) }
    }

    /// 사이드바 정렬 기준. 고르면 즉시 목록을 다시 만들고 설정에 기억합니다.
    var sort: DocSort {
        didSet {
            defaults.set(sort.rawValue, forKey: Keys.sort)
            reloadList()
            emit(.ui)
        }
    }

    /// `false` = 최신/내림차순. 이름 정렬에서는 가나다·ABC 오름차순이 `true`입니다.
    var sortAscending: Bool {
        didSet {
            defaults.set(sortAscending, forKey: Keys.sortAsc)
            reloadList()
            emit(.ui)
        }
    }

    /// 사이드바 하단 '이 문서를 참조' 섹션 펼침 상태.
    var backlinksExpanded: Bool {
        didSet { defaults.set(backlinksExpanded, forKey: Keys.refsExpanded); emit(.links) }
    }

    /// 저장할 때마다 파일이 덮어쓰이기 직전의 바이트를 `.marknote-history`에 남깁니다.
    /// Drive·iCloud로 동기화되는 폴더는 이 숨은 폴더까지 함께 올라가므로, 메뉴에서
    /// 언제든 끌 수 있습니다(껐다고 기존 아카이브가 지워지지는 않습니다).
    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Keys.history); emit(.ui) }
    }

    var toast: String? {
        didSet {
            guard let toast, toast != oldValue else { return }
            emit(.ui)
            toastTask?.cancel()
            // @MainActor: a plain Task would resume on the cooperative pool and the
            // expiry below would rewrite the status bar from off the main thread.
            toastTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.toast == toast { self.toast = nil; self.emit(.ui) }
            }
        }
    }

    private var diskContent = ""
    private var diskModified: Date?
    private var pendingSave: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var watcher: Timer?
    private var loading = false
    private let defaults = UserDefaults.standard
    private var handlers: [StoreEvent: [() -> Void]] = [:]

    /// Per-file dates captured during the last folder scan, so sorting never
    /// stat()s the same path twice and `created` costs nothing extra.
    private var dates: [String: (modified: Date, created: Date)] = [:]

    override init() {
        previewVisible = defaults.object(forKey: Keys.preview) as? Bool ?? true
        autosaveEnabled = defaults.object(forKey: Keys.autosave) as? Bool ?? true
        scrollSync = defaults.object(forKey: Keys.sync) as? Bool ?? true
        visualEnabled = defaults.object(forKey: Keys.visual) as? Bool ?? true
        fontSize = defaults.object(forKey: Keys.fontSize) as? CGFloat ?? 14
        sort = DocSort(rawValue: defaults.string(forKey: Keys.sort) ?? "") ?? .modified
        sortAscending = defaults.object(forKey: Keys.sortAsc) as? Bool ?? false
        backlinksExpanded = defaults.object(forKey: Keys.refsExpanded) as? Bool ?? true
        historyEnabled = defaults.object(forKey: Keys.history) as? Bool ?? true
        super.init()
        Theme.size = fontSize
    }

    // MARK: - Observation

    func on(_ event: StoreEvent, _ handler: @escaping () -> Void) {
        handlers[event, default: []].append(handler)
    }

    /// Observers touch AppKit directly (table reload, web view, status bar), so they
    /// always run on the main thread. Anything emitted from a background task hops
    /// first instead of mutating a view hierarchy from two threads at once.
    private func emit(_ event: StoreEvent) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.emit(event) }
            return
        }
        handlers[event]?.forEach { $0() }
    }

    // MARK: - Filtered list

    var visibleDocs: [Doc] {
        var list = docs
        // 태그 필터가 걸려 있으면 그 태그를 단 노트만 남깁니다(사전 조회, O(노트 수)).
        if let key = tagFilter {
            let owning = tagIndex.paths(tagged: key)
            list = list.filter { owning.contains($0.url.path.pathKey) }
        }
        let q = search.trimmingCharacters(in: .whitespaces).noteKey
        guard !q.isEmpty else { return list }
        // Both sides normalised: the volume stores Hangul names decomposed, the
        // search field types them composed, and a raw `contains` finds nothing.
        return list.filter { $0.fileName.noteKey.contains(q) || $0.title.noteKey.contains(q) }
    }

    /// 태그까지 함께 좁힌 결과 — 사이드바 하단 카운트가 "이 태그 안에서"를 보여 준다.
    var filteredByTag: Bool { tagFilter != nil }

    var recents: [Doc] {
        (defaults.stringArray(forKey: Keys.recents) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Doc(url: $0) }
    }

    // MARK: - Boot

    func bootstrap() {
        if let path = defaults.string(forKey: Keys.folder), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path)
        }
        reloadList()

        if folder == nil, let path = defaults.string(forKey: Keys.lastDoc), FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            folder = url.deletingLastPathComponent()
            defaults.set(folder?.path ?? "", forKey: Keys.folder)
            reloadList()
            select(Doc(url: url))
        } else if let path = defaults.string(forKey: Keys.lastDoc) {
            let candidate = Doc(url: URL(fileURLWithPath: path))
            if docs.contains(where: { $0.id == candidate.id }) { select(candidate) }
        }

        // No usable "last document" (first run with a restored folder, or the file was moved):
        // open the newest note so the editor is never an empty void.
        if current == nil, let first = docs.first { select(first) }

        watcher = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkDisk()
        }
    }

    // MARK: - Folder

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이 폴더 사용"
        panel.message = "마크다운 문서 폴더를 선택하세요"
        panel.directoryURL = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            self.setFolder(url)
        }
    }

    func setFolder(_ url: URL) {
        flush()
        folder = url
        defaults.set(url.path, forKey: Keys.folder)
        current = nil
        reloadList()
        emit(.document)
        emit(.docs)
        toast = "\(url.lastPathComponent) · \(docs.count)개 문서"
        if let first = docs.first { select(first) }
    }

    func useDefaultFolder() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MarkNote", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setFolder(base)
    }

    // MARK: - Listing

    func reloadList() {
        guard let folder else { docs = []; dates = [:]; return }
        let fm = FileManager.default
        var found: [URL] = []
        if let en = fm.enumerator(at: folder,
                                 includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                                 options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                let ext = url.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" || ext == "mdown" { found.append(url) }
            }
        }
        // One stat pass per file: sorting then never touches the disk again, and
        // a birth time that the volume does not carry degrades to "modified".
        var stamps: [String: (modified: Date, created: Date)] = [:]
        for url in found {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            stamps[url.path] = (modified, values?.creationDate ?? modified)
        }
        dates = stamps
        docs = orderDocs(found.map { Doc(url: $0) })
        // The renderer needs to know which names point at a real note; the
        // scanner needs the same list, so both are refreshed from here.
        Markdown.noteIndex = Set(docs.map { $0.title.noteKey })
        emit(.docs)
        refreshReferences()
    }

    /// The open note stays pinned on top whatever the order — the sidebar doubles
    /// as "where am I" — and everything else follows the chosen key and direction.
    private func orderDocs(_ list: [Doc]) -> [Doc] {
        let currentPath = current?.url.path
        func ascending(_ a: Doc, _ b: Doc) -> Bool {
            switch sort {
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
                return a.url.path < b.url.path
            case .modified, .created:
                let lhs = stamp(a.url.path), rhs = stamp(b.url.path)
                if lhs != rhs { return lhs < rhs }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        return list.sorted { a, b in
            let pinnedA = a.url.path == currentPath, pinnedB = b.url.path == currentPath
            if pinnedA != pinnedB { return pinnedA }
            return sortAscending ? ascending(a, b) : ascending(b, a)
        }
    }

    private func stamp(_ path: String) -> Date {
        let record = dates[path] ?? (modified: .distantPast, created: .distantPast)
        switch sort {
        case .created: return record.created
        case .modified, .title: return record.modified
        }
    }

    // MARK: - Backlinks

    /// Other notes that point at a note, plus everything the open note points to.
    private(set) var linkIndex = LinkIndex()

    /// `#태그` 인덱스. 참조와 한 번의 훑기를 공유하므로 `.links`와 함께 갱신됩니다.
    private(set) var tagIndex = TagIndex()

    /// 사이드바를 이 태그를 단 노트만 보여주도록 좁힌다. nil이면 전체.
    var tagFilter: String? {
        didSet {
            guard tagFilter != oldValue else { return }
            emit(.docs)
        }
    }

    private let refScanner = ReferenceScanner()

    /// 어떤 노트를 가리키는 이름인지 다른 노트들이 얼마나 참조하는지.
    func backlinks(to doc: Doc) -> [Reference] { linkIndex.backlinks(to: doc.title.noteKey) }
    func backlinks(toTarget name: String) -> [Reference] { linkIndex.backlinks(to: name.noteKey) }
    func outgoingLinks(from doc: Doc) -> [Reference] { linkIndex.outgoing(from: doc.url.path) }

    /// 폴더를 한 번 훑어 참조·태그 인덱스를 다시 만듭니다. 읽기는 백그라운드, 방출은
    /// 메인 — 이전에 크래시로 배운 대로 뷰를 건드리는 순간은 메인뿐입니다.
    func refreshReferences() {
        let list = docs
        let stamps = dates
        refScanner.refresh(docs: list, dates: stamps) { [weak self] scan in
            guard let self else { return }
            self.linkIndex = scan.links
            self.tagIndex = scan.tags
            // 사라진 태그로 필터가 걸려 있으면 목록이 빈 채로 남으니 스스로 풀립니다.
            if let key = self.tagFilter, self.tagIndex.tag(key) == nil { self.tagFilter = nil }
            self.emit(.links)
        }
    }

    // MARK: - Tags

    /// 열려 있는 노트의 태그. 인덱스는 디스크를 읽으니 저장 전 본문보다 한 박자 늦습니다.
    func tags(for doc: Doc) -> [Tag] {
        tagIndex.keys(forPath: doc.url.path).compactMap { tagIndex.tag($0) }
    }

    var currentTags: [Tag] { current.map { tags(for: $0) } ?? [] }

    /// 같은 칩을 다시 누르면 필터가 풀린다(검색창과 같은 논리).
    func toggleTag(_ key: String) {
        let k = Tags.key(of: key)
        tagFilter = (tagFilter == k) ? nil : k
        guard let tag = tagFilter.flatMap({ tagIndex.tag($0) }) else {
            toast = "태그 필터 해제"
            return
        }
        toast = "#\(tag.name) · \(tag.count)개 노트"
    }

    func clearTagFilter() { tagFilter = nil }

    /// 사이드바 상단 칩: 필터 중이거나 태그가 있을 때만 보여 준다.
    var tagChips: [Tag] { tagIndex.sorted }

    // MARK: - Mention promotion (제목 언급 → 위키링크)

    /// 열려 있는 노트 본문에 그냥 적힌 다른 노트 제목을 `[[위키링크]]`로 바꿉니다.
    ///
    /// 편집기 텍스트를 한 단계로 갈아쓰므로 ⌘Z 한 번으로 통째로 되돌아가고, 저장 직전
    /// 바이트는 히스토리에 그대로 쌓입니다. 대상은 사이드바 목록(= 이 폴더의 노트)이고,
    /// 지금 열려 있는 노트 스스로는 빼립니다.
    @discardableResult
    func promoteMentions() -> Int {
        guard let doc = current else {
            toast = "노트를 먼저 열어 주세요 — 그 노트의 언급을 바꿉니다"
            return 0
        }
        guard let tv = editor, tv.isEditable else {
            toast = "편집기를 쓸 수 없습니다"
            return 0
        }
        let plan = Promotion.plan(text: tv.string,
                                  titles: docs.filter { $0.url.path != doc.url.path }.map(\.title),
                                  excluding: doc.title)
        guard plan.changed else {
            toast = "링크로 바꿀 제목 언급이 없습니다 — 다른 노트 이름 \(Promotion.minTitleLength)자 이상만 봅니다"
            return 0
        }
        let caret = Promotion.caret(tv.selectedRange().location, after: plan.hits)
        let restored = NSRange(location: min(caret, (plan.text as NSString).length), length: 0)
        Editing.replace(tv, NSRange(location: 0, length: (tv.string as NSString).length), plan.text,
                        selection: restored, undoLabel: "언급을 위키링크로")
        editorChanged(plan.text)
        let notes = Set(plan.hits.map(\.title)).count
        toast = "언급 \(plan.hits.count)개를 위키링크로 바꿨습니다 · 노트 \(notes)개 · ⌘Z로 되돌리기"
        return plan.hits.count
    }

    /// 승격할 곳이 얼마나 남았는지. 메뉴에 수를 적어두면 무엇을 누르는지 알립니다.
    var promotableCount: Int {
        guard let doc = current else { return 0 }
        return Promotion.plan(text: text,
                              titles: docs.filter { $0.url.path != doc.url.path }.map(\.title),
                              excluding: doc.title).count
    }

    /// `[[이름]]` 대상 찾기. 확장자 유무·대소문자·빈칸 차이에는 상관없이, 또 서브폴더에
    /// 있어도 목록에서 찾습니다.
    func doc(named target: String) -> Doc? {
        let key = Markdown.wikiLink(target: target, index: []).name
        let needle = key.isEmpty ? target.trimmingCharacters(in: .whitespaces).noteKey : key
        guard !needle.isEmpty else { return nil }
        if let exact = docs.first(where: { $0.title.noteKey == needle }) { return exact }
        return docs.first { $0.fileName.noteKey == needle + ".md" }
    }

    /// 위키링크를 따라 이동합니다. 없으면 만들지 않고 알려줍니다(사용자가 고른 동작).
    @discardableResult
    func openNote(named target: String) -> Bool {
        guard let doc = doc(named: target) else {
            toast = "『\(target)』 노트는 이 폴더에 없습니다"
            return false
        }
        select(doc)
        return true
    }

    /// 참조 행을 클릭했을 때. 파일이 이동/삭제돼 목록에 없으면 조용히 아무 일도 없습니다.
    @discardableResult
    func openReference(_ ref: Reference) -> Bool {
        let from = ref.fromPath.pathKey
        guard let doc = docs.first(where: { $0.url.path.pathKey == from }) else { return false }
        select(doc)
        return true
    }

    // MARK: - History

    /// 노트 옆 숨은 폴더에 이전 버전을 쌓아 두는 보관함. 경로를 언제나 노트에서 유도하므로
    /// 보관함 자체는 상태를 갖지 않습니다 — 폴더를 바꾸거나 다른 곳의 노트를 열어도 그대로 맞습니다.
    let noteHistory = NoteHistory()

    func historySnapshots(for doc: Doc) -> [Snapshot] { noteHistory.snapshots(for: doc) }
    var historySnapshots: [Snapshot] { current.map(historySnapshots(for:)) ?? [] }

    /// 예전 버전으로 되돌리기. 되돌리기 전 내용은 히스토리에 남으므로 이 동작도 되돌릴 수
    /// 있습니다. 보관 설정이 꺼져 있어도 이 한 장만은 반드시 남깁니다 — 사용자가 명시적으로
    /// 요청한 복원이 지금 쓴 내용을 삼켜서는 안 됩니다.
    @discardableResult
    func restoreHistory(_ snap: Snapshot) -> Bool {
        guard let doc = current else { return false }
        flush()
        let previous = DocumentBytes.read(doc.url)
        guard noteHistory.restore(snap, to: doc) else {
            toast = "복원 실패: 히스토리 파일을 읽을 수 없습니다"
            return false
        }
        if let previous { noteHistory.capture(previous, for: doc) }
        let modified = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        dates[doc.url.path] = (modified: modified, created: dates[doc.url.path]?.created ?? modified)
        reloadFromDisk()
        refreshReferences()
        toast = "히스토리에서 복원했습니다 · \(snap.savedAt.historyStamp)"
        return true
    }

    func toggleHistoryKeeping() {
        historyEnabled.toggle()
        toast = historyEnabled
            ? "이전 버전 보관 켜짐 · 노트 옆 \(NoteHistory.directoryName)"
            : "이전 버전 보관 꺼짐 · 이미 남은 버전은 그대로 있습니다"
    }

    /// 아카이브 폴더를 Finder에서 보여줍니다. 아직 한 장도 없으면 노트가 있는 폴더로 갑니다.
    func revealHistoryFolder() {
        guard let doc = current else { return }
        let snaps = noteHistory.snapshots(for: doc)
        if let dir = noteHistory.existingDirectory(for: doc) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            toast = "히스토리 폴더 · \(snaps.count)개"
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([doc.url])
            toast = "이 문서의 히스토리는 아직 없습니다"
        }
    }

    @discardableResult
    func clearHistory(of doc: Doc) -> Int {
        let removed = noteHistory.clear(doc)
        toast = removed == 0 ? "지울 히스토리가 없습니다" : "히스토리 \(removed)개를 지웠습니다"
        return removed
    }

    // MARK: - Selection

    func select(_ doc: Doc) {
        if doc.id == current?.id { return }
        flush()
        current = doc
        externallyChanged = false
        defaults.set(doc.url.path, forKey: Keys.lastDoc)
        pushRecent(doc.url)
        load(doc)
        // Re-order now rather than at the next disk poll, so the open note takes
        // its pinned place at once and the list never jumps a few seconds later.
        if !docs.isEmpty { docs = orderDocs(docs) }
        emit(.docs)
        emit(.document)
        emit(.ui)
        window?.makeFirstResponder(editor)
    }

    func openExternal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        folder = url.deletingLastPathComponent()
        defaults.set(folder?.path ?? "", forKey: Keys.folder)
        current = nil
        reloadList()
        select(Doc(url: url))
        window?.makeKeyAndOrderFront(nil)
    }

    private func load(_ doc: Doc) {
        loading = true
        let read = DocumentText.read(doc.url)
        diskContent = read.raw
        text = read.text
        diskModified = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        savedAt = diskModified
        isDirty = false
        loading = false
        emit(.text)
        if let notice = read.format.notice { toast = notice }
    }

    // MARK: - Create / rename / delete

    func newDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "새 문서.md"
        panel.directoryURL = folder
        panel.message = "새 문서의 이름을 정하세요"
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            let target = url.pathExtension.isEmpty ? url.appendingPathExtension("md") : url
            if !FileManager.default.fileExists(atPath: target.path) {
                let seed = "# \(target.deletingPathExtension().lastPathComponent)\n\n"
                try? seed.write(to: target, atomically: true, encoding: .utf8)
            }
            if self.folder == nil { self.folder = target.deletingLastPathComponent() }
            if self.folder != target.deletingLastPathComponent() {
                self.folder = target.deletingLastPathComponent()
                self.defaults.set(self.folder?.path ?? "", forKey: Keys.folder)
            }
            self.reloadList()
            self.current = nil
            self.select(Doc(url: target))
            if let tv = self.editor {
                let end = NSRange(location: (tv.string as NSString).length, length: 0)
                tv.setSelectedRange(end)
                tv.scrollRangeToVisible(end)
                self.window?.makeFirstResponder(tv)
            }
        }
    }

    func renameCurrent() {
        guard let doc = current, let window else { return }
        let alert = NSAlert()
        alert.messageText = "문서 이름 변경"
        alert.informativeText = doc.folderPath
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = doc.title
        field.placeholderString = "예) 회의 메모"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            let name = raw.hasSuffix(".md") ? raw : raw + ".md"
            let target = doc.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: doc.url, to: target)
                // Archived versions travel with the note, otherwise renaming `회의.md`
                // to `주간 회의.md` would strand every earlier version of it.
                self.noteHistory.move(from: doc, to: target)
                self.current = Doc(url: target)
                self.defaults.set(target.path, forKey: Keys.lastDoc)
                self.reloadList()
                self.emit(.document)
                self.toast = "이름을 바꿨습니다"
            } catch {
                self.toast = "이름 변경 실패: \(error.localizedDescription)"
            }
        }
    }

    func deleteCurrent() {
        guard let doc = current, let window else { return }
        let alert = NSAlert()
        alert.messageText = "'\(doc.fileName)'을(를) 휴지통으로 옮길까요?"
        alert.informativeText = "Finder에서 복원할 수 있습니다. 보관된 이전 버전은 \".marknote-history\"에 그대로 남습니다."
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: doc.url, resultingItemURL: nil)
                self.current = nil
                self.text = ""
                self.diskContent = ""
                self.isDirty = false
                self.reloadList()
                self.emit(.text)
                self.emit(.document)
                if let next = self.docs.first { self.select(next) }
            } catch {
                self.toast = "삭제 실패: \(error.localizedDescription)"
            }
        }
    }

    func revealInFinder() {
        guard let doc = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([doc.url])
    }

    func openFolderInFinder() {
        guard let folder else { return }
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Attachments (이미지 붙여넣기·드롭)

    /// Pictures from the clipboard or a drag are copied into `assets/` beside the
    /// open note and a Markdown link is written where the caret sits. The text goes
    /// in through `Editing.replace`, so it is a single undo step, and the autosave
    /// that follows archives the pre-edit bytes to 저장 히스토리 like any keystroke.
    ///
    /// `false` means "nothing image-like was offered" — the caller then lets AppKit
    /// paste the text it was handed, which is why the whole feature can hang off
    /// `paste(_:)` without touching normal pasting.
    @discardableResult
    func insertImages(_ incoming: [Attachments.Incoming], into tv: NSTextView) -> Bool {
        guard !incoming.isEmpty else { return false }
        guard let doc = current else {
            toast = "노트를 먼저 열어 주세요 — 이미지는 노트 옆 \(Attachments.directoryName)/에 저장됩니다"
            return true
        }

        let noteDirectory = doc.url.deletingLastPathComponent()
        var links: [String] = []
        var stored = 0
        var lastFailure: Attachments.Failure?

        for item in incoming {
            // Already living under this note's folder: reference it, do not copy it.
            if let source = item.source, let inPlace = Attachments.linkInPlace(source, noteDirectory: noteDirectory) {
                links.append(Attachments.markdown(alt: Attachments.alt(for: item.stem), src: inPlace))
                continue
            }
            switch Attachments.place(item.data, ext: item.ext, stem: item.stem, noteDirectory: noteDirectory) {
            case .success(let placed):
                links.append(Attachments.markdown(alt: Attachments.alt(for: item.stem), src: placed.relative))
                if !placed.reused { stored += 1 }
            case .failure(let failure):
                lastFailure = failure
            }
        }

        guard !links.isEmpty else {
            toast = Attachments.explain(lastFailure)
            return true
        }

        let block = links.joined(separator: "\n\n")
        let drop = Attachments.plan(in: tv.string as NSString, selection: tv.selectedRange(), block: block)
        Editing.replace(tv, drop.range, drop.string, selection: drop.selection, undoLabel: "이미지 붙여넣기")

        let head = links.count > 1 ? "이미지 \(links.count)개를 " : "이미지를 "
        toast = stored > 0
            ? head + "\(Attachments.directoryName)/에 저장하고 링크했습니다"
            : head + "링크만 넣었습니다 — 같은 이미지가 이미 \(Attachments.directoryName)/에 있습니다"
        return true
    }

    @discardableResult
    func insertPasteboardImage(_ pasteboard: NSPasteboard, into tv: NSTextView) -> Bool {
        insertImages(Attachments.read(pasteboard), into: tv)
    }

    // MARK: - Editing / saving

    func editorChanged(_ newValue: String) {
        guard !loading else { return }
        text = newValue
        isDirty = newValue != diskContent
        if isDirty { scheduleSave() } else { emit(.ui) }
        emit(.text)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        write()
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        if isDirty { write() }
    }

    private func scheduleSave() {
        guard autosaveEnabled, isDirty else { return }
        pendingSave?.cancel()
        // @MainActor matters: a bare Task resumes on the cooperative thread pool, and
        // write() then emits straight into sidebar.reloadData() — which is exactly the
        // off-main AppKit call that crashed a saved note (CoreAutoLayout abort).
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.write()
        }
    }

    private func write() {
        guard let doc = current else { return }
        let snapshot = text
        let snapshotData = Data(text.utf8)
        // Grab what is on disk *before* overwriting it: that byte-for-byte copy is the
        // previous version. `DocumentBytes` declines huge files so this main-thread read
        // stays a memcpy of a note, not of an accidental 400 MB blob.
        let previous = historyEnabled ? DocumentBytes.read(doc.url) : nil
        do {
            try snapshot.write(to: doc.url, atomically: true, encoding: .utf8)
            diskContent = snapshot
            isDirty = false
            savedAt = Date()
            diskModified = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            // Only after a successful save — a failed one must not invent a version that
            // never existed. Bytes that match what we just wrote (⌘S on a clean document)
            // are skipped, and `capture` drops a byte-identical newest copy as well, so
            // pressing save five times does not fill the archive with one version five times.
            if let previous, previous != snapshotData { noteHistory.capture(previous, for: doc) }
            // The just-saved note is the one file whose links may have changed, so
            // hand the scanner its new timestamp — otherwise the mtime cache would
            // keep serving the pre-save references.
            if let m = diskModified {
                dates[doc.url.path] = (modified: m, created: dates[doc.url.path]?.created ?? m)
            }
            refreshReferences()
            emit(.ui)
        } catch {
            toast = "저장 실패: \(error.localizedDescription)"
        }
    }

    private func checkDisk() {
        let before = docs.map(\.id)
        reloadList()
        _ = before
        guard let doc = current, !isDirty else { return }
        let modified: Date? = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let m = modified, let known = diskModified, m > known else { return }
        let read = DocumentText.read(doc.url)
        guard read.text != text else { return }
        diskContent = read.raw
        diskModified = m
        savedAt = m
        if editor?.window?.isKeyWindow == true {
            externallyChanged = true
            emit(.ui)
        } else {
            loading = true
            text = read.text
            loading = false
            emit(.text)
            emit(.document)
        }
    }

    func reloadFromDisk() {
        guard let doc = current else { return }
        let read = DocumentText.read(doc.url)
        diskContent = read.raw
        diskModified = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        loading = true
        text = read.text
        loading = false
        isDirty = false
        externallyChanged = false
        savedAt = Date()
        emit(.text)
        emit(.ui)
        toast = read.format.notice ?? "디스크 내용을 다시 읽었습니다"
        editor?.setNeedsDisplay(editor?.visibleRect ?? .zero)
    }

    func toggleAutosave() {
        autosaveEnabled.toggle()
        toast = autosaveEnabled ? "자동 저장 켜짐" : "자동 저장 꺼짐 · ⌘S로 저장하세요"
    }

    func togglePreview() {
        previewVisible.toggle()
    }

    func setPreview(_ on: Bool) {
        previewVisible = on
    }

    func clearRecents() {
        defaults.removeObject(forKey: Keys.recents)
        toast = "최근 기록을 지웠습니다"
    }

    func openRecent(_ doc: Doc) {
        folder = doc.url.deletingLastPathComponent()
        defaults.set(folder?.path ?? "", forKey: Keys.folder)
        reloadList()
        current = nil
        select(doc)
    }

    private func pushRecent(_ url: URL) {
        var list = defaults.stringArray(forKey: Keys.recents) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        defaults.set(Array(list.prefix(12)), forKey: Keys.recents)
    }

    // MARK: - Font

    func changeFontSize(_ delta: CGFloat) {
        fontSize = min(28, max(10, fontSize + delta))
    }

    func resetFontSize() {
        fontSize = 14
    }

    // MARK: - Commands

    func run(_ command: FormatCommand) {
        guard let tv = editor, tv.isEditable else { NSSound.beep(); return }
        switch command {
        case .bold: Editing.toggleWrap(tv, "**", "**", placeholder: "굵게")
        case .italic: Editing.toggleWrap(tv, "*", "*", placeholder: "기울임")
        case .strike: Editing.toggleWrap(tv, "~~", "~~", placeholder: "취소선")
        case .inlineCode: Editing.toggleWrap(tv, "`", "`", placeholder: "code")
        case .codeBlock: Editing.toggleCodeBlock(tv)
        case .link: Editing.insertLink(tv)
        case .wikiLink: Editing.toggleWrap(tv, "[[", "]]", placeholder: "노트 이름")
        case .hr: Editing.insertHR(tv)
        case .quote: Editing.toggleQuote(tv)
        case .ul: Editing.toggleList(tv, ordered: false)
        case .ol: Editing.toggleList(tv, ordered: true)
        case .heading(let level): Editing.setHeading(tv, level: level)
        case .clearHeading: Editing.clearHeading(tv)
        }
        editorChanged(tv.string)
    }

    // MARK: - Export

    func exportHTML() {
        saveExport(visual: .off)
    }

    /// Same file, but with the offline renderer stack embedded so diagrams,
    /// code colours and math survive outside this app.
    func exportHTMLRich() {
        guard Vendor.available else {
            toast = "렌더러 번들이 없어 가벼운 HTML만 내보냅니다"
            saveExport(visual: .off)
            return
        }
        saveExport(visual: .inlined)
    }

    /// The document both export paths hand to the save panel: one HTML file that
    /// carries its own pictures, so moving it to the Desktop or mailing it no longer
    /// breaks the images. `kept` counts the ones that stayed as a folder path.
    func exportedHTML(for doc: Doc, visual: Markdown.Visual) -> Markdown.Embedded {
        let page = Markdown.page(title: doc.title, body: Markdown.toHTML(text),
                                 dark: Theme.isDark, docBaseURL: doc.url, visual: visual)
        return Markdown.embedImages(page, docURL: doc.url)
    }

    private func saveExport(visual: Markdown.Visual) {
        guard let doc = current else { return }
        flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = doc.title + ".html"
        panel.directoryURL = doc.url.deletingLastPathComponent()
        panel.message = visual == .inlined
            ? "렌더러와 사진을 HTML 한 파일에 모두 담습니다 (약 4MB + 사진)"
            : "사진을 HTML 한 파일에 함께 담습니다"
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            let out = self.exportedHTML(for: doc, visual: visual)
            do {
                try out.html.write(to: url, atomically: true, encoding: .utf8)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                var note = "HTML 내보냄 · \(url.lastPathComponent) · \(ByteCount(size))"
                if out.embedded > 0 { note += " · 사진 \(out.embedded)장 동봉" }
                if out.kept > 0 { note += " · 사진 \(out.kept)장은 폴더 경로 그대로" }
                self.toast = note
            } catch {
                self.toast = "내보내기 실패: \(error.localizedDescription)"
            }
        }
    }

    func openInBrowser() {
        guard let doc = current else { return }
        let mode: Markdown.Visual = (visualEnabled && Vendor.available) ? .inlined : .off
        let html = Markdown.page(title: doc.title, body: Markdown.toHTML(text),
                                 dark: Theme.isDark, docBaseURL: doc.url, visual: mode)
        // Temp folder, so relative image paths have to be pinned to the note's own folder.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(doc.title + ".html")
        do {
            try Markdown.absolutize(html, docURL: doc.url).write(to: temp, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(temp)
            toast = "브라우저에서 열었습니다"
        } catch {
            toast = "임시 파일 쓰기 실패: \(error.localizedDescription)"
        }
    }

    func copyPlainMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        toast = "원문을 복사했습니다"
    }

    // MARK: - Print / PDF

    /// 뽑을 때 쓸 렌더링. 미리보기에서 머메이드·수식을 켰다면 종이에서도 돕니다(라이트로).
    private var printVisual: Markdown.Visual {
        (visualEnabled && Vendor.available) ? .preview : .off
    }

    /// 인쇄 패널을 띄웁니다. 화면이 다크여도 종이는 언제나 라이트로 나갑니다.
    func printCurrent() {
        guard let doc = current else { return }
        flush()
        toast = "인쇄용 페이지를 그리는 중…"
        PrintBridge.shared.printNote(doc: doc, text: text, visual: printVisual) { [weak self] message in
            self?.toast = message ?? "인쇄 패널을 열었습니다 · 용지 A4 세로"
        }
    }

    /// A4 PDF로 저장. 쪽이 길면 여러 쪽으로 나누고, 그림·다이어그램까지 하나의 파일에 담습니다.
    func exportPDF() {
        guard let doc = current else { return }
        flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = doc.title + ".pdf"
        panel.directoryURL = doc.url.deletingLastPathComponent()
        panel.message = "노트를 A4 쪽으로 나눠 PDF로 저장합니다 — 사진과 다이어그램이 함께 들어갑니다"
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            self.toast = "PDF로 그리는 중…"
            PrintBridge.shared.exportPDF(doc: doc, text: self.text, visual: self.printVisual) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url, options: .atomic)
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
                        // 쪽 수가 눈에 보이면 "정말 여러 장으로 나갔나"를 확인하지 않아도 됩니다.
                        let pages = PDFDocument(data: data)?.pageCount ?? 0
                        self.toast = "PDF 내보냄 · \(url.lastPathComponent) · \(pages)쪽 · \(ByteCount(size))"
                    } catch {
                        self.toast = "PDF 저장 실패: \(error.localizedDescription)"
                    }
                case .failure(let problem):
                    self.toast = problem.message
                }
            }
        }
    }

    func copyHTML() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Markdown.toHTML(text), forType: .string)
        toast = "HTML로 복사했습니다"
    }

    // MARK: - Stats

    var stats: String {
        let chars = text.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        let minutes = max(1, Int(ceil(Double(words) / 220.0)))
        if lines <= 1 { return "문자 \(chars) · 단어 \(words)" }
        return "문자 \(chars) · 단어 \(words) · 줄 \(lines) · 읽는 시간 약 \(minutes)분"
    }

    var relativePath: String {
        guard let doc = current else { return "" }
        if let folder, doc.url.path.hasPrefix(folder.path + "/") {
            return String(doc.url.path.dropFirst(folder.path.count + 1))
        }
        return doc.url.path
    }

    // MARK: - Helpers

    private func present(_ panel: NSSavePanel, _ done: @escaping (URL?) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { resp in done(resp == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin { finish($0) } }
    }

    private func present(_ panel: NSOpenPanel, _ done: @escaping (URL?) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { resp in done(resp == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin { finish($0) } }
    }
}

extension Doc {
    var folderPath: String { url.deletingLastPathComponent().path }
}
