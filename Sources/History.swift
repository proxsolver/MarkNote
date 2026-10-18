import AppKit
import CryptoKit

/// A note's bytes exactly as they sit on disk. History stores and compares these
/// rather than the editor's text, so a note that is really RTF wearing a `.md`
/// name (see `DocumentText`) can be handed back as the RTF it was — not as a
/// UTF-8 re-encoding of what the editor happened to display.
enum DocumentBytes {
    /// `nil` when there is nothing to keep: no file, or one big enough that
    /// copying it on the main thread during an autosave would be felt as a stall.
    static func read(_ url: URL, maxBytes: Int = NoteHistory.maxBytes) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// First `maxBytes` of a file, for a cheap one-line preview of a snapshot.
    static func head(_ url: URL, maxBytes: Int = 8_192) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// One archived version of one note: `<ms>-<sha256-12>.md` inside `.marknote-history`.
/// The stamp is the moment the archived bytes were replaced, and the hash is both the
/// de-duplication key and the integrity check used before anything is written back.
struct Snapshot: Identifiable, Equatable {
    let url: URL
    let savedAt: Date
    let bytes: Int
    let hash: String

    var id: String { url.path }

    /// `1730000000123-2f9c…` → a snapshot, or `nil` for anything a person dropped in
    /// the folder by hand. Unparseable names are skipped rather than guessed at.
    static func parse(_ url: URL) -> Snapshot? {
        let base = url.deletingPathExtension().lastPathComponent
        guard let split = base.firstIndex(of: "-") else { return nil }
        let stamp = base[..<split]
        let hash = base[base.index(after: split)...]
        guard let ms = Int(stamp), ms > 0, hash.count >= 8 else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Snapshot(url: url, savedAt: Date(timeIntervalSince1970: Double(ms) / 1000),
                        bytes: size, hash: String(hash))
    }
}

/// Archive of previous versions, one folder per note:
/// `<노트 폴더>/.marknote-history/<노트 이름>.snapshots/<ms>-<hash>.md`.
///
/// Deliberately stateless: every path is derived from the note itself, so changing
/// folders, opening a note from elsewhere, or a nested subfolder needs no bookkeeping
/// and cannot leak one note's versions into another. The directory starts with a dot,
/// which keeps it out of the sidebar (`reloadList` skips hidden files) and out of the
/// reference scanner, which only ever reads the listed notes.
final class NoteHistory {
    static let directoryName = ".marknote-history"
    /// Snapshots kept per note. Older ones are deleted as newer ones arrive.
    static let limit = 30
    /// Anything above this is not archived (see `DocumentBytes.read`).
    static let maxBytes = 8_000_000

    // MARK: - Paths

    /// `<노트 폴더>/.marknote-history`
    func container(for doc: Doc) -> URL {
        doc.url.deletingLastPathComponent().appendingPathComponent(NoteHistory.directoryName, isDirectory: true)
    }

    /// `<노트 폴더>/.marknote-history/<노트 이름>.snapshots`
    func directory(for doc: Doc) -> URL {
        container(for: doc).appendingPathComponent(doc.title + ".snapshots", isDirectory: true)
    }

    /// The folder the archive lives in, but only once it actually exists — used by
    /// "히스토리 폴더 열기", which must not open a path Finder would reject.
    func existingDirectory(for doc: Doc) -> URL? {
        let url = directory(for: doc)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    // MARK: - Archiving

    /// Store the bytes that are about to be overwritten. Returns `nil` — and writes
    /// nothing — when the newest archive already holds exactly these bytes, which is
    /// what keeps a revert-and-save round trip from padding the archive.
    @discardableResult
    func capture(_ previous: Data, for doc: Doc) -> Snapshot? {
        guard !previous.isEmpty else { return nil }
        let hash = NoteHistory.hash(of: previous)
        if let newest = snapshots(for: doc).first, newest.hash == hash { return nil }
        let dir = directory(for: doc)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            try previous.write(to: dir.appendingPathComponent("\(stamp)-\(hash).md"), options: .atomic)
        } catch {
            return nil
        }
        prune(for: doc)
        return snapshots(for: doc).first { $0.hash == hash }
    }

    /// Newest first, whatever the volume's enumeration order happens to be.
    func snapshots(for doc: Doc) -> [Snapshot] {
        let dir = directory(for: doc)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return [] }
        return items.compactMap(Snapshot.parse)
            .sorted { $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : $0.hash > $1.hash }
    }

    /// Drop everything past `limit`. Called after each archive write, so the folder
    /// never grows unbounded on a note that is saved every few seconds.
    @discardableResult
    func prune(for doc: Doc) -> Int {
        let stale = snapshots(for: doc).dropFirst(NoteHistory.limit)
        for snap in stale { try? FileManager.default.removeItem(at: snap.url) }
        return stale.count
    }

    // MARK: - Restoring

    /// Write an archived version back over the note. Guarded twice: the file must
    /// still be readable, and its bytes must still hash to what the name claims —
    /// so a hand-edited or truncated snapshot is refused instead of installed.
    func restore(_ snap: Snapshot, to doc: Doc) -> Bool {
        guard let data = try? Data(contentsOf: snap.url) else { return false }
        guard NoteHistory.hash(of: data) == snap.hash else { return false }
        return (try? data.write(to: doc.url, options: .atomic)) != nil
    }

    // MARK: - Moving / clearing

    /// Rename a note and its archive together, so the versions of `회의.md` do not
    /// become orphans the moment the file becomes `주간 회의.md`.
    @discardableResult
    func move(from doc: Doc, to destination: URL) -> Bool {
        guard existingDirectory(for: doc) != nil else { return false }
        let renamed = Doc(url: destination)
        let target = directory(for: renamed)
        guard target.path != directory(for: doc).path else { return false }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: directory(for: doc), to: target)
            return true
        } catch {
            return false
        }
    }

    /// Delete a note's whole archive. The note itself is untouched, which is why the
    /// caller asks first. Returns the number of archived versions removed.
    @discardableResult
    func clear(_ doc: Doc) -> Int {
        guard let dir = existingDirectory(for: doc) else { return 0 }
        let count = snapshots(for: doc).count
        do {
            try FileManager.default.removeItem(at: dir)
            removeEmptyContainerIfUnused(for: doc)
            return count
        } catch {
            return 0
        }
    }

    /// Bytes the archive occupies for this note, for the panel's caption.
    func usedBytes(for doc: Doc) -> Int {
        snapshots(for: doc).reduce(0) { $0 + $1.bytes }
    }

    /// Leave `.marknote-history` behind only while some other note still uses it.
    private func removeEmptyContainerIfUnused(for doc: Doc) {
        let dir = container(for: doc)
        guard let rest = try? FileManager.default.contentsOfDirectory(atPath: dir.path), rest.isEmpty else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Identity

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Labels

/// How an archived version is described to a person. Split out from the view so the
/// wording can be checked without a window.
enum HistoryRow {
    /// "10/19 오후 2:31 · 4.2 KB · 3분 전"
    static func title(_ snap: Snapshot) -> String {
        "\(snap.savedAt.historyStamp) · \(size(snap.bytes)) · \(snap.savedAt.timeAgoShort)"
    }

    /// A note is usually a few hundred bytes, and `ByteCountFormatter` rounds that to
    /// "0 KB" — useless when the whole point is telling two versions apart.
    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : ByteCount(bytes)
    }

    /// The first real line of the archived text — a heading beats the blank that
    /// usually follows it, and whitespace inside the line is folded away.
    static func preview(_ snap: Snapshot, width: Int = 64) -> String {
        guard let head = DocumentBytes.head(snap.url) else { return "" }
        let text = DocumentText.looksLikeRTF(head) ? (DocumentText.read(snap.url).text) : head
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.count > width { return String(line.prefix(width)) + "…" }
            return line
        }
        return ""
    }

    /// "이전 버전 3개 · 46 KB · 최신 3분 전"
    static func summary(_ snaps: [Snapshot]) -> String {
        guard !snaps.isEmpty else { return "이전 버전 없음" }
        let bytes = snaps.reduce(0) { $0 + $1.bytes }
        return "이전 버전 \(snaps.count)개 · \(size(bytes)) · 최신 \(snaps.first?.savedAt.timeAgoShort ?? "")"
    }
}

extension Date {
    /// A full stamp for the history list: the archive is read days later, so "수" is
    /// not enough the way it is in the sidebar.
    var historyStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.setLocalizedDateFormatFromTemplate("M/d EEE a h:mm")
        return formatter.string(from: self)
    }
}
