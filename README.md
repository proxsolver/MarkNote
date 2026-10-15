# MarkNote

macOS용 가벼운 마크다운 뷰어 + 편집기. 폴더 하나를 지정하면 그 안의 `.md` 파일 목록을 사이드바에 보여주고, 왼쪽엔 원문, 오른쪽엔 렌더링 결과를 동시에 띄웁니다.

A tiny native Markdown viewer and editor for macOS. Point it at a folder, pick a `.md` file, read the rendered preview on the right and edit the raw source on the left. Autosaves locally, exports standalone HTML.

- **네이티브 앱** — AppKit으로만 작성된 단일 창. 웹 래퍼가 아니고, Electron·RN·SwiftUI 의존성이 없습니다.
- **로컬 전용** — 서버·분석·업데이트 체크가 없습니다. 문서가 기기를 벗어나지 않습니다.
- **Xcode 불필요** — Command Line Tools만으로 빌드되는 `.app` 번들 스크립트를 함께 담고 있습니다.

## 요구 사항

- macOS 13 Ventura 이상 (Apple silicon / Intel 모두)
- Command Line Tools (`xcode-select --install`)
- 외부 의존성 없음 — 순수 Swift + 기본 프레임워크(AppKit, WebKit)

## 빌드 & 실행

```bash
git clone https://github.com/proxsolver/MarkNote.git
cd MarkNote
./build.sh --install --open
```

`.build/MarkNote.app`에 번들이 생기고, `--install`은 `~/Applications/MarkNote.app`으로 복사해 바로 실행합니다. 애드혹 서명만 적용되므로 처음 실행 시 macOS가 막으면 `시스템 설정 > 개인정보 보호 및 보안 > 여전히 열기`를 누르세요.

| 명령 | 동작 |
| --- | --- |
| `./build.sh` | `.build/MarkNote.app` 빌드 |
| `./build.sh --install` | `~/Applications`에 설치 |
| `./build.sh --install --open` | 설치 후 실행 |

## 기능

- **사이드바 목록** — 지정 폴더(하위 폴더 포함)의 `.md` / `.markdown` / `.mdown` 파일을 최근 수정일 순으로 나열. 검색, 이름 변경, 휴지통으로 삭제, 드래그＆드롭으로 파일·폴더 추가.
- **라이브 미리보기** — 타이핑에 반응해 렌더링 결과가 즉시 갱신됩니다. 편집기와 미리보기 스크롤이 양방향 동기화되며, 미리보기는 언제든 접을 수 있습니다.
- **자동 저장** — 입력을 멈추면 0.7초 뒤 원본 파일에 바로 씁니다. 창을 닫거나 앱을 종료할 때 대기 중인 저장도 처리합니다. 다른 프로그램이 파일을 바꾼 경우 감지해 알려줍니다.
- **마크다운 지원** — 제목, 강조/기울임, 취소선, 인라인 코드, 코드 블록(언어 라벨 포함), 인용, 순서·비순서 목록, 중첩 목록, 작업 목록(`- [ ]` / `- [x]`), 표, 구분선, 링크와 이미지. 한글 본문에서도 강조 마커가 정상 동작합니다.
- **HTML 내보내기** — CSS를 동봉한 단일 `.html` 파일로 저장(라이트/다크 팔레트), 기본 브라우저에서 열기, HTML 클립보드 복사.
- **단축키·편집 보조** — 서식 단축키, Enter 시 목록 자동 이어짐, 들여쓰기 Tab / 내어쓰기 ⇧Tab, 커서가 문자 안에 있으면 그 단어를 감싸는 토글 동작.
- **상태 유지** — 폴더, 마지막으로 열던 문서, 최근 문서, 미리보기 표시 여부, 글자 크기, 자동 저장·스크롤 동기화 설정이 모두 복구됩니다.

## 단축키

| 작업 | 키 |
| --- | --- |
| 새 문서 / 열기 / 저장 | `⌘N` `⌘O` `⌘S` |
| 굵게 / 기울임 / 취소선 | `⌘B` `⌘I` `⇧⌘X` |
| 인라인 코드 / 코드 블록 | `⌘E` `⇧⌘K` |
| 링크 | `⌘K` |
| 제목 1·2·3 / 제목 해제 | `⌘1` `⌘2` `⌘3` `⌘0` |
| 순서 목록 / 비순서 목록 / 인용 | `⌥⌘L` `⇧⌘L` `⇧⌘Q` |
| 구분선 | `⇧⌘D` |
| 미리보기 토글 | `⌘R` |
| 사이드바 토글 | `⌥⌘S` |
| 글자 크기 늘림 / 줄임 / 초기화 | `⌘+` `⌘-` `⌥⌘0` |
| HTML 내보내기 / 브라우저에서 열기 / HTML 복사 | `⇧⌘E` `⇧⌘B` `⌥⌘R` |
| 단축키 치트시트 | `⌘/` |

## 저장소 구성

```
Sources/
  App.swift           앱 생명주기, 메인 메뉴(단축키 정의)
  MainController.swift 창·툴바·분할 레이아웃, 하단 상태 바, 액션
  Store.swift         문서/폴더 상태, 자동 저장, 디스크 감시, 내보내기
  EditorPane.swift    NSTextView 편집기, 구문 하이라이트 적용
  Sidebar.swift       문서 목록(소스 리스트 테이블), 검색, 드래그＆드롭
  PreviewPane.swift   WKWebView 미리보기, 점진적 갱신, 스크롤 브리지
  Markdown.swift      마크다운 → HTML 변환, 스타일시트, 내보내기 페이지
  Editing.swift       서식 명령, Enter/Tab 동작 등 편집 로직
  Theme.swift         동적 컬러, 폰트, 원문 구문 하이라이트 규칙
  Utils.swift, Welcome.swift
Info.plist            문서 타입 등록(.md, .markdown, .mdown)
build.sh              컴파일 → 번들링 → 서명 → 설치
```

## 알려진 제한

- `.app`은 애드혹 서명이라 App Store 외 배포용 검증(공증)이 없습니다. 로컬 빌드는 문제없지만, 다른 기기로 옮기면 Gatekeeper 경고를 무시해야 합니다.
- 표·중첩 목록은 일반적인 사용 예에 맞춰 렌더링하는 간소 파서입니다. CommonMark 전부를 검증하지는 않습니다.
- 이미지 상대 경로는 미리보기에서 원본 폴더 기준으로 해석되나, 내보낸 HTML을 폴더 밖으로 옮기면 깨집니다.
- 파일 동기화·암호화·협업은 지원하지 않습니다. 의도된 로컬 단일 사용자 도구입니다.

## 라이선스

MIT — 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
