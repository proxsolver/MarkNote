import AppKit
import WebKit

final class PreviewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let store: Store
    private var web: WKWebView!
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
            let html = Markdown.page(title: store.current?.title ?? "미리보기",
                                     body: Markdown.toHTML(store.text),
                                     dark: dark,
                                     docBaseURL: store.current?.url,
                                     bridge: true)
            web.loadHTMLString(html, baseURL: store.current?.url)
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
            NSWorkspace.shared.open(url)
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
