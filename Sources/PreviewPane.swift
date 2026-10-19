import AppKit
import WebKit

final class PreviewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let store: Store
    private var web: WKWebView!
    private let schemeHandler = VendorSchemeHandler()
    private var loaded = false
    private var lastDark = false
    private var pending: DispatchWorkItem?
    private var quietUntil = Date.distantPast

    /// Reported when the rendered page is scrolled (fraction 0...1).
    var onScroll: ((CGFloat) -> Void)?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "미리보기"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "scroll")
        config.suppressesIncrementalRendering = false
        // marknote:// serves the bundled renderer files and images beside the document.
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Vendor.scheme)

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        web.navigationDelegate = self
        web.allowsMagnification = true
        web.autoresizingMask = [.width, .height]
        view = web

        lastDark = Theme.isDark
        store.on(.text) { [weak self] in self?.schedule(full: false) }
        store.on(.document) { [weak self] in self?.schedule(full: true) }
        store.on(.ui) { [weak self] in self?.schedule(full: false) }
        schedule(full: true)
    }

    // MARK: - Rendering

    /// Diagrams / code colours / math are on only when the user enabled them
    /// and the bundled files really are inside the app.
    private var visualMode: Markdown.Visual {
        (store.visualEnabled && Vendor.available) ? .preview : .off
    }

    private var usesSchemeBase: Bool { visualMode == .preview && store.current != nil }

    private func schedule(full: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render(full: full) }
        pending = work
        let delay = full ? 0.0 : 0.14
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func render(full: Bool) {
        guard web != nil else { return }
        let dark = Theme.isDark
        let mustReload = full || !loaded || dark != lastDark || store.text.count > 400_000
        lastDark = dark

        if mustReload {
            loaded = true
            schemeHandler.docDirectory = store.current?.url.deletingLastPathComponent()
            let html = Markdown.page(title: store.current?.title ?? "미리보기",
                                     body: Markdown.toHTML(store.text),
                                     dark: dark,
                                     docBaseURL: store.current?.url,
                                     bridge: true,
                                     visual: visualMode)
            if usesSchemeBase, let base = Vendor.pageBaseURL(for: store.current?.url.deletingLastPathComponent()) {
                // A directory base keeps `![](photo.png)` resolving through marknote://assets/doc/…
                web.loadHTMLString(html, baseURL: base)
            } else {
                web.loadHTMLString(html, baseURL: store.current?.url)
            }
            return
        }

        web.evaluateJavaScript("window.__set(\(jsLiteral(Markdown.toHTML(store.text))))", completionHandler: nil)
    }

    private func jsLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let wrapped = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
    }

    // MARK: - Scroll sync

    func setFraction(_ fraction: CGFloat) {
        guard store.scrollSync, loaded, web != nil else { return }
        quietUntil = Date().addingTimeInterval(0.2)
        let value = max(0, min(1, Double(fraction)))
        web.evaluateJavaScript("window.__quiet = true; window.scrollTo(0, \(value) * (document.documentElement.scrollHeight - window.innerHeight)); setTimeout(function(){ window.__quiet = false; }, 220);",
                               completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            // `#태그` 칩: 스크롤을 옮기지 않고 사이드바 필터만 바꿉니다.
            if let fragment = url.fragment, let key = Tags.key(fromFragment: fragment) {
                store.toggleTag(key)
                decisionHandler(.cancel)
                return
            }
            if url.scheme == Vendor.scheme {
                // marknote:// links are files next to the document.
                if let target = schemeHandler.file(for: url) {
                    if Markdown.isReadableTextFile(target) {
                        store.openExternal(target.path)
                    } else {
                        NSWorkspace.shared.open(target)
                    }
                } else if let last = url.pathComponents.last,
                          Markdown.isReadableTextFile(URL(fileURLWithPath: last)) {
                    // A wiki link to a note in a subfolder resolves to a sibling path
                    // that does not exist — look the name up in the note list instead.
                    store.openNote(named: (last as NSString).deletingPathExtension)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - Messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scroll", Date() > quietUntil else { return }
        if let fraction = message.body as? Double {
            onScroll?(CGFloat(fraction))
        } else if let fraction = message.body as? NSNumber {
            onScroll?(CGFloat(truncating: fraction))
        }
    }
}
