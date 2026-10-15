import AppKit

/// Editor appearance helpers + Markdown source coloring.
enum Theme {
    static var size: CGFloat = 14

    /// Appearance-aware color helper.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        }
    }

    static var base: NSFont {
        monospaced(.regular)
    }

    static var heading: NSFont {
        monospaced(.bold)
    }

    private static func monospaced(_ weight: NSFont.Weight) -> NSFont {
        let names = weight == .bold ? ["SFMono-Bold", "Menlo-Bold"] : ["SFMono-Regular", "Menlo-Regular", "Menlo"]
        for name in names {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static var text: NSColor { NSColor.labelColor }
    static var muted: NSColor { NSColor.tertiaryLabelColor }
    static var accent: NSColor { NSColor.controlAccentColor }
    static var marker: NSColor { NSColor.secondaryLabelColor }
    static var code: NSColor { dynamic(light: NSColor(srgbRed: 0.13, green: 0.45, blue: 0.28, alpha: 1),
                                      dark:  NSColor(srgbRed: 0.55, green: 0.84, blue: 0.66, alpha: 1)) }
    static var link: NSColor { dynamic(light: NSColor(srgbRed: 0.00, green: 0.42, blue: 0.86, alpha: 1),
                                       dark:  NSColor(srgbRed: 0.48, green: 0.72, blue: 1.00, alpha: 1)) }
    static var emphasis: NSColor { dynamic(light: NSColor(srgbRed: 0.62, green: 0.36, blue: 0.05, alpha: 1),
                                           dark:  NSColor(srgbRed: 1.00, green: 0.72, blue: 0.35, alpha: 1)) }
    static var editorBackground: NSColor { dynamic(light: NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1),
                                                   dark:  NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)) }
}

enum Highlighter {

    struct Rule {
        let pattern: String
        let options: NSRegularExpression.Options
        let color: NSColor
        let font: NSFont?
        let underline: Bool

        init(_ pattern: String,
             options: NSRegularExpression.Options = [],
             color: NSColor,
             font: NSFont? = nil,
             underline: Bool = false) {
            self.pattern = pattern
            self.options = options
            self.color = color
            self.font = font
            self.underline = underline
        }
    }

    private static let rules: [Rule] = [
        Rule("```[^`]*```", color: Theme.code),
        Rule("^#{1,6} .*$", options: [.anchorsMatchLines], color: Theme.accent, font: Theme.heading),
        Rule("^\\s*>.*$", options: [.anchorsMatchLines], color: Theme.muted),
        Rule("`[^`\\n]+`", color: Theme.code),
        Rule("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__", color: Theme.emphasis),
        Rule("(?<!\\*)\\*[^*\\n]+\\*(?!\\*)", color: Theme.emphasis),
        Rule("(?<![\\w_])_[^_\\n]+_(?![\\w_])", color: Theme.emphasis),
        Rule("~~[^~\\n]+~~", color: Theme.muted),
        Rule("!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", color: Theme.link, underline: true),
        Rule("^(\\s*)(-{3,}|\\*{3,}|_{3,})\\s*$", options: [.anchorsMatchLines], color: Theme.marker),
        Rule("^(\\s*)([-*+]|\\d+[.)])(?= )", options: [.anchorsMatchLines], color: Theme.marker),
    ]

    /// Recolors the whole text storage. Fast enough for note-sized documents.
    static func apply(to storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)

        storage.setAttributes([
            .font: Theme.base,
            .foregroundColor: Theme.text,
        ], range: full)

        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            for m in re.matches(in: storage.string, range: full) {
                guard m.range.length > 0, m.range.upperBound <= storage.length else { continue }
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: rule.color]
                if let font = rule.font { attrs[.font] = font }
                if rule.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                storage.addAttributes(attrs, range: m.range)
            }
        }
    }
}
