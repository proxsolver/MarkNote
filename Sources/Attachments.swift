import AppKit
import CryptoKit

/// A screenshot put on the clipboard, or a picture dragged onto the editor, is
/// copied into `assets/` **beside the note** and turned into an ordinary Markdown
/// link: `![하늘](assets/2026-10-19-하늘.png)`. Nothing leaves the machine, the
/// note stays plain text, and the preview already resolves relative paths against
/// the open document's folder — so the image renders the moment it is written.
///
/// Two rules keep the folder sane: names are dated and stripped of anything a URL
/// or a sync service would dislike, and identical bytes are never stored twice.
enum Attachments {

    static let directoryName = "assets"
    /// Label used when the clipboard offers no name (a plain screenshot does not).
    static let anonymous = "이미지"

    /// A 24 MB picture is a scan, not a screenshot. It would ride along into every
    /// export and every history copy of the note, so it is refused with a message.
    static let maxBytes = 24_000_000

    /// What we look for on a pasteboard or a drag.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    /// Formats a browser shows as they are.
    static let webFormats = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "svg"]
    /// Formats macOS hands over that a browser cannot draw — re-encoded to PNG.
    static let convertedFormats = ["tiff", "tif", "heic", "heif"]

    static var supportedFormats: Set<String> { Set(webFormats + convertedFormats) }

    static func isImage(_ url: URL) -> Bool { supportedFormats.contains(url.pathExtension.lowercased()) }

    // MARK: - Naming

    /// `yyyy-MM-dd` — the day first, so the folder reads like a timeline and a
    /// Finder sort lines pictures up in the order they were taken.
    static func dayStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Spaces, brackets and parentheses would have to be escaped inside a Markdown
    /// `src` (our parser reads a link only up to the first space), and `:` or `/`
    /// would not survive as a file name at all — so they become `-` or disappear.
    /// Hangul is put in NFC, matching how `String.noteKey` compares note names.
    static func sanitize(_ raw: String, fallback: String = anonymous) -> String {
        var out = ""
        for character in raw.precomposedStringWithCanonicalMapping {
            if character.isNewline || character.isWhitespace {
                if !out.hasSuffix("-") { out.append("-") }
                continue
            }
            if character.isLetter || character.isNumber { out.append(character); continue }
            if character == "-" || character == "_" || character == "." { out.append(character) }
        }
        while out.hasPrefix("-") || out.hasPrefix(".") { out.removeFirst() }
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        if out.count > 48 {
            out = String(out.prefix(48))
            while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        }
        guard !out.isEmpty else { return fallback }   // `..` and friends are useless as names
        return out
    }

    /// `2026-10-19-하늘.png`, with `-2`, `-3` appended when the folder already holds
    /// that name. The extension is the *stored* format, which `normalize` may have
    /// changed (a TIFF becomes a PNG).
    static func fileName(stem: String?, ext: String, date: Date = Date(), existing: Set<String> = []) -> String {
        let label = sanitize(stem ?? "")
        var candidate = "\(dayStamp(date))-\(label).\(ext)"
        var index = 2
        while existing.contains(candidate) {
            candidate = "\(dayStamp(date))-\(label)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    /// Alt text for the generated link. Unlike a file name it may keep its spaces —
    /// that is the part a screen reader says — but a `]` would end the `[...]` early
    /// and a newline would break the line, so those go.
    static func alt(for stem: String?) -> String {
        let cleaned = (stem ?? anonymous)
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        var out = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if out.count > 48 { out = String(out.prefix(48)) }
        return out.isEmpty ? anonymous : out
    }

    /// `![하늘](assets/2026-10-19-하늘.png)`
    static func markdown(alt: String, src: String) -> String { "![\(alt)](\(src))" }

    // MARK: - Where the text goes

    struct Insertion {
        let range: NSRange
        let string: String
        let selection: NSRange
    }

    /// A paste replaces a selection, and otherwise lands on its own block: never
    /// inside a sentence, and always with exactly one blank line on each side,
    /// because without that separator Markdown folds the picture into the paragraph.
    /// Nothing existing is deleted — only inserted — so one undo step is enough.
    static func plan(in ns: NSString, selection: NSRange, block: String) -> Insertion {
        if selection.length > 0 {
            return Insertion(range: selection, string: block,
                             selection: NSRange(location: selection.location + (block as NSString).length, length: 0))
        }

        let lineRange = ns.lineRange(for: selection)
        let line = ns.substring(with: lineRange)
        let content = line.hasSuffix("\n") ? String(line.dropLast()) : line
        // A blank line is filled from its own start; running text is left alone and
        // the block goes after the whole line rather than at the caret.
        let at = content.trimmingCharacters(in: .whitespaces).isEmpty ? lineRange.location : lineRange.upperBound
        let head = ns.substring(to: at)
        let tail = ns.substring(from: at)
        let string = leadingGap(head) + block + trailingGap(tail)
        let caret = at + ((leadingGap(head) + block) as NSString).length
        return Insertion(range: NSRange(location: at, length: 0), string: string,
                         selection: NSRange(location: caret, length: 0))
    }

    /// Blank line above the block, unless one is already there.
    static func leadingGap(_ head: String) -> String {
        if head.isEmpty || head.hasSuffix("\n\n") { return "" }
        return head.hasSuffix("\n") ? "\n" : "\n\n"
    }

    /// Blank line below, and a note that ends with a newline like every other file.
    static func trailingGap(_ tail: String) -> String {
        if tail.isEmpty { return "\n" }
        if tail.hasPrefix("\n\n") { return "" }
        return tail.hasPrefix("\n") ? "\n" : "\n\n"
    }

    // MARK: - Reading a pasteboard or a drop

    struct Incoming {
        let data: Data
        let ext: String
        /// Name the source offered (a dropped file), used for the label. nil for a clipboard image.
        let stem: String?
        let source: URL?
    }

    static func imageURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let raw = (try? pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true])) as [Any]?
        return (raw ?? []).compactMap { $0 as? URL }
    }

    /// Cheap enough to call on every drag-hover: raw image bytes, or a file whose
    /// extension we know how to attach.
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil { return true }
        return imageURLs(pasteboard).contains(where: isImage)
    }

    /// Pictures the pasteboard carries. File references come first and are read
    /// whole: they keep the original bytes, so a JPEG is not silently re-compressed.
    static func read(_ pasteboard: NSPasteboard) -> [Incoming] {
        var found: [Incoming] = []
        for url in imageURLs(pasteboard) where isImage(url) {
            guard let data = DocumentBytes.read(url, maxBytes: maxBytes) else { continue }
            found.append(Incoming(data: data, ext: url.pathExtension,
                                  stem: url.deletingPathExtension().lastPathComponent, source: url))
        }
        if !found.isEmpty { return found }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            guard let data = pasteboard.data(forType: type) else { continue }
            return [Incoming(data: data, ext: ext, stem: nil, source: nil)]
        }
        return []
    }

    // MARK: - Placing the bytes

    enum Failure: Error {
        /// Not a format we can store, or bytes that will not decode as a picture.
        case unsupported
        case tooLarge
        /// The folder could not be made or written — read-only volume, full disk.
        case directory
        case written
    }

    /// A paste that silently does nothing is worse than a plain message.
    static func explain(_ failure: Failure?) -> String {
        switch failure {
        case .tooLarge:      return "이미지가 너무 큽니다 — \(ByteCount(maxBytes)) 이하만 첨부합니다"
        case .unsupported:   return "이미지를 읽을 수 없습니다 — 지원하지 않는 형식입니다"
        case .directory:     return "\(directoryName)/ 폴더를 만들 수 없습니다 — 읽기 전용 폴더인가요?"
        case .written, nil:  return "이미지를 저장하지 못했습니다"
        }
    }

    struct Placed {
        /// Goes straight into the link: `assets/2026-10-19-하늘.png`.
        let relative: String
        let fileName: String
        let bytes: Int
        /// The folder already held these exact bytes, so nothing was written.
        let reused: Bool
    }

    /// TIFF (what the clipboard usually carries) and HEIC (an iPhone photo) are not
    /// browser formats, so they become PNG. Everything already web-safe is stored
    /// byte-for-byte — re-encoding a JPEG would only lose quality.
    static func normalize(_ data: Data, ext: String) -> (bytes: Data, ext: String)? {
        let lowered = ext.lowercased()
        guard supportedFormats.contains(lowered) else { return nil }
        guard convertedFormats.contains(lowered) else { return (data, lowered) }
        guard let png = pngData(from: data) else { return nil }
        return (png, "png")
    }

    static func pngData(from data: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        guard let image = NSImage(data: data),
              let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A copy of these exact bytes already in the folder, by name. Sizes are compared
    /// first so a folder of photos is not hashed from disk on every paste.
    static func reuseName(for data: Data, in directory: URL) -> String? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        let target = hash(data)
        for url in items where isImage(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard size == data.count else { continue }
            guard let other = DocumentBytes.read(url, maxBytes: maxBytes), hash(other) == target else { continue }
            return url.lastPathComponent
        }
        return nil
    }

    /// Copy (or reuse) one image into the note's own `assets/` folder.
    static func place(_ data: Data, ext: String, stem: String?, noteDirectory: URL,
                      date: Date = Date()) -> Result<Placed, Failure> {
        guard let (bytes, format) = normalize(data, ext: ext) else { return .failure(.unsupported) }
        guard bytes.count <= maxBytes else { return .failure(.tooLarge) }

        let fm = FileManager.default
        let directory = noteDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { return .failure(.directory) }
        }

        if let hit = reuseName(for: bytes, in: directory) {
            return .success(Placed(relative: "\(directoryName)/\(hit)", fileName: hit, bytes: bytes.count, reused: true))
        }

        let taken = Set(((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [])
            .map { $0.lastPathComponent })
        let name = fileName(stem: stem, ext: format, date: date, existing: taken)
        do { try bytes.write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { return .failure(.written) }
        return .success(Placed(relative: "\(directoryName)/\(name)", fileName: name, bytes: bytes.count, reused: false))
    }

    /// Only a picture that already lives in *this note's* `assets/` folder is linked
    /// where it is — dropping an attachment again must not make a second copy.
    /// Anything else is copied in, so `assets/` stays the one place images live.
    static func linkInPlace(_ url: URL, noteDirectory: URL) -> String? {
        guard isImage(url) else { return nil }
        let owned = noteDirectory.appendingPathComponent(directoryName, isDirectory: true).standardizedFileURL.path
        guard url.standardizedFileURL.deletingLastPathComponent().path == owned else { return nil }
        return "\(directoryName)/\(url.lastPathComponent)"
    }
}
