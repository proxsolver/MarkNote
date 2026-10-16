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
                     bridge: Bool = false, visual: Visual = .off) -> String {
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

    // MARK: - Blocks

    /// Extensions the app opens as notes (used for preview links and folder scan).
    static let documentExtensions = ["md", "markdown", "mdown"]

    static func isReadableTextFile(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
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
