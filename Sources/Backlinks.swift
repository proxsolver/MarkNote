import Foundation

/// Where one note points at another. A wiki link is the strongest evidence, a
/// Markdown link next, and a bare mention of the title the weakest — the sidebar
/// marks them apart so a passing reference is not mistaken for a real link.
struct Reference: Hashable {
    enum Kind: Int {
        case wikilink = 0, markdown, mention

        var symbol: String {
            switch self {
            case .wikilink:  return "link"
            case .markdown:  return "arrow.up.right"
            case .mention:   return "text.magnifyingglass"
            }
        }

        var label: String {
            switch self {
            case .wikilink:  return "위키링크"
            case .markdown:  return "링크"
            case .mention:   return "제목 언급"
            }
        }
    }

    let fromPath: String
    let fromTitle: String
    /// Normalised (`noteKey`) target note name without extension — the reverse-index key.
    let target: String
    let kind: Kind
    let line: Int
    let snippet: String
}

/// Reverse (backlinks) and forward (outgoing) lookups over one folder.
struct LinkIndex {
    private var byTarget: [String: [Reference]] = [:]
    private var bySource: [String: [Reference]] = [:]

    init(_ references: [Reference] = []) { ingest(references) }

    mutating func ingest(_ references: [Reference]) {
        var targets: [String: [Reference]] = [:]
        var sources: [String: [Reference]] = [:]
        for ref in references {
            targets[ref.target.noteKey, default: []].append(ref)
            sources[ref.fromPath.pathKey, default: []].append(ref)
        }
        for key in targets.keys { targets[key]?.sort(by: LinkIndex.ordered) }
        for key in sources.keys { sources[key]?.sort(by: LinkIndex.ordered) }
        byTarget = targets
        bySource = sources
    }

    /// Strongest evidence first, then Finder-like name order.
    static let ordered: (Reference, Reference) -> Bool = { a, b in
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        let names = a.fromTitle.localizedStandardCompare(b.fromTitle)
        if names != .orderedSame { return names == .orderedAscending }
        return a.line < b.line
    }

    func backlinks(to target: String) -> [Reference] { byTarget[target.noteKey] ?? [] }
    func outgoing(from path: String) -> [Reference] { bySource[path.pathKey] ?? [] }
    var referenceCount: Int { bySource.values.reduce(0) { $0 + $1.count } }
    var linkedNoteCount: Int { byTarget.keys.count }
}

/// 한 번의 폴더 훑기가 낳는 두 개의 표 — 참조와 태그는 같은 줄을 읽는다.
struct FolderScan {
    let links: LinkIndex
    let tags: TagIndex
}

/// Reads every note in the folder once and turns them into a `LinkIndex` and a
/// `TagIndex`.
///
/// The cache is touched only from the scanner's own serial queue, and the result
/// is handed back on the main thread, so no view is ever reached from a worker.
/// Reading also stays inside Foundation (`String(contentsOf:)`) on purpose: the
/// RTF decoder is AppKit, and AppKit does not belong on this queue — the crash
/// report in the README's history is exactly that mistake.
final class ReferenceScanner {
    private let queue = DispatchQueue(label: "com.marknote.references", qos: .utility, autoreleaseFrequency: .workItem)
    private var cache: [String: (modified: Date, refs: [Reference], tags: [String])] = [:]

    /// Skips notes above this size; a 1 MB wall of text is not worth indexing on
    /// every keystroke-triggered refresh.
    static let maxBytes = 1_000_000
    /// Above this many notes the "title mentioned somewhere" sweep is dropped —
    /// it is the only part that costs O(notes × bytes).
    static let mentionLimit = 250

    private static let wikiPattern = #"\[\[([^\[\]\|\n]+)(?:\|[^\]\n]*)?\]\]"#
    private static let mdPattern = #"\[[^\]]*\]\(<?([^)>\s]+)>?"#

    /// Deliver a fresh index for `docs` on the main thread. `onMain` runs on main.
    func refresh(docs: [Doc], dates: [String: (modified: Date, created: Date)],
                 onMain: @escaping (FolderScan) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let titles = docs.map { $0.title.noteKey }
            let mention = Self.mentionRegex(titles: titles)
            var collected: [Reference] = []
            var tagged: [(path: String, tags: [String])] = []
            var next: [String: (Date, [Reference], [String])] = [:]

            for doc in docs {
                let modified = dates[doc.url.path]?.modified ?? .distantPast
                if let cached = self.cache[doc.url.path], cached.modified == modified {
                    next[doc.url.path] = (cached.modified, cached.refs, cached.tags)
                    collected.append(contentsOf: cached.refs)
                    tagged.append((doc.url.path, cached.tags))
                    continue
                }
                let found = Self.gather(doc: doc, allTitles: titles, mention: mention)
                next[doc.url.path] = (modified, found.refs, found.tags)
                collected.append(contentsOf: found.refs)
                tagged.append((doc.url.path, found.tags))
            }
            self.cache = next
            let built = FolderScan(links: LinkIndex(collected), tags: TagIndex(tagged))
            DispatchQueue.main.async { onMain(built) }
        }
    }

    /// References only — the shape `scan` has always had, kept for tests and callers
    /// that do not care about tags.
    static func scan(doc: Doc, allTitles: [String], mention: NSRegularExpression?) -> [Reference] {
        gather(doc: doc, allTitles: allTitles, mention: mention).refs
    }

    /// One pass over a note's text. References and tags come out of the same read
    /// because both need the same "skip the fenced example" decision.
    static func gather(doc: Doc, allTitles: [String],
                       mention: NSRegularExpression?) -> (refs: [Reference], tags: [String]) {
        let size = (try? doc.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { return ([], []) }
        guard let text = try? String(contentsOf: doc.url, encoding: .utf8) else { return ([], []) }
        let myself = doc.title.noteKey
        var found: [String: Reference] = [:]

        func record(_ ref: Reference?) {
            guard let ref, ref.target != myself, !ref.target.isEmpty else { return }
            let key = ref.target.noteKey
            // Keep the strongest evidence per (source, target) pair.
            if let keep = found[key], keep.kind.rawValue <= ref.kind.rawValue { return }
            found[key] = ref
        }

        for line in NoteProse.prose(text) {
            for name in wikiTargets(in: line.text) {
                record(Reference(fromPath: doc.url.path, fromTitle: doc.title, target: name,
                                 kind: .wikilink, line: line.number, snippet: snippet(line.text, hint: name)))
            }
            for name in markdownTargets(in: line.text) {
                record(Reference(fromPath: doc.url.path, fromTitle: doc.title, target: name,
                                 kind: .markdown, line: line.number, snippet: snippet(line.text, hint: name)))
            }
            guard let mention else { continue }
            let ns = line.text as NSString
            for match in mention.matches(in: line.text, range: NSRange(location: 0, length: ns.length)) {
                let hit = ns.substring(with: match.range).noteKey
                guard allTitles.contains(hit) else { continue }
                record(Reference(fromPath: doc.url.path, fromTitle: doc.title, target: hit,
                                 kind: .mention, line: line.number, snippet: snippet(line.text, hint: hit)))
            }
        }
        return (Array(found.values), Tags.collect(text))
    }

    // MARK: - Extractors

    static func wikiTargets(in line: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: wikiPattern) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let raw = ns.substring(with: match.range(at: 1))
            let name = Markdown.wikiLink(target: raw, index: []).name
            return name.isEmpty ? nil : name
        }
    }

    static func markdownTargets(in line: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: mdPattern) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let href = ns.substring(with: match.range(at: 1))
            if href.contains(":") || href.hasPrefix("#") || href.hasPrefix("/") { return nil }
            let last = href.components(separatedBy: "/").last ?? href
            let name = (last as NSString).deletingPathExtension
            let ext = (last as NSString).pathExtension.lowercased()
            guard Markdown.documentExtensions.contains(ext), !name.isEmpty else { return nil }
            return name.noteKey
        }
    }

    /// `^(?!title)`-style sweep of every other note name in one regular expression.
    private static func mentionRegex(titles: [String]) -> NSRegularExpression? {
        let distinct = Set(titles.filter { $0.count >= 3 && $0.rangeOfCharacter(from: .alphanumerics) != nil })
        if distinct.count > mentionLimit { return nil }
        let alternatives = distinct
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .sorted { $0.count > $1.count }
            .joined(separator: "|")
        guard !alternatives.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: "(\(alternatives))", options: [.caseInsensitive])
    }

    /// The line itself, shortened around the match so the panel can show why a
    /// note is listed.
    static func snippet(_ line: String, hint: String, width: Int = 96) -> String {
        let flat = line.trimmingCharacters(in: .whitespaces)
        if flat.count <= width { return flat }
        let lower = flat.lowercased()
        let at = lower.range(of: hint.lowercased())?.lowerBound ?? flat.startIndex
        let head = flat.distance(from: flat.startIndex, to: at)
        let start = flat.index(flat.startIndex, offsetBy: max(0, head - width / 3))
        var out = String(flat[start...])
        if start != flat.startIndex { out = "…" + out }
        if out.count > width { out = String(out.prefix(width)) + "…" }
        return out
    }
}
