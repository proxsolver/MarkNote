import Foundation

/// 줄 번호를 유지한 채 노트를 읽는 시선 — 무엇을 "본문"으로 볼지의 판단을 한 곳에 모은다.
///
/// 닫는 코드(``` … ```) 안은 문서가 아니라 예제입니다. 그래서 거기 적힌 `[[링크]]`는
/// 참조가 아니고 `#include`는 태그가 아니며, 미연결 언급을 링크로 바꿀 때도 건드려서는
/// 안 됩니다. 인덱스와 편집기가 같은 규칙을 쓰도록 여기 한 번만 적습니다.
enum NoteProse {
    struct Line: Hashable {
        /// 1부터 세는 줄 번호(편집기 표시와 같다).
        let number: Int
        let text: String
        /// 코드 펜스 안에 있는지.
        let inCode: Bool
    }

    /// 모든 줄, 코드 안 여부까지 표시해 포함합니다.
    static func lines(_ text: String) -> [Line] {
        var inside = false
        var out: [Line] = []
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inside.toggle()
                out.append(Line(number: offset + 1, text: raw, inCode: true))
                continue
            }
            out.append(Line(number: offset + 1, text: raw, inCode: inside))
        }
        return out
    }

    /// 본문으로 보는 줄만 — 코드 펜스는 통째로 건너뜁니다(펜스를 여닫는 줄 포함).
    static func prose(_ text: String) -> [Line] { lines(text).filter { !$0.inCode } }
}

/// `#태그` — 폴더를 새로 파지 않고 노트를 묶는 두 번째 축.
///
/// 태그는 문법보다 관습에 가까운 문법이라, 무엇을 태그로 볼지가 곧 동작을 결정합니다.
/// 여기 정한 규칙은 네 가지입니다.
///
/// 1. `#`이 단어의 일부가 아닐 때만 태그로 봅니다. `c#`, `폭#1`, URL의 `#조각`, `## 제목`은
///    태그가 아니고, `(#태그)`처럼 괄호·따옴표 뒤에 온 것은 태그입니다.
/// 2. 첫 글자는 문자입니다. `#1`, `#2026-01-19`은 번호·날짜이지 주제가 아닙니다.
/// 3. 닫는 코드는 건너뛰고, 줄 안의 `` `인라인 코드` ``는 지웁니다. 예제를 적어둔 노트에서
///    `#include`, `# 예시`가 태그로 새어 나오면 인덱스는 쓸모가 없어집니다.
/// 4. 대소문자·한글 정규화(NFC/NFD)를 가리지 않아, `#React`와 `#react`는 같은 태그이고
///    표기는 더 많이 쓴 쪽을 따릅니다.
enum Tags {
    /// 태그 이름 최대 길이. 이보다 길면 경로나 해시일 가능성이 커 이름을 잘라버린다.
    static let maxName = 48

    /// `#` 앞에 단어 문자·URL 기호가 없어야 하고, 첫 글자는 문자, 이후는 문자·숫자·`-_ /`.
    ///
    /// 앞에 오는 것을 막는 이유는 "`#`이 단어의 일부가 아닐 때만 태그"라는 한 문장입니다.
    /// `c#`, `폭#1`, `https://x/#절`, `##제목`, `&#35;` 는 모두 `#`이 단어·경로·문자의 일부이고,
    /// `(#기획)`, `"#태그"`, `,#태그` 는 괄호·따옴표·쉼표일 뿐이라 태그로 봅니다.
    /// 닫는 문장 부호(`.` `!` `?` `,`)는 이름 문자에 없어 자동으로 태그를 끝냅니다.
    static let pattern = "(?<![\\w/#&=:?%+@$~.-])#(\\p{L}[\\p{L}\\p{N}_\\-/]{0,\(maxName - 1)})"

    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// 줄 하나에서 태그 이름을 뽑습니다(`#` 제외). 인라인 코드는 먼저 지웁니다.
    static func names(in line: String) -> [String] {
        guard let regex else { return [] }
        let cleaned = stripInlineCode(line)
        let ns = cleaned as NSString
        var found: [String] = []
        for match in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 2 else { continue }
            let name = ns.substring(with: match.range(at: 1))
            guard !name.isEmpty else { continue }
            found.append(name)
        }
        return found
    }

    /// 노트 전체에서 나타난 순서대로, 중복 없이.
    static func collect(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in NoteProse.prose(text) {
            for name in names(in: line.text) where seen.insert(name.noteKey).inserted {
                out.append(name)
            }
        }
        return out
    }

    /// `` `…` `` 묶음을 빈칸으로 바꿉니다. 위치가 어긋나면 안 되니 글자 수를 유지합니다.
    static func stripInlineCode(_ line: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "`[^`\\n]+`") else { return line }
        let ns = line as NSString
        let hits = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !hits.isEmpty else { return line }
        var result = line
        for hit in hits.reversed() {
            let blanks = String(repeating: " ", count: hit.range.length)
            result = (result as NSString).replacingCharacters(in: hit.range, with: blanks)
        }
        return result
    }

    /// 인덱스가 쓰는 키. `noteKey`(NFC + 소문자)라 검색창 입력과 같은 기준으로 만납니다.
    static func key(of name: String) -> String { name.noteKey }

    /// 사이드바·미리보기가 함께 쓰는 해시 조각. 내보낸 HTML에서는 그냥 문서 안 조각이라
    /// 앱 밖에서도 깨지지 않습니다.
    static func fragment(for key: String) -> String {
        "tag-" + (key.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? key)
    }

    /// `#tag-키` 조각에서 태그 키를 되돌립니다. 미리보기 클릭 처리용.
    static func key(fromFragment fragment: String) -> String? {
        guard fragment.hasPrefix("tag-") else { return nil }
        let raw = String(fragment.dropFirst(4))
        return raw.removingPercentEncoding ?? raw
    }
}

/// 한 태그의 실체: 표기·키, 그리고 그것을 단 노트들의 경로.
struct Tag: Hashable {
    let key: String
    /// 목록에 보여 주는 표기. `#React`와 `#react`는 같은 태그이므로 키는 접고 표기는
    /// 그대로 보여 준다 — 어떤 표기를 삼는지 `TagIndex`가 정한다.
    var name: String
    var paths: Set<String>

    var count: Int { paths.count }
}

/// 폴더 한 번 훑어 얻은 태그 표. 노트 경로 기준이라 사이드바 필터는 사전 조회로 끝난다.
struct TagIndex {
    private(set) var byKey: [String: Tag] = [:]
    /// 노트 경로(pathKey) → 그 노트의 태그 키(이름 순 정렬).
    private(set) var byPath: [String: [String]] = [:]

    init(_ scanned: [(path: String, tags: [String])] = []) {
        for entry in scanned {
            let path = entry.path.pathKey
            var keys: [String] = []
            for name in entry.tags {
                let key = Tags.key(of: name)
                keys.append(key)
                if var tag = byKey[key] {
                    tag.paths.insert(path)
                    byKey[key] = tag
                } else {
                    // 표기는 처음 만난 노트의 것을 따릅니다. 스캐너는 사이드바 순서(최신
                    // 수정이 먼저)로 돌므로, 결과적으로 가장 최근 노트에서 쓴 표기가 목록에 뜬다.
                    byKey[key] = Tag(key: key, name: name, paths: [path])
                }
            }
            byPath[path] = keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    func tag(_ key: String) -> Tag? { byKey[Tags.key(of: key)] }
    func keys(forPath path: String) -> [String] { byPath[path.pathKey] ?? [] }

    /// 사이드바 필터: 이 태그를 단 노트 경로 모임.
    func paths(tagged key: String) -> Set<String> { byKey[Tags.key(of: key)]?.paths ?? [] }

    func contains(_ key: String, path: String) -> Bool { paths(tagged: key).contains(path.pathKey) }

    /// 많은 순, 같으면 이름 순. 사이드바 칩은 이 순서를 그대로 쓴다.
    var sorted: [Tag] {
        byKey.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var count: Int { byKey.count }
    var isEmpty: Bool { byKey.isEmpty }
}
