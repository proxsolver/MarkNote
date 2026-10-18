import AppKit
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
        let q = search.trimmingCharacters(in: .whitespaces).noteKey
        guard !q.isEmpty else { return docs }
        // Both sides normalised: the volume stores Hangul names decomposed, the
        // search field types them composed, and a raw `contains` finds nothing.
        return docs.filter { $0.fileName.noteKey.contains(q) || $0.title.noteKey.contains(q) }
    }

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

    private let refScanner = ReferenceScanner()

    /// 어떤 노트를 가리키는 이름인지 다른 노트들이 얼마나 참조하는지.
    func backlinks(to doc: Doc) -> [Reference] { linkIndex.backlinks(to: doc.title.noteKey) }
    func backlinks(toTarget name: String) -> [Reference] { linkIndex.backlinks(to: name.noteKey) }
    func outgoingLinks(from doc: Doc) -> [Reference] { linkIndex.outgoing(from: doc.url.path) }

    /// 폴더를 한 번 훑어 참조 인덱스를 다시 만듭니다. 읽기는 백그라운드, 방출은
    /// 메인 — 이전에 크래시로 배운 대로 뷰를 건드리는 순간은 메인뿐입니다.
    func refreshReferences() {
        let list = docs
        let stamps = dates
        refScanner.refresh(docs: list, dates: stamps) { [weak self] built in
            guard let self else { return }
            self.linkIndex = built
            self.emit(.links)
        }
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
        alert.informativeText = "Finder에서 복원할 수 있습니다."
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
        do {
            try snapshot.write(to: doc.url, atomically: true, encoding: .utf8)
            diskContent = snapshot
            isDirty = false
            savedAt = Date()
            diskModified = (try? doc.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
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

    private func saveExport(visual: Markdown.Visual) {
        guard let doc = current else { return }
        flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = doc.title + ".html"
        panel.directoryURL = doc.url.deletingLastPathComponent()
        if visual != .off {
            panel.message = "그림·수식을 HTML 안에 직접 포함합니다 (약 4MB, 이미지는 문서 폴더에 둘 때만 열립니다)"
        }
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            let html = Markdown.page(title: doc.title, body: Markdown.toHTML(self.text),
                                     dark: Theme.isDark, docBaseURL: doc.url, visual: visual)
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                self.toast = "HTML 내보냄 · \(url.lastPathComponent) · \(ByteCount(size))"
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
