import AppKit

final class EditorController: NSViewController, NSTextViewDelegate {
    private let store: Store
    private(set) var scroll: NSScrollView!
    private var textView: NSTextView!
    private var isProgrammatic = false
    private var lastAppliedSize: CGFloat = -1
    private var quietUntil = Date.distantPast

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "편집기"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 24, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: -10, left: 0, bottom: -24, right: 0)

        textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.editorBackground
        textView.insertionPointColor = .controlAccentColor
        textView.textColor = Theme.text
        textView.font = Theme.base
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 16
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isIncrementalSearchingEnabled = true
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.delegate = self
        textView.string = store.text
        textView.typingAttributes = [.font: Theme.base, .foregroundColor: Theme.text]
        if let storage = textView.textStorage { Highlighter.apply(to: storage) }
        (textView as? NoteTextView)?.noteStore = store

        // AppKit only offers a view the drag types it registered for, so pictures
        // and dropped files have to be added to whatever a text view already takes.
        var dragged = textView.registeredDraggedTypes
        for extra in Attachments.pasteboardTypes where !dragged.contains(extra) { dragged.append(extra) }
        textView.registerForDraggedTypes(dragged)

        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        store.editor = textView

        view = scroll
        bind()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    private func bind() {
        store.on(.document) { [weak self] in self?.sync() }
        store.on(.text) { [weak self] in self?.sync() }
        store.on(.ui) { [weak self] in self?.applyFont() }
    }

    private func sync() {
        guard let textView, !isProgrammatic else { return }
        store.editor = textView
        applyFont()
        guard textView.string != store.text else { return }
        isProgrammatic = true
        let selection = textView.selectedRange()
        textView.string = store.text
        if let storage = textView.textStorage {
            storage.beginEditing()
            Highlighter.apply(to: storage)
            storage.endEditing()
        }
        let location = min(selection.location, (store.text as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.typingAttributes = [.font: Theme.base, .foregroundColor: Theme.text]
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        isProgrammatic = false
    }

    private func applyFont() {
        guard let textView, let storage = textView.textStorage else { return }
        Theme.size = store.fontSize
        guard lastAppliedSize != store.fontSize else { return }
        lastAppliedSize = store.fontSize
        isProgrammatic = true
        textView.font = Theme.base
        storage.beginEditing()
        Highlighter.apply(to: storage)
        storage.endEditing()
        textView.typingAttributes = [.font: Theme.base, .foregroundColor: Theme.text]
        textView.setNeedsDisplay(textView.visibleRect)
        isProgrammatic = false
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isProgrammatic, let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        if storage.length < 300_000 {
            storage.beginEditing()
            Highlighter.apply(to: storage)
            storage.endEditing()
            textView.setSelectedRange(selection)
        }
        textView.typingAttributes = [.font: Theme.base, .foregroundColor: Theme.text]
        store.editorChanged(textView.string)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let insertNewline = Selector(("insertNewline:"))
        let insertTab = Selector(("insertTab:"))
        let insertBacktab = Selector(("insertBacktab:"))

        if commandSelector == insertNewline, let insert = Editing.smartNewline(in: textView) {
            if !insert.isEmpty { textView.insertText(insert, replacementRange: textView.selectedRange()) }
            return true
        }
        if commandSelector == insertTab, let insert = Editing.tab(in: textView, shift: false) {
            textView.insertText(insert, replacementRange: textView.selectedRange())
            return true
        }
        if commandSelector == insertBacktab, let insert = Editing.tab(in: textView, shift: true) {
            textView.insertText(insert, replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {}

    // MARK: - Scroll sync

    var scrollFraction: CGFloat {
        guard let textView else { return 0 }
        let clip = scroll.contentView
        let docHeight = textView.frame.height - clip.bounds.height
        guard docHeight > 0 else { return 0 }
        return max(0, min(1, clip.bounds.origin.y / docHeight))
    }

    var isScrollQuiet: Bool { Date() < quietUntil }

    func setScrollFraction(_ fraction: CGFloat) {
        guard store.scrollSync, let textView else { return }
        quietUntil = Date().addingTimeInterval(0.25)
        let clip = scroll.contentView
        let docHeight = textView.frame.height - clip.bounds.height
        guard docHeight > 0 else { return }
        let y = max(0, min(docHeight, fraction * docHeight))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

/// The plain-text editor, plus the one thing plain text views refuse to do:
/// accept a picture. A rich text view would embed the bitmap in the document,
/// which is exactly what a Markdown note must not become, so `isRichText` and
/// `importsGraphics` stay off and pasted or dropped images are handed to
/// `Store.insertImages` — a file in `assets/` and a Markdown link at the caret.
final class NoteTextView: NSTextView {
    weak var noteStore: Store?

    override func paste(_ sender: Any?) {
        if let noteStore, noteStore.insertPasteboardImage(.general, into: self) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let noteStore, noteStore.insertPasteboardImage(.general, into: self) { return }
        super.pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Attachments.hasImage(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Attachments.hasImage(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let noteStore, noteStore.insertPasteboardImage(sender.draggingPasteboard, into: self) { return true }
        return super.performDragOperation(sender)
    }
}
