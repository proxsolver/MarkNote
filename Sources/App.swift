import AppKit

@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainController?
    private var didFinishLaunching = false
    private var pendingFiles: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = MainController()
        controller = main
        main.showWindow(nil)
        main.bootstrap()
        didFinishLaunching = true
        pendingFiles.forEach { Store.shared.openExternal($0) }
        pendingFiles.removeAll()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard FileManager.default.fileExists(atPath: filename) else { return false }
        if didFinishLaunching {
            Store.shared.openExternal(filename)
        } else {
            pendingFiles.append(filename)
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.flush()
    }
}

/// Main menu — every item routes through the responder chain (target = nil),
/// so shortcuts keep working no matter which view currently has focus.
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appItem())
        main.addItem(fileItem())
        main.addItem(editItem())
        main.addItem(formatItem())
        main.addItem(viewItem())
        main.addItem(windowItem())
        main.addItem(helpItem())
        return main
    }

    private static func container(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        let menu = NSMenu(title: title)
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ mask: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = nil
        item.tag = tag
        menu.addItem(item)
        return item
    }

    private static func appItem() -> NSMenuItem {
        let item = container("MarkNote")
        let menu = item.submenu!
        add(menu, "MarkNote 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        let prefs = add(menu, "설정…", #selector(MainController.showSettings(_:)), ",")
        prefs.target = nil
        menu.addItem(.separator())
        add(menu, "서비스", nil).submenu = NSMenu(title: "서비스")
        NSApp.servicesMenu = menu.items.last!.submenu
        menu.addItem(.separator())
        add(menu, "MarkNote 가리기", #selector(NSApplication.hide(_:)), "h")
        add(menu, "다른 앱 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "모두 보기", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "MarkNote 종료", #selector(NSApplication.terminate(_:)), "q")
        return item
    }

    private static func fileItem() -> NSMenuItem {
        let item = container("파일")
        let menu = item.submenu!
        add(menu, "새 문서…", #selector(MainController.newDocument(_:)), "n")
        add(menu, "폴더 열기…", #selector(MainController.openFolder(_:)), "o")
        menu.addItem(.separator())
        add(menu, "저장", #selector(MainController.saveDocument(_:)), "s")
        add(menu, "디스크 내용으로 되돌리기", #selector(MainController.revertToDisk(_:)), "v", [.command, .shift])
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "최근 문서", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "최근 문서")
        recentMenu.autoenablesItems = false
        recent.submenu = recentMenu
        menu.addItem(recent)

        menu.addItem(.separator())
        add(menu, "이름 변경…", #selector(MainController.renameDocument(_:)))
        add(menu, "Finder에서 보기", #selector(MainController.revealInFinder(_:)), "r", [.command, .option])
        add(menu, "휴지통으로 이동", #selector(MainController.deleteDocument(_:)))
        menu.addItem(.separator())
        add(menu, "HTML로 내보내기…", #selector(MainController.exportHTML(_:)), "e", [.command, .shift])
        add(menu, "시각화 포함 HTML 내보내기…", #selector(MainController.exportHTMLRich(_:)), "e", [.command, .shift, .option])
        add(menu, "브라우저로 미리보기", #selector(MainController.openInBrowser(_:)), "b", [.command, .shift])
        add(menu, "HTML로 복사", #selector(MainController.copyHTML(_:)), "c", [.command, .shift, .option])
        return item
    }

    private static func editItem() -> NSMenuItem {
        let item = container("편집")
        let menu = item.submenu!
        add(menu, "실행 취소", Selector(("undo:")), "z")
        add(menu, "다시 실행", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "자르기", #selector(NSText.cut(_:)), "x")
        add(menu, "복사", #selector(NSText.copy(_:)), "c")
        add(menu, "붙여넣기", #selector(NSText.paste(_:)), "v")
        add(menu, "내용만 붙여넣기", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(menu, "모두 선택", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        let find = add(menu, "찾기…", #selector(NSResponder.performTextFinderAction(_:)), "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let next = add(menu, "다음 찾기", #selector(NSResponder.performTextFinderAction(_:)), "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let prev = add(menu, "이전 찾기", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift])
        prev.tag = NSTextFinder.Action.previousMatch.rawValue
        let rep = add(menu, "바꾸기…", #selector(NSResponder.performTextFinderAction(_:)), "f", [.command, .option])
        rep.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        return item
    }

    private static func formatItem() -> NSMenuItem {
        let item = container("서식")
        let menu = item.submenu!
        add(menu, "굵게", #selector(MainController.boldText(_:)), "b")
        add(menu, "기울임", #selector(MainController.italicText(_:)), "i")
        add(menu, "취소선", #selector(MainController.strikeText(_:)), "x", [.command, .shift])
        add(menu, "인라인 코드", #selector(MainController.inlineCodeText(_:)), "e")
        add(menu, "코드 블록", #selector(MainController.codeBlockText(_:)), "k", [.command, .shift])
        add(menu, "링크", #selector(MainController.insertLink(_:)), "k")
        add(menu, "위키 링크 [[노트]]", #selector(MainController.insertWikiLink(_:)), "k", [.command, .option])
        menu.addItem(.separator())
        add(menu, "제목 1", #selector(MainController.heading1(_:)), "1")
        add(menu, "제목 2", #selector(MainController.heading2(_:)), "2")
        add(menu, "제목 3", #selector(MainController.heading3(_:)), "3")
        add(menu, "제목 해제", #selector(MainController.clearHeading(_:)), "0")
        menu.addItem(.separator())
        add(menu, "글머리 목록", #selector(MainController.bulletList(_:)), "l", [.command, .option])
        add(menu, "번호 목록", #selector(MainController.numberList(_:)), "l", [.command, .shift])
        add(menu, "인용구", #selector(MainController.blockQuote(_:)), "q", [.command, .shift])
        add(menu, "구분선", #selector(MainController.horizontalRule(_:)), "d", [.command, .shift])
        return item
    }

    private static func viewItem() -> NSMenuItem {
        let item = container("보기")
        let menu = item.submenu!
        add(menu, "미리보기 보이기/숨기기", #selector(MainController.togglePreview(_:)), "r")
        add(menu, "사이드바 보이기/숨기기", Selector(("toggleSidebar:")), "s", [.command, .control])
        add(menu, "스크롤 동기화", #selector(MainController.toggleScrollSync(_:)))
        add(menu, "그림·수식 렌더링", #selector(MainController.toggleVisualRender(_:)))
        menu.addItem(.separator())

        let sort = NSMenuItem(title: "사이드바 정렬", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "사이드바 정렬")
        sort.submenu = sortMenu
        add(sortMenu, "이름", #selector(MainController.sortByTitle(_:)), "1", [.command, .option])
        add(sortMenu, "최근 수정", #selector(MainController.sortByModified(_:)), "2", [.command, .option])
        add(sortMenu, "생성일", #selector(MainController.sortByCreated(_:)), "3", [.command, .option])
        sortMenu.addItem(.separator())
        add(sortMenu, "정렬 방향 바꾸기", #selector(MainController.toggleSortDirection(_:)), "s", [.command, .option, .shift])
        menu.addItem(sort)
        add(menu, "이 문서를 참조 표시", #selector(MainController.toggleBacklinks(_:)), "b", [.command, .option])

        menu.addItem(.separator())
        add(menu, "글자 크기 키우기", #selector(MainController.largerText(_:)), "+")
        add(menu, "글자 크기 줄이기", #selector(MainController.smallerText(_:)), "-")
        add(menu, "글자 크기 14pt", #selector(MainController.defaultTextSize(_:)), "0", [.command, .option])
        menu.addItem(.separator())
        add(menu, "자동 저장", #selector(MainController.toggleAutosave(_:)))
        add(menu, "문서 폴더 열기", #selector(MainController.openFolderInFinder(_:)), "o", [.command, .option])
        return item
    }

    private static func windowItem() -> NSMenuItem {
        let item = container("창")
        let menu = item.submenu!
        add(menu, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "닫기", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "화면 가득히", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])
        menu.addItem(.separator())
        add(menu, "앞으로 순환", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpItem() -> NSMenuItem {
        let item = container("도움말")
        let menu = item.submenu!
        add(menu, "MarkNote 단축키", #selector(MainController.showShortcuts(_:)))
        NSApp.helpMenu = menu
        return item
    }
}
