import AppKit
import Quartz
import WebKit

/// 쪽을 나누는 데 쓰는 블록 하나 — 렌더링된 종이 위에서의 위변과 높이(px).
struct Block: Equatable {
    let top: CGFloat
    let height: CGFloat
    /// 제목(h1–h6)이면 쪽의 마지막 자리에 혼자 두지 않습니다.
    let heading: Bool
}

/// 인쇄할 문서의 기하: 전체 높이와 블록 목록.
struct PageLayout {
    let documentHeight: CGFloat
    let blocks: [Block]
}

/// 긴 한 장에서 한 쪽이 가져다 쓸 세로 구간(px, 문서 위변 기준).
struct PageSlice: Equatable {
    let top: CGFloat
    let bottom: CGFloat
    var height: CGFloat { bottom - top }
}

/// 인쇄·PDF 내보내기 다리.
///
/// 미리보기 WKWebView를 그대로 쓰면 지금 화면의 팔레트가 종이에 올라갑니다. 다크로
/// 보고 있는 노트를 그냥 뽑으면 옅은 글자가 검은 배경과 함께 사라지므로, 뽑을 때만
/// 라이트로 다시 그리는 조용한 뷰를 하나 더 둡니다. 이 뷰는 창에 얹지 않아도
/// 렌더링·인쇄가 돌아가고, 머메이드·수식은 미리보기와 같은 방식으로 `marknote://`
/// 번들 파일을 읽습니다.
///
/// 한 번에 하나만 다룹니다. 새 요청이 들어오면 진행 중이던 일은 "더 새로운 요청"으로
/// 포기합니다 — ⌘P를 두 번 눌렀을 때 뒤에서 패널이 하나 더 떠서는 안 되기 때문입니다.
final class PrintBridge: NSObject, WKNavigationDelegate {
    static let shared = PrintBridge()

    /// 실패 사유는 사용자에게 그대로 보여주는 문장입니다.
    struct Failure: Error { let message: String }

    private enum Job {
        case pdf((Result<Data, Failure>) -> Void)
        case print((String?) -> Void)
    }

    /// JS 렌더러가 없는 페이지는 바로 뽑힙니다.
    static let settlePlain: TimeInterval = 0.25
    /// 머메이드·KaTeX가 그림을 그리느라 한 박자가 더 필요합니다.
    static let settleVisual: TimeInterval = 1.5
    /// 이보다 길어지면 포기하고 사용자에게 말합니다.
    static let timeout: TimeInterval = 25

    private var web: WKWebView?
    private let schemeHandler = VendorSchemeHandler()
    private var job: Job?
    private var timer: DispatchWorkItem?
    private var settle = PrintBridge.settlePlain
    private var jobTitle = ""
    /// 쪽을 한 장씩 그리는 여정을 알아채는 표식. 새 요청이 이 값을 올리면 진행 중인
    /// 여정은 다음 장부터 스스로 멈춥니다.
    private var renderToken = 0

    private override init() { super.init() }

    // MARK: - Entry points

    /// 노트를 A4 PDF 바이트로 그립니다. 저장은 부르는 쪽(NSSavePanel)이 합니다.
    func exportPDF(doc: Doc, text: String, visual: Markdown.Visual,
                   then: @escaping (Result<Data, Failure>) -> Void) {
        start(doc: doc, text: text, visual: visual, job: .pdf(then))
    }

    /// 인쇄 패널을 띄웁니다. `then`은 패널을 성공적으로 준비시켰을 때 nil, 실패했을 때
    /// 이유를 받습니다 — 패널이 뜬 뒤 사용자를 뭘 고를지는 앱이 알 일이 아닙니다.
    func printNote(doc: Doc, text: String, visual: Markdown.Visual,
                   then: @escaping (String?) -> Void) {
        start(doc: doc, text: text, visual: visual, job: .print(then))
    }

    // MARK: - Rendering

    private func start(doc: Doc, text: String, visual: Markdown.Visual, job: Job) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start(doc: doc, text: text, visual: visual, job: job) }
            return
        }
        abandon("더 새로운 인쇄 요청이 들어왔습니다")
        renderToken += 1
        self.job = job
        self.jobTitle = doc.title
        self.settle = visual == .off ? Self.settlePlain : Self.settleVisual

        let view = ensureView()
        schemeHandler.docDirectory = doc.url.deletingLastPathComponent()
        armTimeout()
        // 인쇄용 페이지는 언제나 라이트. 화면 팔레트는 여기서 통하지 않습니다.
        let html = Markdown.printPage(title: doc.title, body: Markdown.toHTML(text),
                                      docBaseURL: doc.url, visual: visual)
        let base = visual == .off
            ? doc.url
            : Vendor.pageBaseURL(for: doc.url.deletingLastPathComponent()) ?? doc.url
        view.loadHTMLString(html, baseURL: base)
    }

    /// 화면 밖에서 쓰이는 인쇄 전용 뷰. 한 번 만들면 재사용합니다(벤더 캐시도 같이 남는다).
    private func ensureView() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Vendor.scheme)
        let made = WKWebView(frame: NSRect(origin: .zero, size: PrintLayout.layoutSize), configuration: config)
        made.navigationDelegate = self
        made.underPageBackgroundColor = .white
        web = made
        return made
    }

    private func armTimeout() {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fail("인쇄할 페이지를 그리는 시간이 길어졌습니다 — 다시 시도해 주세요")
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)
    }

    private func scheduleDraw(_ view: WKWebView) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire(view) }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// 그릴 준비가 됐으니 종이에 옮깁니다.
    ///
    /// 여기서 함정이 하나 있습니다. `createPDF`의 `rect`는 쪽 크기가 아니라 **긴 내용에서
    /// 잘라내는 창**입니다(검증으로 확인 — A4로 잘라 뽑으면 첫 쪽만 나오고 나머지는 소리
    /// 없이 사라졌습니다). 그래서 블록 경계를 따라 쪽 구간을 정하고, 구간마다 한 장씩 잘라
    /// 뽑은 뒤 그 조각들을 A4 용지에 얹어 쪽을 만듭니다.
    private func fire(_ view: WKWebView) {
        guard job != nil else { return }
        armTimeout()
        view.evaluateJavaScript(Self.measureJS) { [weak self] result, _ in
            guard let self, self.job != nil else { return }
            self.draw(view, layout: Self.readLayout(result as? String))
        }
    }

    /// 렌더링된 종이의 좌표를 재는 한 수.
    ///
    /// `getBoundingClientRect`는 화면에 실제로 앉은 자리를 주므로(padding까지 포함한
    /// 좌표계), 이 값으로 자르면 눈으로 본 자리와 종이의 자리가 어긋나지 않습니다.
    /// 쪽을 나누는 기준은 블록의 위변 — 문단·표·코드 블록을 중간에서 자르지 않기 위한 최소한의 정보입니다.
    static let measureJS = """
    (function () {
      var art = document.querySelector('article.markdown-body');
      var y = window.scrollY || window.pageYOffset || 0;
      var kids = [];
      if (art) {
        Array.prototype.forEach.call(art.children, function (e) {
          var r = e.getBoundingClientRect();
          kids.push([Math.round((r.top + y) * 100) / 100,
                     Math.round(r.height * 100) / 100,
                     /^H[1-6]$/i.test(e.tagName) ? 1 : 0]);
        });
      }
      return JSON.stringify({
        w: document.documentElement.clientWidth,
        h: Math.ceil(document.documentElement.scrollHeight),
        kids: kids
      });
    })()
    """

    /// `measureJS`가 돌려준 JSON. 못 읽으면 "한 쪽짜리"로 간주하고 끝까지 갑니다.
    static func readLayout(_ json: String?) -> PageLayout {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PageLayout(documentHeight: PrintLayout.pageHeight, blocks: [])
        }
        let height = (obj["h"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? PrintLayout.pageHeight
        var blocks: [Block] = []
        if let kids = obj["kids"] as? [[Any?]] {
            for kid in kids {
                guard kid.count >= 2, let top = kid[0] as? NSNumber, let tall = kid[1] as? NSNumber else { continue }
                let heading = (kid.count > 2 ? kid[2] as? NSNumber : nil)?.intValue ?? 0
                blocks.append(Block(top: CGFloat(top.doubleValue), height: CGFloat(tall.doubleValue),
                                    heading: heading != 0))
            }
        }
        return PageLayout(documentHeight: max(height, PrintLayout.pageHeight), blocks: blocks)
    }

    private func draw(_ view: WKWebView, layout: PageLayout) {
        guard let job else { return }
        switch job {
        case .pdf:
            renderBands(view, slices: Self.pageSlices(layout), index: 0, bands: [], token: renderToken)
        case .print(let then):
            // 패널이 뜨는 순간까지가 이 앱의 일입니다. 그 다음은 사용자 프린터와의 대화.
            self.job = nil
            timer?.cancel()
            then(nil)
            runPanel(view)
        }
    }

    /// 쪽마다 종이를 한 장씩 잘라 그립니다.
    ///
    /// `rect`는 쪽 크기가 아니라 내용에서 잘라내는 창입니다(검증으로 확인 — 원점을 1000px로
    /// 밀면 그 뒤 1003px만 종이에 올라왔습니다). 그래서 쪽마다 자기 구간만 담도록 시킵니다.
    /// 문서 전체를 한 장의 긴 PDF로 그리고 쪽마다 그 위에서 다시 그리면, 각 쪽의 내용 스트림에
    /// 문서 전체가 얹혀 파일이 쪽 수만큼 불어나고 종이에 안 보이는 글자가 중복으로 앉습니다
    /// (검색·복사가 어긋납니다). 잘라 뽑으면 둘 다 일어나지 않습니다.
    private func renderBands(_ view: WKWebView, slices: [PageSlice], index: Int,
                             bands: [Data], token: Int) {
        guard token == renderToken, job != nil else { return }
        guard index < slices.count else {
            guard let out = Self.composeA4(bands, pages: slices), !out.isEmpty else {
                fail("쪽을 나열해 얹는 데 실패했습니다 — 다시 시도해 주세요")
                return
            }
            deliver(.success(out))
            return
        }
        let slice = slices[index]
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: slice.top, width: PrintLayout.pageWidth,
                             height: max(slice.height, 1))
        view.createPDF(configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, token == self.renderToken, self.job != nil else { return }
                switch result {
                case .success(let band) where !band.isEmpty:
                    // 쪽이 여러 장이라 한 장마다 시계를 다시 걸어서, 전체 쪽 수가 많아도
                    // 첫 쪽 기준으로만 시간을 재지 않도록 합니다.
                    self.armTimeout()
                    self.renderBands(view, slices: slices, index: index + 1,
                                     bands: bands + [band], token: token)
                case .success:
                    self.fail("빈 PDF가 나왔습니다")
                case .failure(let error):
                    self.fail("PDF 생성 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Pagination

    /// 블록 경계만으로 쪽을 나눕니다. 결과는 각 쪽이 긴 한 장에서 가져다 쓸 세로 구간입니다.
    ///
    /// 두 가지를 지킵니다.
    /// · 끊지 않는다 — 블록이 쪽 폭에 통째로 들어갈 때만 앉히고, 넘치면 다음 쪽으로 보냅니다.
    /// · 겹치지 않는다 — 각 쪽의 아래변은 실제로 앉은 마지막 블록의 아래변입니다. 쪽 폭
    ///  (`limit`)까지 그대로 그리는 순간, 다음 쪽의 첫 블록이 앞 쪽 아래에도 나와 같은 줄이
    ///   두 번 찍힙니다.
    /// 쪽보다 긴 블록(거대한 표·코드 블록)은 어쩔 수 없이 이어 자르되, 내용은 드롭하지 않습니다.
    static func pageSlices(_ layout: PageLayout) -> [PageSlice] {
        let firstCapacity = PrintLayout.pageHeight - PrintLayout.topMargin
        let capacity = PrintLayout.contentHeight
        guard layout.documentHeight > firstCapacity + 1 else {
            return [PageSlice(top: 0, bottom: layout.documentHeight)]
        }
        guard !layout.blocks.isEmpty else {
            return stride(from: CGFloat(0), to: layout.documentHeight, by: capacity)
                .map { PageSlice(top: $0, bottom: min($0 + capacity, layout.documentHeight)) }
        }

        var slices: [PageSlice] = []
        var start: CGFloat = 0
        var limit = start + firstCapacity
        var next = 0
        // 아무리 긴 노트라도 쪽 수에 상한이 있어야 루프가 항상 끝납니다.
        while slices.count < 2_000 {
            var last = next - 1
            while last + 1 < layout.blocks.count {
                let candidate = layout.blocks[last + 1]
                let fits = candidate.top + candidate.height <= limit
                // 이 쪽에 앉힐 첫 블록인데 혼자서도 쪽보다 길다면, 어쨌든 앉히고 자릅니다.
                if fits || (last + 1 == next && candidate.height >= capacity) { last += 1 } else { break }
            }
            if last < next { last = next }
            // 제목을 쪽의 마지막 자리에 혼자 두지 않습니다 — 바로 뒤 본문과 함께 넘깁니다.
            if last > next, layout.blocks[last].heading { last -= 1 }

            let tail = layout.blocks[last]
            let tailBottom = tail.top + tail.height
            slices.append(PageSlice(top: start, bottom: min(limit, tailBottom)))
            if tailBottom > limit {
                // 쪽보다 긴 블록(거대한 표·코드 블록) — 다음 쪽에서 같은 블록을 이어서 자릅니다.
                next = last
                start = limit
            } else {
                next = last + 1
                if next >= layout.blocks.count { break }
                // 다음 쪽은 다음 블록의 위변에서 시작합니다. 앞 블록의 아래변부터 그리면
                // 블록 사이 여백만큼 종이가 비고, 잘린 블록은 위쪽 일부를 다시 찍습니다.
                start = layout.blocks[next].top
            }
            limit = start + capacity
        }
        return slices
    }

    /// 잘라 뽑은 쪽들을 A4 용지에 얹습니다. 각 쪽은 여백만큼 들여앉히고, 그 쪽이 가져다
    /// 쓰는 구간 밖의 내용은 자릅니다(clip) — 앞 쪽의 마지막 줄이 다음 쪽 맨 위에 다시
    /// 찍히지 않도록 하는 장치입니다.
    static func composeA4(_ bands: [Data], pages slices: [PageSlice]) -> Data? {
        guard bands.count == slices.count, !bands.isEmpty else { return nil }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        var mediaBox = PrintLayout.pageRect
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for (band, slice) in zip(bands, slices) {
            guard let source = PDFDocument(data: band), let srcPage = source.page(at: 0) else { return nil }
            let srcHeight = srcPage.bounds(for: .mediaBox).height
            // 첫 쪽은 문서 자체의 위 여백을 함께 실어오고(구간의 위변이 0), 그 다음부터는
            // 우리가 여백을 만들어 블록의 위변을 여백 아래에 놓습니다.
            let inset = slice.top == 0 ? CGFloat(0) : PrintLayout.topMargin
            let band2 = max(srcHeight, 1)
            var box = mediaBox
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: PrintLayout.pageHeight - inset - band2,
                                width: PrintLayout.pageWidth, height: band2))
            // PDF 눈금은 아래에서 위로 자라므로, 구간 위변을 여백 자리에 맞춰 내려 앉힙니다.
            ctx.translateBy(x: 0, y: PrintLayout.pageHeight - inset - srcHeight)
            srcPage.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// 인쇄 패널을 여는 마지막 한 수. 우리가 할 일은 여기까지 — 용지에 들어갈
    /// 페이지와 여백, 작업 이름만 정해 넘기고 나면 나머지는 사용자와 프린터의 대화입니다.
    ///
    /// 갈고리로 열어 둡니다. 검증 하네스는 ⌘P를 누르지 않았는데 사용자의 화면에
    /// 모달 패널을 띄울 수 없으니, 이 자리를 대체해 "패널에 넘길 준비가 됐는지"만 확인합니다.
    var opensPanel: (_ view: WKWebView, _ info: NSPrintInfo, _ title: String) -> Void = { view, info, title in
        let operation = view.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let target = Store.shared.window {
            operation.runModal(for: target, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private func runPanel(_ view: WKWebView) {
        opensPanel(view, printInfo(), jobTitle.isEmpty ? "마크다운 노트" : jobTitle)
    }

    /// 용지 여백과 쪽 나눔만 우리가 정하고, 용지 크기는 사용자의 프린터 기본값을 둡니다.
    /// 프린터 쪽은 pt를 쓰므로 우리가 px로 재어 둔 여백을 환산해서 넘깁니다.
    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.orientation = .portrait
        info.topMargin = PrintLayout.toPoints(PrintLayout.topMargin)
        info.bottomMargin = PrintLayout.toPoints(PrintLayout.topMargin)
        info.leftMargin = PrintLayout.toPoints(PrintLayout.sideMargin)
        info.rightMargin = PrintLayout.toPoints(PrintLayout.sideMargin)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .spool
        return info
    }

    // MARK: - Completion

    private func deliver(_ result: Result<Data, Failure>) {
        timer?.cancel()
        timer = nil
        guard let job else { return }
        self.job = nil
        switch job {
        case .pdf(let then): then(result)
        case .print(let then):
            if case .failure(let problem) = result { then(problem.message) } else { then(nil) }
        }
    }

    private func fail(_ message: String) {
        deliver(.failure(Failure(message: message)))
    }

    /// 새 요청이 이전 요청을 밀어낼 때. 대기를 끊고 이유를 알려줍니다.
    private func abandon(_ reason: String) {
        guard job != nil else { return }
        fail(reason)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard job != nil else { return }
        scheduleDraw(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail("인쇄할 페이지를 그리지 못했습니다: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        fail("인쇄할 페이지를 열지 못했습니다: \(error.localizedDescription)")
    }
}
