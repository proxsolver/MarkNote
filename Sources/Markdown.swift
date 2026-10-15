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
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(body.joined(separator: "\n")))</code></pre>")
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

            // Lists (unordered / ordered, with task checkboxes)
            if let marker = listMarker(trimmed) {
                flush()
                let ordered = marker.ordered
                var items: [(text: String, task: String?)] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        // A blank line only ends the list if the next line is not a continuation.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        if j >= lines.count { break }
                        let next = lines[j].trimmingCharacters(in: .whitespaces)
                        if listMarker(next) == nil { break }
                        i = j
                        continue
                    }
                    guard let m = listMarker(t), m.ordered == ordered else {
                        // lazy continuation of the previous item
                        if !t.hasPrefix("#"), items.isEmpty == false {
                            items[items.count - 1].text += " " + t
                            i += 1
                            continue
                        }
                        break
                    }
                    var body = m.body
                    var task: String? = nil
                    if body.hasPrefix("[ ]") { task = " "; body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    else if body.lowercased().hasPrefix("[x]") { task = "x"; body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                    items.append((body, task))
                    i += 1
                }
                let tag = ordered ? "ol" : "ul"
                var html = "<\(tag)>\n"
                for item in items {
                    let content: String
                    if let task = item.task {
                        let checked = task.lowercased() == "x" ? " checked" : ""
                        content = "<label><input type=\"checkbox\" disabled\(checked)> <span>\(renderInline(item.text))</span></label>"
                    } else {
                        content = renderInline(item.text)
                    }
                    html += "<li>\(content)</li>\n"
                }
                html += "</\(tag)>"
                out.append(html)
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// A self-contained page used for preview and export.
    static func page(title: String, body: String, dark: Bool, docBaseURL: URL?, bridge: Bool = false) -> String {
        _ = docBaseURL
        return """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css(dark: dark))</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        \(bridge ? bridgeScript : "")
        </body>
        </html>
        """
    }

    static let bridgeScript = """
    <script>
    window.__set = function (h) { var a = document.querySelector('article.markdown-body'); if (a) a.innerHTML = h; };
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

    // MARK: - Blocks

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
        table { border-collapse: collapse; width: 100%; margin: 0 0 1.3em; font-size: .95em; }
        th, td { border: 1px solid \(palette.border); padding: 8px 12px; }
        th { background: \(palette.code); font-weight: 650; }
        tr:nth-child(even) td { background: rgba(127,127,127,.035); }
        input[type=checkbox] { margin-right: .35em; }
        ::selection { background: \(dark ? "rgba(127,179,255,.32)" : "rgba(47,111,237,.18)"); }
        """
    }
}
