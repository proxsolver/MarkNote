import Foundation

/// Minimal but practical Markdown → HTML converter used by the live preview
/// and the HTML export. Supports the syntax people actually put in notes.
enum Markdown {

    // MARK: - Public

    static func toHTML(_ source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
                          .replacingOccurrences(of: "\r", with: "\n")
                          .components(separatedBy: "\n")
        var out: [String] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            let body = paragraph.map { renderInline($0) }.joined(separator: "<br>\n")
            out.append("<p>\n\(body)\n</p>")
            paragraph.removeAll()
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flush(); i += 1; continue }

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence) { i += 1; break }
                    body.append(lines[i]); i += 1
                }
                if lang.lowercased() == "mermaid" {
                    // Mermaid reads the element's text, so the escaped source is exactly right.
                    out.append("<div class=\"mermaid\">\(escape(body.joined(separator: "\n")))</div>")
                } else {
                    let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                    out.append("<pre><code\(cls)>\(escape(body.joined(separator: "\n")))</code></pre>")
                }
                continue
            }

            // Heading
            if let h = headingLevel(trimmed) {
                flush()
                let body = renderInline(h.text)
                out.append("<h\(h.level) id=\"\(anchor(h.text))\">\(body)</h\(h.level)>")
                i += 1
                continue
            }

            // Horizontal rule
            if isRule(trimmed) { flush(); out.append("<hr>"); i += 1; continue }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flush()
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    body.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append("<blockquote>\n<p>\(body.map(renderInline).joined(separator: "<br>\n"))</p>\n</blockquote>")
                continue
            }

            // Table: header row + separator row
            if isTableRow(raw), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = tableCells(raw)
                let aligns = tableCells(lines[i + 1]).map { cell -> String in
                    let left = cell.hasPrefix(":")
                    let right = cell.hasSuffix("-") && cell.hasSuffix(":")
                    if left && right { return "center" }
                    if right { return "right" }
                    return "left"
                }
                i += 2
                var rows: [[String]] = []
                while i < lines.count, isTableRow(lines[i]) {
                    rows.append(tableCells(lines[i])); i += 1
                }
                var html = "<table>\n<thead>\n<tr>"
                for (idx, cell) in header.enumerated() {
                    html += "<th style=\"text-align:\(idx < aligns.count ? aligns[idx] : "left")\">\(renderInline(cell))</th>"
                }
                html += "</tr>\n</thead>\n<tbody>\n"
                for row in rows {
                    html += "<tr>"
                    for (idx, cell) in row.enumerated() {
                        html += "<td style=\"text-align:\(idx < aligns.count ? aligns[idx] : "left")\">\(renderInline(cell))</td>"
                    }
                    html += "</tr>\n"
                }
                html += "</tbody>\n</table>"
                out.append(html)
                continue
            }

            // Lists (unordered / ordered / nested, with task checkboxes)
            if listMarker(trimmed) != nil {
                flush()
                var items: [ListItem] = []
                var open: [Int] = []          // indentation of each currently open level
                while i < lines.count {
                    let line = lines[i]
                    let t = line.trimmingCharacters(in: .whitespaces)

                    if t.isEmpty {
                        // A blank line only ends the list when what follows is not list content.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        if j >= lines.count { break }
                        let next = lines[j].trimmingCharacters(in: .whitespaces)
                        guard listMarker(next) != nil || indentOf(lines[j]) >= 2 else { break }
                        i = j
                        continue
                    }

                    let ind = indentOf(line)
                    if let m = listMarker(t) {
                        if open.isEmpty {
                            open.append(ind)
                        } else {
                            while open.count > 1, ind < open.last! { open.removeLast() }
                            if ind > open.last! { open.append(ind) }
                        }
                        var body = m.body
                        var task: String? = nil
                        if body.hasPrefix("[ ]") { task = " "; body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                        else if body.lowercased().hasPrefix("[x]") { task = "x"; body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                        items.append(ListItem(depth: open.count - 1, ordered: m.ordered, body: body, task: task))
                    } else if !items.isEmpty, ind >= 2, !t.hasPrefix("#"), !isRule(t), !t.hasPrefix(">") {
                        // Indented prose continues the item directly above it.
                        items[items.count - 1].body += " " + t
                    } else {
                        break
                    }
                    i += 1
                }
                var at = 0
                while at < items.count {
                    out.append(renderList(items, &at))
                }
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// How much of the offline renderer stack a page should carry.
    enum Visual {
        /// Plain prose — code fences stay text, no JS at all.
        case off
        /// Preview pane: load the vendored files through `marknote://vendor/…`.
        case preview
        /// Export: embed the vendored files (fonts as data URIs) in one HTML file.
        case inlined
    }

    /// A self-contained page used for preview and export.
    static func page(title: String, body: String, dark: Bool, docBaseURL: URL? = nil,
                     bridge: Bool = false, visual: Visual = .off, printing: Bool = false) -> String {
        _ = docBaseURL
        var head = "<style>\(css(dark: dark))</style>"
        var tail = ""

        switch visual {
        case .off:
            break
        case .preview:
            head += "\n" + Vendor.previewStyleTags(dark: dark)
            tail += Vendor.previewScriptTags(dark: dark)
        case .inlined:
            let styles = Vendor.exportStyles(dark: dark)
            if !styles.isEmpty { head += "\n<style>\(styles)</style>" }
            tail += Vendor.exportScripts(dark: dark)
        }
        // Last so these rules win over the vendored stylesheets above.
        if visual != .off { head += "\n<style>\(visualOverrides(dark: dark))</style>" }
        // 인쇄 규칙도 마지막: 종이에서는 팔레트 대신 이 값들이 이깁니다.
        if printing { head += "\n<style>\(PrintLayout.css)</style>" }

        return """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        \(head)
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        \(bridge ? bridgeScript : "")
        \(tail)
        </body>
        </html>
        """
    }

    /// Rules that keep the vendored styles from fighting the note layout.
    private static func visualOverrides(dark: Bool) -> String {
        let palette = dark ? (code: "#2a2c33", border: "#33353d", mute: "#9a9ca6")
                           : (code: "#f4f5f8", border: "#e6e8ee", mute: "#6b6f7b")
        return """
        pre code.hljs { background: transparent; padding: 0; display: block; overflow-x: auto; }
        .hljs { background: transparent; color: inherit; padding: 0; }
        .mermaid {
          margin: 0 0 1.3em; padding: 16px 14px; text-align: center;
          background: \(palette.code); border: 1px solid \(palette.border); border-radius: 12px;
          overflow-x: auto;
        }
        .mermaid svg { max-width: 100%; height: auto; }
        .mermaid.render-failed {
          text-align: left; white-space: pre-wrap; color: \(palette.mute);
          font: .86em ui-monospace, "SF Mono", Menlo, monospace;
        }
        .katex { font-size: 1.06em; }
        .katex-display { margin: 0 0 1.2em; overflow-x: auto; overflow-y: hidden; padding: .3em 0; }
        """
    }

    static let bridgeScript = """
    <script>
    window.__set = function (h) {
      var a = document.querySelector('article.markdown-body');
      if (a) a.innerHTML = h;
      if (window.__renderVisual) window.__renderVisual();
    };
    function __max() { return Math.max(1, document.documentElement.scrollHeight - window.innerHeight); }
    window.__fraction = function () { return window.scrollY / __max(); };
    window.__setQuiet = function (h, f) {
      window.__quiet = true;
      window.__set(h);
      if (typeof f === 'number') { window.scrollTo(0, f * __max()); }
      setTimeout(function () { window.__quiet = false; }, 80);
    };
    window.addEventListener('scroll', function () {
      if (window.__quiet) return;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scroll) {
        window.webkit.messageHandlers.scroll.postMessage(window.__fraction());
      }
    }, { passive: true });
    </script>
    """

    static func standaloneHTML(source: String, title: String, dark: Bool) -> String {
        page(title: title, body: toHTML(source), dark: dark, docBaseURL: nil)
    }

    /// 인쇄·PDF 전용 페이지. 화면 팔레트를 그대로 뽑으면 검은 배경에 얹은 옅은 글자가
    /// 종이 위에서 사라지므로, 이 페이지만 언제나 라이트로 그리고 용지 규칙을 덧붙입니다.
    static func printPage(title: String, body: String, docBaseURL: URL? = nil,
                          visual: Visual = .off) -> String {
        page(title: title, body: body, dark: false, docBaseURL: docBaseURL,
             visual: visual, printing: true)
    }

    /// Rewrites relative `src`/`href` values to absolute `file:` URLs so a page
    /// written outside the note folder (the browser preview) still finds images.
    static func absolutize(_ html: String, docURL: URL) -> String {
        let dir = docURL.deletingLastPathComponent()
        guard let re = try? NSRegularExpression(pattern: "(?i)\\b(src|href)=\"([^\"]+)\"") else { return html }
        let ns = html as NSString
        var patches: [(NSRange, String)] = []
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let value = ns.substring(with: match.range(at: 2))
            if value.contains(":") || value.hasPrefix("/") || value.hasPrefix("#") { return }
            patches.append((match.range(at: 2), dir.appendingPathComponent(value).standardizedFileURL.absoluteString))
        }
        var result = html
        for (range, replacement) in patches.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }

    // MARK: - Images inside an export

    /// Largest picture to base64 into one exported file. Beyond this the "document"
    /// is really a download, and most cameras never get near it.
    static let embedLimitEach = 8_000_000
    /// … and the running total for one note, so a folder of phone photos cannot make
    /// a 400 MB HTML file that no mail client will accept.
    static let embedLimitTotal = 64_000_000

    /// Image extensions we are willing to carry as a data URI. Anything else that
    /// looks like a local file (a linked page, a PDF) is a *link*, not a picture,
    /// and inlining it would hide it inside the prose.
    static let embeddableTypes = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "svg"]

    struct Embedded {
        let html: String
        let embedded: Int
        /// A picture we saw but could not carry: too big, missing, or outside the
        /// note's own folder. Its path is left in the file.
        let kept: Int
    }

    /// Puts the pictures *into* the exported file, so a note that was moved to
    /// `~/Desktop` or mailed to someone still shows them. Relative paths are
    /// resolved against the note's own folder; `http`, `data` and fragments are
    /// left exactly as they were, and a file that cannot be carried keeps its path
    /// rather than silently disappearing.
    static func embedImages(_ html: String, docURL: URL?,
                            maxEach: Int = embedLimitEach, maxTotal: Int = embedLimitTotal) -> Embedded {
        guard let dir = docURL?.deletingLastPathComponent(),
              let re = try? NSRegularExpression(pattern: "(?i)\\bsrc=\"([^\"]+)\"") else {
            return Embedded(html: html, embedded: 0, kept: 0)
        }
        let ns = html as NSString
        var patches: [(NSRange, String)] = []
        var embedded = 0, kept = 0, used = 0

        for match in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 2 else { continue }
            let value = ns.substring(with: match.range(at: 1))
            // Already self-contained, remote, an anchor, or served by the preview scheme.
            if value.contains(":") || value.hasPrefix("/") || value.hasPrefix("#") { continue }
            // `![a](assets/그%20파일.png)` is how a spaced filename survives Markdown,
            // so the path we look up is the decoded one.
            let decoded = value.removingPercentEncoding ?? value
            guard embeddableTypes.contains((decoded as NSString).pathExtension.lowercased()) else { continue }
            // A note that reaches above its own folder is the one case where carrying
            // the picture would be worse than leaving it: an exported file is often
            // mailed, and `../../` is how a note someone else sent you would slip a
            // private picture into it. The preview scheme refuses the same paths.
            if (decoded as NSString).pathComponents.contains("..") { kept += 1; continue }
            let candidate = Vendor.resolve(under: dir, relative: decoded)
            guard let source = candidate,
                  let data = DocumentBytes.read(source, maxBytes: maxEach),
                  used + data.count <= maxTotal,
                  let mime = mimeType(forImage: source) else {
                kept += 1
                continue
            }
            used += data.count
            embedded += 1
            patches.append((match.range(at: 1), "data:\(mime);base64,\(data.base64EncodedString())"))
        }

        var result = html
        for (range, replacement) in patches.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return Embedded(html: result, embedded: embedded, kept: kept)
    }

    /// `Vendor.mimeType` answers `application/octet-stream` for anything it does not
    /// know; a data URI with that type renders as a broken picture, so unknown
    /// extensions are refused instead.
    private static func mimeType(forImage url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard embeddableTypes.contains(ext) else { return nil }
        let mime = Vendor.mimeType(for: url)
        return mime.hasPrefix("image/") ? mime : nil
    }

    // MARK: - Blocks

    /// Extensions the app opens as notes (used for preview links and folder scan).
    static let documentExtensions = ["md", "markdown", "mdown"]

    static func isReadableTextFile(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Wiki links

    /// Small note names the folder currently holds, refreshed with every scan.
    /// Empty means "unknown", so nothing is painted as missing.
    static var noteIndex: Set<String> = []

    struct WikiLink {
        let href: String
        /// What the link reads when the author gave no alias.
        let text: String
        /// Normalised (`noteKey`) target note name, without extension — the backlink key.
        let name: String
        let resolved: Bool
    }

    /// Splits `[[노트]]`, `[[노트|라벨]]`, `[[노트#구절]]`, `[[#구절]]` into an href plus
    /// the pieces the backlink index needs. A fragment becomes a heading anchor so
    /// `[[가이드#원칙 6]]` lands on that heading in the preview.
    static func wikiLink(target: String, index: Set<String> = noteIndex) -> WikiLink {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let hash = trimmed.firstIndex(of: "#")
        let filePart = hash.map { String(trimmed[..<$0]) } ?? trimmed
        let fragment = (hash.map { String(trimmed[trimmed.index(after: $0)...]) } ?? "")
            .trimmingCharacters(in: .whitespaces)
        let name = filePart.trimmingCharacters(in: .whitespaces)
        let suffix = fragment.isEmpty ? "" : "#\(anchor(fragment))"

        guard !name.isEmpty else {
            return WikiLink(href: suffix, text: fragment, name: "", resolved: true)
        }
        let extended = documentExtensions.contains((name as NSString).pathExtension.lowercased())
        let path = extended ? name : name + ".md"
        let href = path.components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/") + suffix
        let key = ((name as NSString).deletingPathExtension as NSString).lastPathComponent.noteKey
        return WikiLink(href: href, text: name, name: key, resolved: index.isEmpty || index.contains(key))
    }

    /// Undo the escaping `escape(_:)` applied before inline rules run, so a note
    /// name containing `&` or a quote still matches the file on disk.
    private static func decodeEntities(_ s: String) -> String {
        var r = s
        // &amp; last, otherwise "&amp;lt;" would collapse twice.
        for (from, to) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                           ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            r = r.replacingOccurrences(of: from, with: to)
        }
        return r
    }

    private static func headingLevel(_ t: String) -> (level: Int, text: String)? {
        guard t.hasPrefix("#") else { return nil }
        var level = 0
        for ch in t {
            if ch == "#" { level += 1 } else { break }
        }
        guard level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let stripped = t.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    /// Leading indentation of a raw line, in columns (a tab counts as four).
    private static func indentOf(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    /// One list line with its nesting depth already resolved.
    private struct ListItem {
        let depth: Int
        let ordered: Bool
        var body: String
        let task: String?
    }

    /// Renders one list level — including the levels nested inside it — and moves
    /// `at` past every item it consumed. A same-depth change of list type closes
    /// this list so the caller can open a sibling.
    private static func renderList(_ items: [ListItem], _ at: inout Int) -> String {
        let depth = items[at].depth
        let ordered = items[at].ordered
        var html = "<\(ordered ? "ol" : "ul")>\n"
        while at < items.count {
            let item = items[at]
            // A dedent belongs to the list above; a deeper item or a change of list
            // type ends this run so the caller can open the right sibling.
            if item.depth != depth || item.ordered != ordered { break }
            at += 1

            var inner: String
            if let task = item.task {
                let checked = task.lowercased() == "x" ? " checked" : ""
                inner = "<label><input type=\"checkbox\" disabled\(checked)> <span>\(renderInline(item.body))</span></label>"
            } else {
                inner = renderInline(item.body)
            }
            // Everything deeper than this level nests in the item — as several
            // sibling lists when the writer switched between `-` and `1.` below it.
            while at < items.count, items[at].depth > depth {
                inner += "\n" + renderList(items, &at)
            }
            html += "<li>\(inner)</li>\n"
        }
        html += "</\(ordered ? "ol" : "ul")>"
        return html
    }

    private static func listMarker(_ t: String) -> (ordered: Bool, body: String)? {
        if t.hasPrefix("- ") { return (false, String(t.dropFirst(2))) }
        if t.hasPrefix("* ") { return (false, String(t.dropFirst(2))) }
        if t.hasPrefix("+ ") { return (false, String(t.dropFirst(2))) }
        if t == "-" || t == "*" || t == "+" { return (false, "") }
        var digits = ""
        var idx = t.startIndex
        while idx < t.endIndex, t[idx].isNumber { digits.append(t[idx]); idx = t.index(after: idx) }
        if !digits.isEmpty, idx < t.endIndex, t[idx] == "." || t[idx] == ")" {
            let body = t[t.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            return (true, body)
        }
        return nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count > 0, line.contains("|") || line.contains("-") else { return false }
        return cells.allSatisfy { cell in
            let c = cell.replacingOccurrences(of: " ", with: "")
            return c.count >= 1 && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func anchor(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").lowercased()
    }

    // MARK: - Inline

    private static func renderInline(_ raw: String) -> String {
        var s = escape(raw)
        var codes: [String] = []

        s = substitute(s, pattern: "`([^`]+)`") { m in
            codes.append(m[1] ?? "")
            return "\u{1F}C\(codes.count - 1)\u{1F}"
        }

        // Wiki links, resolved before the [text](url) rule so `[[…]]` never gets
        // mistaken for a link with a bracket label. The href stays an ordinary
        // relative ".md" path: in the preview it resolves through the
        // marknote://assets/doc/ root, and in an exported file it works as a
        // plain sibling link in a browser.
        s = substitute(s, pattern: #"\[\[([^\[\]\|\n]+)(?:\|([^\[\]\n]*))?\]\]"#) { m in
            let target = decodeEntities(m[1] ?? "")
            let alias = (m[2] ?? "").isEmpty ? nil : decodeEntities(m[2] ?? "")
            let link = wikiLink(target: target, index: noteIndex)
            let label = escape(alias ?? link.text)
            let state = link.resolved ? "wikilink" : "wikilink unresolved"
            let hint = link.resolved ? "" : " title=\"노트가 없습니다 — 저장하면 이 이름으로 생깁니다\""
            return "<a class=\"\(state)\" href=\"\(link.href)\" data-note=\"\(escape(target))\"\(hint)>\(label)</a>"
        }

        s = substitute(s, pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#) { m in
            "<img src=\"\(m[2] ?? "")\" alt=\"\(m[1] ?? "")\">"
        }

        s = substitute(s, pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#) { m in
            let href = m[2] ?? ""
            let external = href.hasPrefix("http") ? " target=\"_blank\" rel=\"noopener\"" : ""
            return "<a href=\"\(href)\"\(external)>\(m[1] ?? "")</a>"
        }

        s = substitute(s, pattern: #"<(https?://[^>\s]+)>"#) { m in
            "<a href=\"\(m[1] ?? "")\" target=\"_blank\" rel=\"noopener\">\(m[1] ?? "")</a>"
        }

        s = substitute(s, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1] ?? "")</strong>" }
        s = substitute(s, pattern: #"__([^_]+)__"#) { "<strong>\($0[1] ?? "")</strong>" }
        s = substitute(s, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#) { "<em>\($0[1] ?? "")</em>" }
        s = substitute(s, pattern: #"(?<![\w_])_([^_\n]+)_(?![\w_])"#) { "<em>\($0[1] ?? "")</em>" }
        s = substitute(s, pattern: #"~~([^~]+)~~"#) { "<del>\($0[1] ?? "")</del>" }
        s = substitute(s, pattern: #"\{\{([^}]+)\}\}"#) { "<mark>\($0[1] ?? "")</mark>" }

        s = tagChips(s)

        s = substitute(s, pattern: "\u{1F}C(\\d+)\u{1F}") { m in
            let idx = Int(m[1] ?? "0") ?? 0
            return "<code>\(idx < codes.count ? codes[idx] : "")</code>"
        }

        // Bare URLs that were not already linked.
        s = substitute(s, pattern: #"(?<!href=")(?<!")https?://[^\s<>()"]+"#) { m in
            let url = m[0] ?? ""
            return "<a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">\(url)</a>"
        }

        return s
    }

    /// `#태그`를 칩으로 바꿉니다. 인라인 규칙이 이미 만들어 놓은 HTML — 특히
    /// `<a href="…">…</a>` 같은 링크 — 은 통째로 건너뛰고, 그 사이의 텍스트만 대상으로
    /// 삼습니다. `escape(_:)`가 본문의 모든 `<`를 `&lt;`로 바꿔 놓았으니 이 단계에 남아
    /// 있는 `<`는 우리가 만든 마크업뿐입니다. 그래서 "마크업 밖인지" 판단이 정규식 하나로 끝난다.
    private static let htmlRunPattern = #"(?i)<a\b[^>]*>.*?</a>|</?[a-zA-Z][^>]*>"#

    private static func tagChips(_ input: String) -> String {
        guard let re = try? NSRegularExpression(pattern: htmlRunPattern) else { return input }
        let ns = input as NSString
        var out = ""
        var last = 0
        for match in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            out += chips(in: ns.substring(with: NSRange(location: last,
                                                        length: match.range.location - last)))
            out += ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        out += chips(in: ns.substring(from: last))
        return out
    }

    /// href는 문서 안 조각(`#tag-키`)입니다. 앱 안에서는 미리보기가 가로채 사이드바
    /// 필터로 쓰고, 내보낸 파일에서는 그냥 아무 데도 안 가는 앵커라 파일이 깨지지 않습니다.
    private static func chips(in text: String) -> String {
        substitute(text, pattern: Tags.pattern) { m in
            let name = m[1] ?? ""
            guard !name.isEmpty else { return m[0] ?? "" }
            return "<a class=\"tag\" href=\"#\(Tags.fragment(for: Tags.key(of: name)))\" data-tag=\"\(name)\">#\(name)</a>"
        }
    }

    private static func escape(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        return r
    }

    /// Regex replacement where the transform receives capture groups (index 0 = whole match).
    private static func substitute(_ input: String, pattern: String, _ transform: ([String?]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String?] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            result += transform(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Style

    private static func css(dark: Bool) -> String {
        let palette = dark ? (
            bg: "#1e1f24", fg: "#dcdde2", mute: "#9a9ca6", accent: "#7fb3ff",
            border: "#33353d", code: "#2a2c33", strong: "#f2f3f7"
        ) : (
            bg: "#ffffff", fg: "#22242b", mute: "#6b6f7b", accent: "#2f6fed",
            border: "#e6e8ee", code: "#f4f5f8", strong: "#000000"
        )

        return """
        :root { color-scheme: \(dark ? "dark" : "light"); }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 40px 34px 120px;
          background: \(palette.bg); color: \(palette.fg);
          font: 16px/1.75 -apple-system, "Apple SD Gothic Neo", "Pretendard", "Helvetica Neue", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        .markdown-body { max-width: 74ch; margin: 0 auto; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.3; font-weight: 650; margin: 1.7em 0 .55em; letter-spacing: -.01em; }
        h1 { font-size: 1.9em; margin-top: .2em; padding-bottom: .3em; border-bottom: 1px solid \(palette.border); }
        h2 { font-size: 1.42em; padding-bottom: .25em; border-bottom: 1px solid \(palette.border); }
        h3 { font-size: 1.18em; }
        h4 { font-size: 1.05em; }
        p { margin: 0 0 1.05em; }
        a { color: \(palette.accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        a.wikilink { text-decoration: none; }
        /* [[이름]]이 목록에 없는 노트를 가리킬 때: 회색 점선, 클릭하면 아무 일도 없습니다. */
        a.wikilink.unresolved { color: \(palette.mute); border-bottom: 1px dashed \(palette.mute); }
        a.wikilink.unresolved:hover { color: \(palette.accent); border-bottom-color: \(palette.accent); }
        /* #태그 칩. 미리보기에서 클릭하면 사이드바 필터가 되고, 내보낸 파일에서는 문서 안 조각일 뿐입니다. */
        a.tag {
          color: \(palette.accent); background: \(dark ? "rgba(127,179,255,.14)" : "rgba(47,111,237,.09)");
          border: 1px solid \(dark ? "rgba(127,179,255,.34)" : "rgba(47,111,237,.22)");
          border-radius: 999px; padding: .04em .5em; margin: 0 .04em;
          font-size: .87em; text-decoration: none; white-space: nowrap;
        }
        a.tag:hover { text-decoration: none; background: \(dark ? "rgba(127,179,255,.24)" : "rgba(47,111,237,.16)"); }
        h1 a.tag, h2 a.tag, h3 a.tag, h4 a.tag { vertical-align: .12em; }
        strong { font-weight: 700; color: \(palette.strong); }
        em { font-style: italic; }
        del { color: \(palette.mute); }
        mark { background: rgba(255, 214, 102, .55); color: inherit; padding: 0 .15em; border-radius: 3px; }
        ul, ol { margin: 0 0 1.05em; padding-left: 1.5em; }
        li { margin: .25em 0; }
        li > ul, li > ol { margin-bottom: 0; }
        code {
          font: .88em ui-monospace, "SF Mono", Menlo, monospace;
          background: \(palette.code); padding: .15em .4em; border-radius: 4px;
        }
        pre {
          background: \(palette.code); padding: 14px 16px; border-radius: 10px;
          overflow-x: auto; border: 1px solid \(palette.border); margin: 0 0 1.2em;
        }
        pre code { background: none; padding: 0; font-size: .86em; line-height: 1.6; }
        blockquote {
          margin: 0 0 1.2em; padding: .3em 1.1em;
          border-left: 3px solid \(palette.accent); color: \(palette.mute); background: rgba(127, 127, 127, .06);
          border-radius: 0 8px 8px 0;
        }
        hr { border: 0; border-top: 1px solid \(palette.border); margin: 2em 0; }
        img { max-width: 100%; border-radius: 10px; }
        .mermaid { margin: 0 0 1.2em; }
        .markdown-body .mermaid:not(:has(svg)) {
          font: .86em/1.65 ui-monospace, "SF Mono", Menlo, monospace;
          white-space: pre-wrap; text-align: left; color: \(palette.mute);
          background: \(palette.code); border: 1px solid \(palette.border);
          border-radius: 10px; padding: 13px 15px; overflow-x: auto;
        }
        table { border-collapse: collapse; width: 100%; margin: 0 0 1.3em; font-size: .95em; }
        th, td { border: 1px solid \(palette.border); padding: 8px 12px; }
        th { background: \(palette.code); font-weight: 650; }
        tr:nth-child(even) td { background: rgba(127,127,127,.035); }
        input[type=checkbox] { margin-right: .35em; }
        ::selection { background: \(dark ? "rgba(127,179,255,.32)" : "rgba(47,111,237,.18)"); }
        """
    }
}

/// 종이 위 레이아웃 — 인쇄와 PDF가 같은 수치를 쓰도록 한 곳에 모았습니다.
///
/// 화면용 `css(dark:)`는 미리보기 팔레트이고, 여기는 잉크 이야기입니다. 웹뷰가 이 폭으로
/// 레이아웃되고, PDF 쪽 크기도 같은 값을 쓰므로 CSS 여백과 용지 여백이 어긋나지 않습니다.
enum PrintLayout {
    /// A4 세로, **CSS px** (96dpi). 1pt = 1/72인치, 1px = 1/96인치입니다.
    ///
    /// 단위부터 정해야 합니다. `createPDF`가 만드는 PDF의 눈금은 CSS 픽셀로 잡힙니다
    /// (인쇄 CSS에서 `padding: 46pt`로 적으면 종이에 61눈금으로 앉아 있었다). 그래서
    /// pt로 A4(595×842)를 그리고 뷰를 그 폭에 맞추면 글자가 종이 대비 1.33배 커지고
    /// 여백도 어긋납니다. A4를 px로 적고(px→pt는 0.75배) 여백까지 px로 통일하면
    /// 종이의 비율·글자 크기·여백이 의도한 그대로 나옵니다.
    static let pageWidth: CGFloat = 794
    static let pageHeight: CGFloat = 1123
    /// 종이의 네 가장자리. 좌우 62px ≒ 46.5pt, 상하 60px ≒ 45pt.
    static let sideMargin: CGFloat = 62
    static let topMargin: CGFloat = 60

    static var contentWidth: CGFloat { pageWidth - sideMargin * 2 }
    /// 한 쪽에 잉크가 앉을 수 있는 세로 폭.
    static var contentHeight: CGFloat { pageHeight - topMargin * 2 }
    static var layoutSize: CGSize { CGSize(width: pageWidth, height: pageHeight) }
    static var pageRect: CGRect { CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight) }

    /// 실제 프린터에 넘길 NSPrintInfo는 pt를 쓰므로 숫자를 다시 환산합니다.
    static func toPoints(_ px: CGFloat) -> CGFloat { px * 72 / 96 }

    /// 인쇄 규칙. 화면 팔레트보다 나중에 들어오므로 언제나 이쪽이 이깁니다.
    ///
    /// 여백은 `@page`가 아니라 `html`의 padding 한 곳에만 적습니다. PDF를 만들 때는
    /// `@page`가 먹지 않고(종이 눈금만 정해집니다), 실제 인쇄에서는 padding이 종이의
    /// 여백이 됩니다. 두 갈래가 같은 숫자를 한 번만 쓰라는 뜻이고, 스크롤바가 폭을
    /// 갉아먹지 않게 숨깁니다 — 안 그러면 오른쪽 여백만 17px 어색해집니다.
    static var css: String {
        """
        @page { size: \(Int(pageWidth))px \(Int(pageHeight))px; margin: 0; }
        :root { color-scheme: light; }
        html {
          background: #ffffff; padding: \(Int(topMargin))px \(Int(sideMargin))px;
          overflow: hidden;
        }
        body {
          margin: 0; padding: 0; background: #ffffff !important; color: #16181d;
          font-size: 11.5pt; line-height: 1.62;
          -webkit-print-color-adjust: exact; print-color-adjust: exact;
        }
        ::-webkit-scrollbar { display: none; width: 0; height: 0; }
        .markdown-body { max-width: none; }
        h1 { font-size: 1.5em; } h2 { font-size: 1.26em; } h3 { font-size: 1.1em; } h4 { font-size: 1em; }
        h1, h2, h3, h4 { break-after: avoid; }
        p, li { orphans: 2; widows: 2; }
        pre, blockquote, table, img, .mermaid, hr { break-inside: avoid; }
        thead { display: table-header-group; }
        a { color: #1a4fbf; }
        a.wikilink.unresolved { color: #5a5f6a; border-bottom-color: #b3b8c2; }
        a.tag {
          color: #22314f; background: #eef1f6; border-color: #c9cdd6;
          -webkit-print-color-adjust: exact; print-color-adjust: exact;
        }
        code { background: #f5f6f8 !important; color: #16181d; border-radius: 3px; }
        pre { background: #f7f8fa !important; border: 1px solid #d7dae1; }
        pre code { background: none !important; }
        .hljs { background: transparent !important; color: inherit; }
        blockquote { color: #3c4048; background: #f6f7f9; border-left-color: #9aa0ad; }
        th { background: #f1f3f6 !important; }
        th, td { border-color: #c9cdd6; }
        hr { border-top-color: #c9cdd6; }
        mark { background: #ffe9a8 !important; color: #16181d; }
        img { max-width: 100%; }
        .katex { color: #16181d; }
        """
    }
}
