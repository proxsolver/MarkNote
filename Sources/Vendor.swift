import AppKit
import WebKit

/// Offline copies of the rendering libraries shipped inside the app bundle
/// (mermaid, highlight.js, KaTeX). Everything is served from disk — the
/// preview never issues a network request.
///
/// Layout inside `Contents/Resources/vendor/`:
///   mermaid.min.js, highlight.min.js, github.min.css, github-dark.min.css,
///   katex/{katex.min.css,katex.min.js,auto-render.min.js,fonts/*.woff2},
///   licenses/*, manifest.json
enum Vendor {

    /// Custom URL scheme used to hand these files (and images next to the open
    /// document) to the preview web view.
    static let scheme = "marknote"

    private static let fm = FileManager.default
    private static var textCache: [String: String] = [:]
    private static let readQueue = DispatchQueue(label: "com.marknote.vendor.read")

    /// Root of the vendored files. Overridable so tests and `--install`-free
    /// runs can point at the source tree.
    static var rootURL: URL = {
        if let custom = ProcessInfo.processInfo.environment["MARKNOTE_VENDOR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("vendor", isDirectory: true)
        if let bundled, fm.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: "Resources/vendor", isDirectory: true)
    }()

    static func file(_ relative: String) -> URL {
        rootURL.appendingPathComponent(relative)
    }

    static func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: file(relative).path)
    }

    /// True when the heavy renderers are actually available.
    static var available: Bool { exists("mermaid.min.js") }

    /// File contents, cached (used for self-contained exports).
    static func text(_ relative: String) -> String? {
        if let hit = readQueue.sync(execute: { textCache[relative] }) { return hit }
        let path = file(relative).path
        guard let data = fm.contents(atPath: path),
              let string = String(data: data, encoding: .utf8) else { return nil }
        readQueue.sync { textCache[relative] = string }
        return string
    }

    // MARK: - URLs

    /// Everything the preview loads lives under one host (`marknote://assets/…`),
    /// with `vendor/` and `doc/` as the two roots. One host means one origin, so
    /// KaTeX's font requests are same-origin and nothing trips WebKit's opaque
    /// response blocking for custom schemes.
    static let host = "assets"
    static let vendorPrefix = "vendor"
    static let docPrefix = "doc"

    static func vendorURL(_ relative: String) -> String {
        "\(scheme)://\(host)/\(vendorPrefix)/" + relative.split(separator: "/").map { encoded($0) }.joined(separator: "/")
    }

    /// Base URL a preview page is loaded with, or nil when there is no document.
    static func pageBaseURL(for directory: URL?) -> URL? {
        guard directory != nil else { return nil }
        return URL(string: "\(scheme)://\(host)/\(docPrefix)/")
    }

    /// Resolves a path inside a root, refusing anything that escapes it.
    static func resolve(under root: URL, relative: String) -> URL? {
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let path = candidate.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    private static func encoded(_ segment: Substring) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
    }

    // MARK: - Media types

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs":  return "text/javascript"
        case "css":        return "text/css"
        case "json":       return "application/json"
        case "svg":        return "image/svg+xml"
        case "html":       return "text/html"
        case "md", "markdown", "txt": return "text/plain"
        case "woff2":      return "font/woff2"
        case "woff":       return "font/woff"
        case "ttf":        return "font/ttf"
        case "png":        return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":        return "image/gif"
        case "webp":       return "image/webp"
        case "bmp":        return "image/bmp"
        case "avif":       return "image/avif"
        default:           return "application/octet-stream"
        }
    }

    static func isTextual(_ url: URL) -> Bool {
        ["js", "mjs", "css", "json", "svg", "html", "md", "markdown", "txt"]
            .contains(url.pathExtension.lowercased())
    }

    // MARK: - Self-contained export

    /// highlight.js theme + KaTeX stylesheet with the woff2 fonts inlined as data URIs.
    static func exportStyles(dark: Bool) -> String {
        var blocks: [String] = []
        if let theme = text(dark ? "github-dark.min.css" : "github.min.css") {
            blocks.append("/* highlight.js \(dark ? "github-dark" : "github") */\n" + theme)
        }
        if let katex = text("katex/katex.min.css") {
            blocks.append("/* KaTeX */\n" + inlineFonts(in: katex))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Rewrites every `src:url(fonts/X.woff2) … ,url(…woff) … ,url(…ttf) …`
    /// declaration down to a single base64 woff2, then drops leftover font URLs.
    private static func inlineFonts(in css: String) -> String {
        var result = css
        let pattern = #"url\((fonts/[^)]+\.woff2)\) format\("woff2"\)(?:,url\([^)]+\) format\("[^"]+"\))*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return stripFontURLs(result) }
        let ns = result as NSString
        var patches: [(NSRange, String)] = []
        re.enumerateMatches(in: result, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 2 else { return }
            let relative = ns.substring(with: match.range(at: 1))
            let fontURL = file("katex/" + relative)
            guard let data = fm.contents(atPath: fontURL.path) else { return }
            let replacement = "url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            patches.append((match.range, replacement))
        }
        for (range, replacement) in patches.reversed() {
            result = ns.replacingCharacters(in: range, with: replacement)
        }
        return stripFontURLs(result)
    }

    private static func stripFontURLs(_ css: String) -> String {
        css.replacingOccurrences(of: #"url\((?:\.\./)?fonts/[^)]+\)\s*format\("[^"]*"\)"#,
                                with: "", options: .regularExpression)
    }

    /// mermaid + highlight.js + KaTeX sources, ready to drop into `<script>` tags.
    static func exportScripts(dark: Bool) -> String {
        var out = ""
        for (key, label) in [("mermaid.min.js", "mermaid"),
                             ("highlight.min.js", "highlight.js"),
                             ("katex/katex.min.js", "KaTeX"),
                             ("katex/auto-render.min.js", "KaTeX auto-render")] {
            guard let source = text(key) else { continue }
            out += "<script>/* \(label) */\n" + unsafeguard(source) + "</script>\n"
        }
        out += "<script>\n" + visualBootstrap(dark: dark) + "\n</script>\n"
        return out
    }

    /// A file that ends in `</script>` would close the tag we are embedding it in.
    private static func unsafeguard(_ source: String) -> String {
        source.replacingOccurrences(of: "</script", with: "<\\/script", options: .literal)
    }
}

// MARK: - Preview wiring

extension Vendor {

    /// Runs mermaid / highlight.js / KaTeX over whatever is currently in the DOM.
    /// Each library is independent and failures are swallowed, so a broken
    /// diagram still leaves the readable source behind.
    static func visualBootstrap(dark: Bool) -> String {
        #"""
        (function () {
          if (window.mermaid) {
            try {
              window.mermaid.initialize({
                startOnLoad: false,
                securityLevel: 'strict',
                theme: '__THEME__',
                fontFamily: '-apple-system, "Apple SD Gothic Neo", "Pretendard", sans-serif'
              });
            } catch (e) {}
          }
          var queued = null;
          // Only one mermaid.render may be in flight, ever: the library measures text
          // through shared state, so a second concurrent call reads half-finished numbers
          // and its diagram comes out collapsed onto the first one. A module-level chain
          // covers the case paint() itself re-enters while an earlier batch is still
          // drawing (every keystroke schedules a new one).
          var mnChain = Promise.resolve();
          function paint() {
            queued = null;
            var root = document.querySelector('article.markdown-body') || document.body;
            if (window.hljs) {
              var codes = root.querySelectorAll('pre code[class*="language-"]');
              for (var i = 0; i < codes.length; i++) {
                var block = codes[i];
                if (block.dataset.hl === '1') continue;
                block.dataset.hl = '1';
                try { window.hljs.highlightElement(block); } catch (e) {}
              }
            }
            if (window.renderMathInElement) {
              try {
                window.renderMathInElement(root, {
                  throwOnError: false,
                  delimiters: [
                    { left: '$$', right: '$$', display: true },
                    { left: '\\[$', right: '$\\]', display: true },
                    { left: '$', right: '$', display: false },
                    { left: '\\(', right: '\\)', display: false }
                  ],
                  ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
                });
              } catch (e) {}
            }
            if (window.mermaid) {
              // Queue this paint's diagrams on the shared chain instead of calling
              // mermaid.run on them all at once: two renders in flight corrupt each
              // other's measurements (see mnChain). Still one call per diagram, so a
              // parse failure stays contained to its own block — a batched call aborts
              // the whole batch and skips elements already marked data-processed.
              var pending = root.querySelectorAll('.mermaid');
              var todo = [];
              for (var j = 0; j < pending.length; j++) {
                var node = pending[j];
                if (node.querySelector('svg') || node.getAttribute('data-mn-run') === '1') continue;
                node.setAttribute('data-mn-run', '1');
                todo.push({ el: node, source: node.textContent });
              }
              var renderOne = function (item) {
                return new Promise(function (resolve) {
                  var node = item.el;
                  var settled = false;
                  var timer = 0;
                  var finish = function () {
                    if (settled) return;
                    settled = true;
                    if (timer) clearTimeout(timer);
                    resolve();
                  };
                  // The preview replaces the article on every keystroke, so a queued
                  // node can already be detached; rendering into it would only waste
                  // the shared measurement element the next diagram needs.
                  if (!document.contains(node)) { finish(); return; }
                  var park = function (err) {
                    finish();
                    node.setAttribute('data-mn-run', '0');
                    node.classList.add('render-failed');
                    if (err) {
                      var msg = String((err.message || err)).split('\n')[0].slice(0, 160);
                      if (!window.__mermaidError) window.__mermaidError = msg;
                      node.setAttribute('data-mn-error', msg);
                    }
                    // A parse failure may leave mermaid's own error picture behind;
                    // when nothing was drawn, put the readable source back.
                    if (!node.querySelector('svg')) node.textContent = item.source;
                  };
                  // Serialising only helps while the queue keeps moving, so each render
                  // gets a deadline — a wedged one would block every later diagram.
                  // Healthy diagrams settle in a few hundred milliseconds.
                  timer = setTimeout(function () { park(new Error('render timeout')); }, 8000);
                  var done = function () {
                    if (node.querySelector('svg')) { node.setAttribute('data-mn-run', '1'); finish(); }
                    else park(null);
                  };
                  try {
                    var result = window.mermaid.run({ nodes: [node] });
                    if (result && typeof result.then === 'function') result.then(done, park);
                    else done();
                  } catch (e) {
                    park(e);
                  }
                });
              };
              for (var k = 0; k < todo.length; k++) {
                (function (item) { mnChain = mnChain.then(function () { return renderOne(item); }); })(todo[k]);
              }
            }
          }
          window.__renderVisual = function (now) {
            if (now) { if (queued) { clearTimeout(queued); queued = null; } paint(); return; }
            if (queued) return;
            queued = setTimeout(paint, 120);
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function () { window.__renderVisual(true); });
          } else {
            window.__renderVisual(true);
          }
        })();
        """#.replacingOccurrences(of: "__THEME__", with: dark ? "dark" : "default")
    }

    /// Stylesheets for the preview, kept in `<head>` so the app's own
    /// `visualOverrides` rules can still come after them.
    static func previewStyleTags(dark: Bool) -> String {
        guard available else { return "" }
        var tags = ""
        if exists("katex/katex.min.css") {
            tags += "<link rel=\"stylesheet\" href=\"\(vendorURL("katex/katex.min.css"))\">\n"
        }
        if exists(themeFile(dark: dark)) {
            tags += "<link rel=\"stylesheet\" href=\"\(vendorURL(themeFile(dark: dark)))\">\n"
        }
        return tags
    }

    static func themeFile(dark: Bool) -> String { dark ? "github-dark.min.css" : "github.min.css" }

    /// `<script src=…>` tags for the vendored libraries, in dependency order.
    static func previewScriptTags(dark: Bool) -> String {
        guard available else { return "" }
        var tags = ""
        for key in ["mermaid.min.js", "highlight.min.js", "katex/katex.min.js", "katex/auto-render.min.js"] where exists(key) {
            tags += "<script src=\"\(vendorURL(key))\"></script>\n"
        }
        tags += "<script>\n" + visualBootstrap(dark: dark) + "\n</script>"
        return tags
    }
}

/// Serves `marknote://assets/vendor/…` from the app bundle and
/// `marknote://assets/doc/…` from the folder that holds the open document, so
/// relative images and the vendored renderers all load without any network.
final class VendorSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Directory the `doc` prefix maps to. Updated whenever a new file is opened.
    var docDirectory: URL?

    private let fm = FileManager.default

    /// Maps `marknote://assets/<root>/<rest>` onto a real file, or nil.
    func file(for url: URL) -> URL? {
        guard url.host == Vendor.host else { return nil }
        let parts = url.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard let kind = parts.first else { return nil }
        let relative = parts.dropFirst().joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        let root: URL?
        switch kind {
        case Vendor.vendorPrefix: root = Vendor.rootURL
        case Vendor.docPrefix:    root = docDirectory
        default:                  root = nil
        }
        guard let base = root, let target = Vendor.resolve(under: base, relative: relative) else { return nil }
        return fm.isReadableFile(atPath: target.path) ? target : nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let target = file(for: url),
              let data = fm.contents(atPath: target.path) else {
            fail(task, code: 404)
            return
        }

        let mime = Vendor.mimeType(for: target)
        let response = URLResponse(url: url,
                                   mimeType: mime,
                                   expectedContentLength: data.count,
                                   textEncodingName: Vendor.isTextual(target) ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Loads here are synchronous and tiny; nothing to cancel.
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        let error = NSError(domain: "MarkNote.Vendor", code: code,
                            userInfo: [NSLocalizedDescriptionKey: "리소스를 찾을 수 없습니다 (\(code))"])
        task.didFailWithError(error)
    }
}
