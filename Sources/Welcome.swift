import AppKit

/// First-run screen: pick a folder, or start with ~/Documents/MarkNote.
final class WelcomeController: NSViewController {
    private let store: Store
    private let recentStack = NSStackView()
    private var recentPaths: [String] = []

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "MarkNote"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSView()
        background.wantsLayer = true

        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "MarkNote")
        mark.contentTintColor = .controlAccentColor
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .light)

        let heading = NSTextField(labelWithString: "MarkNote")
        heading.font = .systemFont(ofSize: 30, weight: .semibold)

        let blurb = NSTextField(labelWithString: "마크다운을 치면 바로 저장되는, 로컬 전용 메모 편집기")
        blurb.font = .systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor

        let pick = NSButton(title: "문서 폴더 선택…", target: nil, action: #selector(MainController.openFolder(_:)))
        pick.bezelStyle = .rounded
        pick.keyEquivalent = "\r" // Return = 폴더 선택
        pick.controlSize = .large
        pick.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let starter = NSButton(title: "문서/MarkNote 폴더에 새로 시작", target: nil, action: #selector(MainController.useDefaultFolder(_:)))
        starter.bezelStyle = .rounded
        starter.controlSize = .regular

        let hint = NSTextField(labelWithString: "Finder에서 .md 파일이나 폴더를 이 창에 끌어다 놓아도 열립니다")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        recentStack.orientation = .vertical
        recentStack.alignment = .centerX
        recentStack.spacing = 4

        let stack = NSStackView(views: [mark, heading, blurb, spacer(10), pick, starter, spacer(14), recentStack, spacer(6), hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -24),
        ])

        view = background
        reload()
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    func reload() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        recentPaths.removeAll()
        let items = store.recents
        guard !items.isEmpty else { return }

        let label = NSTextField(labelWithString: "최근 문서")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        recentStack.addArrangedSubview(label)

        for doc in items.prefix(5) {
            let button = NSButton(title: "\(doc.title)   ·  \(doc.parentName)", target: self, action: #selector(openRecent(_:)))
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.font = .systemFont(ofSize: 11.5)
            button.toolTip = doc.url.path
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.tag = recentPaths.count
            recentPaths.append(doc.url.path)
            recentStack.addArrangedSubview(button)
        }
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < recentPaths.count else { return }
        store.openRecent(Doc(url: URL(fileURLWithPath: recentPaths[sender.tag])))
    }
}
