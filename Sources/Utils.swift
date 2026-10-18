import AppKit

extension String {
    /// `""` and missing path components behave the same way downstream.
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// A note name reaches the app from two directions: a volume (and `URL.path`)
    /// hands back Hangul *decomposed* into jamo, while text typed in the editor
    /// stays *precomposed*. Swift's `==` bridges that gap, but `contains`, Set
    /// lookups and the "is there a note called this" check in the preview are much
    /// easier to trust when both sides are put in the same form first.
    var noteKey: String { precomposedStringWithCanonicalMapping.lowercased() }
    /// The same idea for file paths, without case folding — a case-sensitive volume
    /// must still tell `노트.md` apart from its opposite-case twin.
    var pathKey: String { precomposedStringWithCanonicalMapping }
}

/// A note saved as `.md` does not always hold Markdown. TextEdit — and a few
/// chat and agent tools — write Rich Text and only rename the extension, which
/// reads as `{\rtf1\ansi\ansicpg949…}` with every Korean syllable escaped to
/// `\uNNNN`. Decode those so the note is legible, but hand the original bytes
/// back too: the editor shows the text while the file keeps whatever was on
/// disk, so opening a note never rewrites it — only saving does.
enum DocumentText {
    enum Format: Equatable {
        case markdown
        case rtf

        /// Shown once when a note is opened, so the conversion is not a surprise.
        var notice: String? {
            switch self {
            case .markdown: return nil
            case .rtf: return "이 파일은 RTF 원문입니다 — 텍스트로 변환해 보여줍니다. 저장하면 이 내용으로 바뀝니다"
            }
        }
    }

    struct Read {
        /// What the editor should show.
        let text: String
        /// What is actually on disk, verbatim.
        let raw: String
        let format: Format
    }

    static func read(_ url: URL) -> Read {
        let data = (try? Data(contentsOf: url)) ?? Data()
        // Latin-1 cannot fail, so the RTF header stays recognisable even when the
        // file is not valid UTF-8 (cp949 RTF from an older TextEdit, say).
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard looksLikeRTF(raw), let decoded = rtfToText(data),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Read(text: raw, raw: raw, format: .markdown)
        }
        return Read(text: decoded, raw: raw, format: .rtf)
    }

    static func looksLikeRTF(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(#"{\rtf"#)
    }

    /// AppKit's own RTF reader: handles `\par`, groups, escapes and `\uNNNN`
    /// without a network or an extra dependency.
    private static func rtfToText(_ data: Data) -> String? {
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil) else { return nil }
        return attr.string
    }
}

/// "1.2 MB" for the export toast.
func ByteCount(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB]
    return formatter.string(fromByteCount: Int64(bytes))
}

extension Date {
    /// "오후 3:12" today, "수" this week, "10/12" earlier — for the sidebar.
    var abbreviated: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            formatter.setLocalizedDateFormatFromTemplate("a h:mm")
        } else if calendar.isDate(self, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("M/d")
        }
        return formatter.string(from: self)
    }

    /// "방금", "5분 전", "3시간 전", 아니면 날짜.
    var timeAgoShort: String {
        let seconds = Int(-timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "방금"
        case ..<3600: return "\(seconds / 60)분 전"
        case ..<86400: return "\(seconds / 3600)시간 전"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.setLocalizedDateFormatFromTemplate("M/d a h:mm")
            return formatter.string(from: self)
        }
    }
}
