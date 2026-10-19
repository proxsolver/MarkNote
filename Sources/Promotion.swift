import Foundation

/// 본문에 그냥 적혀 있던 노트 제목을 `[[위키링크]]`로 바꾸는 한 걸음 — '제목 언급 승격'.
///
/// 참조 스캐너는 "다른 노트가 이 제목을 언급했다"까지 알아냅니다. 여기서는 그 언급을
/// 실제 링크로 바꿔, 백링크 목록을 클릭 가능한 연결로 굳힙니다.
///
/// 네 가지를 지킵니다.
///
/// 1. 이미 링크가 된 자리와 코드는 건드리지 않습니다. 펜스 안, `` `인라인 코드` `` 안,
///    `[[이미 링크]]`, `![사진](…)`, 맨 URL 속의 제목은 그대로 둡니다.
/// 2. 앞뒤가 문자·숫자인 언급은 넘깁니다. 한국어는 조사가 붙으면 그 말이 더 이상
///    제목이 아니기 때문입니다 — `회의를`은 `회의` 노트를 가리키지 않습니다.
/// 3. 파일 이름의 한글은 풀어 쓰고( NFD) 편집기에 타이핑한 글자는 합쳐 저장(NFC)됩니다.
///    글자마다 정규화 키를 비교해 두 표기를 같은 단어로 봅니다.
/// 4. 한 번에 여러 개를 바꿔도 결과물은 한 장의 문자열이라, 편집기에서는 ⌘Z 한 번으로
///    통째로 되돌아갑니다.
enum Promotion {
    struct Hit: Hashable {
        /// 원문(전체 본문) 안의 위치.
        let range: NSRange
        /// 파일에 적힌 그대로의 노트 이름. 링크에는 이 표기를 넣습니다.
        let title: String
    }

    struct Plan {
        let text: String
        let hits: [Hit]
        var count: Int { hits.count }
        /// 바꾸지 않고 그대로 돌려보내는 경우(언급이 없음)에도 텍스트는 같습니다.
        var changed: Bool { !hits.isEmpty }
    }

    /// 대상 후보 하나: 파일에 적힌 이름과, 그것을 글자 단위로 정규화한 키.
    struct Candidate: Hashable {
        let title: String
        let clusters: [String]
        var first: String { clusters.first ?? "" }
        var insertion: String { "[[\(title)]]" }

        init?(title: String) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minTitleLength,
                  trimmed.rangeOfCharacter(from: .alphanumerics) != nil,
                  !trimmed.contains("[") else { return nil }
            self.title = trimmed
            self.clusters = Array(trimmed).map { String($0).noteKey }
        }
    }

    /// 이보다 짧은 제목은 조사·부분 일치 위험이 커서 후보에서 뺍니다(스캐너와 같은 기준).
    static let minTitleLength = 3

    /// 이미 링크·코드인 자리. 빈칸으로 지운 뒤에도 길이가 같아야 위치가 안 어긋납니다.
    private static let protected: [NSRegularExpression?] = [
        #"!?\[[^\]\n]*\]\([^)\n]*\)"#,   // 마크다운 링크·사진
        #"\[\[[^\]\n]*\]\]"#,            // 위키링크
        #"<[^>\n]{1,240}>"#,              // HTML 태그·`<URL>` 자동 링크
        #"https?://\S+"#,                 // 맨 URL
    ].map { try? NSRegularExpression(pattern: $0) }

    // MARK: - Planning

    /// 현재 노트를 뺀 후보 제목. 같은 키는 처음 만난 표기를 따릅니다.
    static func candidates(_ titles: [String], excluding own: String?) -> [Candidate] {
        let own = own?.noteKey
        var seen = Set<String>()
        var out: [Candidate] = []
        for title in titles {
            guard let made = Candidate(title: title) else { continue }
            let key = made.clusters.joined()
            guard key != own, seen.insert(key).inserted else { continue }
            out.append(made)
        }
        // 긴 제목 먼저: `주간 회의`와 `회의`가 경쟁하면 더 긴 쪽이 맞는 말입니다.
        return out.sorted { $0.clusters.count > $1.clusters.count }
    }

    /// 본문 전체에서 바꿀 자리를 찾고, 적용까지 한 번에 합니다.
    static func plan(text: String, titles: [String], excluding own: String?) -> Plan {
        let list = candidates(titles, excluding: own)
        guard !list.isEmpty else { return Plan(text: text, hits: []) }

        var buckets: [String: [Candidate]] = [:]
        for candidate in list { buckets[candidate.first, default: []].append(candidate) }

        let ns = text as NSString
        let prose = Set(NoteProse.prose(text).map(\.number))
        var found: [Hit] = []
        for (index, lineRange) in lineRanges(ns).enumerated() where prose.contains(index + 1) {
            let line = ns.substring(with: lineRange)
            if line.rangeOfCharacter(from: .alphanumerics) == nil { continue }
            found.append(contentsOf: hits(in: line, buckets: buckets, offset: lineRange.location))
        }
        found.sort { $0.range.location < $1.range.location }
        return Plan(text: apply(found, to: text), hits: found)
    }

    /// 줄 하나만 떼어 테스트할 수 있게 여는 경로.
    static func hits(in line: String, buckets: [String: [Candidate]], offset: Int = 0) -> [Hit] {
        let masked = Array(mask(of: line))
        guard masked.count > 0 else { return [] }
        var starts: [Int] = []
        var acc = 0
        for character in masked { starts.append(acc); acc += String(character).utf16.count }
        starts.append(acc)

        var out: [Hit] = []
        var i = 0
        while i < masked.count {
            guard let bucket = buckets[String(masked[i]).noteKey] else { i += 1; continue }
            guard let hit = bucket.first(where: { fits(masked, at: i, $0) }) else { i += 1; continue }
            let end = i + hit.clusters.count
            // 앞뒤가 단어 문자면 그 언급은 더 큰 말의 일부입니다.
            guard clear(masked, before: i), clear(masked, after: end - 1) else { i += 1; continue }
            out.append(Hit(range: NSRange(location: offset + starts[i],
                                          length: starts[end] - starts[i]),
                           title: hit.title))
            i = end
        }
        return out
    }

    // MARK: - Applying

    /// 뒤에서 앞으로 갈아넣어야 앞 위치가 안 어긋납니다.
    static func apply(_ hits: [Hit], to text: String) -> String {
        guard !hits.isEmpty else { return text }
        var ns = text as NSString
        for hit in hits.sorted(by: { $0.range.location > $1.range.location }) {
            ns = ns.replacingCharacters(in: hit.range, with: "[[\(hit.title)]]") as NSString
        }
        return ns as String
    }

    /// 승격 뒤 커서 위치. 링크가 늘어난 만큼 앞으로 밀어, 손이 글자 위를 떠나지 않게 합니다.
    static func caret(_ location: Int, after hits: [Hit]) -> Int {
        var moved = location
        for hit in hits.sorted(by: { $0.range.location < $1.range.location }) {
            let delta = "[[\(hit.title)]]".utf16.count - hit.range.length
            if location <= hit.range.location { break }
            if location < hit.range.upperBound { return hit.range.upperBound + delta }
            moved += delta
        }
        return moved
    }

    // MARK: - Pieces

    private static func fits(_ chars: [Character], at start: Int, _ candidate: Candidate) -> Bool {
        guard start + candidate.clusters.count <= chars.count else { return false }
        for (step, key) in candidate.clusters.enumerated() {
            guard String(chars[start + step]).noteKey == key else { return false }
        }
        return true
    }

    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    private static func clear(_ chars: [Character], before index: Int) -> Bool {
        guard index > 0, index - 1 < chars.count else { return true }
        return !isWord(chars[index - 1])
    }

    private static func clear(_ chars: [Character], after index: Int) -> Bool {
        guard index >= 0, index + 1 < chars.count else { return true }
        return !isWord(chars[index + 1])
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.contains { wordCharacters.contains($0) }
    }

    /// 링크·코드 자리에 빈칸을 놓은 사본. UTF-16 길이를 보존합니다.
    static func mask(of line: String) -> String {
        var out = Tags.stripInlineCode(line)
        for regex in protected {
            guard let regex else { continue }
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            for match in matches.reversed() {
                out = (out as NSString).replacingCharacters(in: match.range,
                    with: String(repeating: " ", count: match.range.length)) as String
            }
        }
        return out
    }

    /// 개행 제외 줄 범위. `NoteProse`와 같은 방식으로 갈라야 줄 번호가 어긋나지 않습니다.
    static func lineRanges(_ ns: NSString) -> [NSRange] {
        let length = ns.length
        if length == 0 { return [NSRange(location: 0, length: 0)] }
        var out: [NSRange] = []
        var start = 0
        for i in 0..<length {
            if ns.character(at: i) == 0x0A {
                out.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
        }
        out.append(NSRange(location: start, length: length - start))
        return out
    }
}
