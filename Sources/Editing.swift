import AppKit

/// Text mutations shared by menu commands and keyboard shortcuts.
/// Every entry point works on the focused NSTextView and keeps
/// undo registration + selection sane.
enum Editing {

    // MARK: - Plumbing

    /// One text mutation, one undo step.
    ///
    /// AppKit registers undo only for edits that arrive through an input event, so a
    /// command-driven replacement — bold, a list toggle, a pasted picture — would sit
    /// outside ⌘Z. Put it back by hand: the same call re-registers the inverse while
    /// the manager is undoing, so redo comes along for free.
    static func replace(_ tv: NSTextView, _ range: NSRange, _ string: String, selection: NSRange? = nil,
                        undoLabel: String = "") {
        let ns = tv.string as NSString
        guard range.location >= 0, range.upperBound <= ns.length else { return }
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        let previous = ns.substring(with: range)
        let restore = selection ?? NSRange(location: range.location + (string as NSString).length, length: 0)

        tv.textStorage?.replaceCharacters(in: range, with: string)
        tv.didChangeText()
        tv.setSelectedRange(restore)
        tv.scrollRangeToVisible(restore)

        guard previous != string, let undo = tv.undoManager else { return }
        undo.registerUndo(withTarget: tv) { view in
            replace(view, range, previous, selection: restore, undoLabel: undoLabel)
        }
        if !undoLabel.isEmpty { undo.setActionName(undoLabel) }
    }

    static func lineRanges(_ ns: NSString) -> [NSRange] {
        let length = ns.length
        if length == 0 { return [NSRange(location: 0, length: 0)] }
        var result: [NSRange] = []
        var start = 0
        for i in 0..<length {
            if ns.character(at: i) == 0x0A {
                result.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
        }
        result.append(NSRange(location: start, length: length - start))
        return result
    }

    static func selectedLineRanges(_ tv: NSTextView) -> [NSRange] {
        let ns = tv.string as NSString
        let all = lineRanges(ns)
        let sel = tv.selectedRange()
        let touched = all.filter { $0.location <= sel.upperBound && $0.upperBound >= sel.location }
        return touched.isEmpty ? [NSRange(location: sel.location, length: 0)] : touched
    }

    private static func slice(_ ns: NSString, _ r: NSRange) -> String {
        guard r.location >= 0, r.upperBound <= ns.length else { return "" }
        return ns.substring(with: r)
    }

    private static func rewrite(_ tv: NSTextView, lines: [NSRange], transform: (String) -> String) {
        guard let first = lines.first, let last = lines.last else { return }
        let ns = tv.string as NSString
        let whole = NSRange(location: first.location, length: last.location + last.length - first.location)
        let merged = lines.map { transform(slice(ns, $0)) }.joined(separator: "\n")
        replace(tv, whole, merged, selection: NSRange(location: whole.location, length: (merged as NSString).length))
    }

    // MARK: - Inline wrapping (bold / italic / code / strike)

    static func toggleWrap(_ tv: NSTextView, _ left: String, _ right: String, placeholder: String) {
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let full = slice(ns, sel)

        // Selection itself is wrapped -> unwrap it.
        if full.hasPrefix(left), full.hasSuffix(right), (full as NSString).length >= (left as NSString).length + (right as NSString).length {
            let inner = String(full.dropFirst(left.count).dropLast(right.count))
            replace(tv, sel, inner, selection: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }

        // Markers sit just around the selection -> remove them.
        let around = NSRange(location: max(0, sel.location - left.count),
                             length: sel.length + left.count + right.count)
        if around.location + around.length <= ns.length, around.location == sel.location - left.count {
            let chunk = slice(ns, around)
            if chunk.hasPrefix(left), chunk.hasSuffix(right) {
                let inner = String(chunk.dropFirst(left.count).dropLast(right.count))
                replace(tv, around, inner, selection: NSRange(location: around.location, length: (inner as NSString).length))
                return
            }
        }

        let content = full.isEmpty ? placeholder : full
        replace(tv, sel, left + content + right,
                selection: NSRange(location: sel.location + left.count, length: (content as NSString).length))
    }

    // MARK: - Links

    static func insertLink(_ tv: NSTextView) {
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let label = slice(ns, sel)
        let body = label.isEmpty ? "링크 텍스트" : label
        let inserted = "[\(body)](https://)" as NSString
        let urlStart = inserted.range(of: "](").location + 2
        replace(tv, sel, inserted as String, selection: NSRange(location: sel.location + urlStart, length: 8))
    }

    // MARK: - Line prefixes (heading / list / quote)

    static func setHeading(_ tv: NSTextView, level: Int) {
        let ns = tv.string as NSString
        let lines = selectedLineRanges(tv)
        let marker = String(repeating: "#", count: level) + " "
        let allReady = lines.allSatisfy { slice(ns, $0).hasPrefix(marker) }
        let target = allReady ? "" : marker
        rewrite(tv, lines: lines) { line in
            let bare = line.replacingOccurrences(of: "^#{1,6} ", with: "", options: .regularExpression)
            return target + bare
        }
    }

    static func clearHeading(_ tv: NSTextView) {
        let lines = selectedLineRanges(tv)
        rewrite(tv, lines: lines) { $0.replacingOccurrences(of: "^#{1,6} ", with: "", options: .regularExpression) }
    }

    private static let listPattern = #"^(\s*)([-*+]|\d+[.)])\s+"#
    private static let bulletOnly = #"^(\s*)([-*+])\s+"#
    private static let numberOnly = #"^(\s*)(\d+)([.)])\s+"#

    static func toggleList(_ tv: NSTextView, ordered: Bool) {
        let ns = tv.string as NSString
        let lines = selectedLineRanges(tv)
        let want = ordered ? numberOnly : bulletOnly

        // Already exactly the requested kind -> remove the markers.
        let allRequested = lines.allSatisfy { slice(ns, $0).range(of: want, options: .regularExpression) != nil }
        if allRequested {
            rewrite(tv, lines: lines) { $0.replacingOccurrences(of: listPattern, with: "", options: .regularExpression) }
            return
        }

        // Otherwise convert every touched line to the requested kind, keeping an existing number.
        var index = 0
        rewrite(tv, lines: lines) { line in
            index += 1
            if ordered, let hit = line.range(of: numberOnly, options: .regularExpression) {
                let digits = line[hit].filter { $0.isNumber }
                if let existing = Int(digits), existing > index { index = existing }
            }
            let bare = line.replacingOccurrences(of: listPattern, with: "", options: .regularExpression)
            return ordered ? "\(index). \(bare)" : "- \(bare)"
        }
    }

    static func toggleQuote(_ tv: NSTextView) {
        let ns = tv.string as NSString
        let lines = selectedLineRanges(tv)
        let allReady = lines.allSatisfy {
            let l = slice(ns, $0)
            return l.hasPrefix("> ") || l == ">"
        }
        rewrite(tv, lines: lines) { line in
            let bare = line.replacingOccurrences(of: "^\\s*> ?", with: "", options: .regularExpression)
            return allReady ? bare : "> " + bare
        }
    }

    static func toggleCodeBlock(_ tv: NSTextView) {
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let body = slice(ns, sel)
        if body.hasPrefix("```"), body.hasSuffix("```") {
            let inner = String(body.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            replace(tv, sel, inner, selection: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }

        // Caret/selection sits between a pair of fence lines -> drop the fences.
        let all = lineRanges(ns)
        let touched = all.indices.filter { all[$0].location <= sel.upperBound && all[$0].upperBound >= sel.location }
        if let firstIdx = touched.first, let lastIdx = touched.last,
           firstIdx > 0, lastIdx + 1 < all.count,
           slice(ns, all[firstIdx - 1]).trimmingCharacters(in: .whitespaces) == "```",
           slice(ns, all[lastIdx + 1]).trimmingCharacters(in: .whitespaces) == "```" {
            let whole = NSRange(location: all[firstIdx - 1].location,
                                length: all[lastIdx + 1].upperBound - all[firstIdx - 1].location)
            let content = all[firstIdx...lastIdx].map { slice(ns, $0) }.joined(separator: "\n")
            replace(tv, whole, content, selection: NSRange(location: whole.location, length: (content as NSString).length))
            return
        }

        let lines = selectedLineRanges(tv)
        guard let first = lines.first, let last = lines.last else { return }
        let block = lines.map { slice(ns, $0) }.joined(separator: "\n")
        let content = block.isEmpty ? "code" : block
        let contentNS = content as NSString
        let whole = NSRange(location: first.location, length: last.upperBound - first.location)
        let inserted = "```\n" + content + "\n```"
        replace(tv, whole, inserted,
                selection: NSRange(location: whole.location + 4, length: contentNS.length))
    }

    static func insertHR(_ tv: NSTextView) {
        replace(tv, tv.selectedRange(), "\n---\n")
    }

    // MARK: - Typing behaviours

    /// Continues lists when the user presses Return.
    /// Returns the string to insert; "" means "already handled".
    static func smartNewline(in tv: NSTextView) -> String? {
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return nil }
        let lineRange = ns.lineRange(for: sel)
        let line = ns.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
        let pattern = #"^(\s*)([-*+]|(\d+)([.)]))\s+(\[[ xX]\]\s+)?(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }

        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return "" }
            return (line as NSString).substring(with: r)
        }

        let indent = group(1), bullet = group(2), numberText = group(3), closer = group(4)
        let checkbox = group(5), rest = group(6)

        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item -> clear its marker and leave the list.
            let raw = ns.substring(with: lineRange)
            let replacement = raw.hasSuffix("\n") ? "\n" : ""
            replace(tv, lineRange, replacement, selection: NSRange(location: lineRange.location, length: 0))
            return ""
        }

        var marker = indent + bullet + " "
        if let number = Int(numberText) {
            marker = indent + "\(number + 1)" + closer + " "
        }
        if !checkbox.isEmpty { marker += "[ ] " }
        return "\n" + marker
    }

    /// Tab / Shift-Tab indentation. Returns "" when handled, nil for default behaviour.
    static func tab(in tv: NSTextView, shift: Bool) -> String? {
        let indent = "  "
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        guard sel.length > 1 else { return shift ? nil : indent }

        let lines = selectedLineRanges(tv)
        guard lines.count > 1 else { return shift ? nil : indent }

        if shift {
            rewrite(tv, lines: lines) { line in
                if line.hasPrefix(indent) { return String(line.dropFirst(indent.count)) }
                if line.hasPrefix(" ") || line.hasPrefix("\t") { return String(line.dropFirst()) }
                return line
            }
        } else {
            rewrite(tv, lines: lines) { indent + $0 }
        }
        return ""
    }
}
