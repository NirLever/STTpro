import Foundation

/// Replaces spoken punctuation words with punctuation characters.
/// Port of src/STTpro.Core/Stt/PunctuationReplacer.cs. Difference: French
/// words ("point", "virgule", …) only apply when the detected language is
/// French, so English "point" isn't turned into ".".
public enum PunctuationReplacer {
    private static let english: [(String, String)] = [
        ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
        ("period", "."), ("full stop", "."), ("comma", ","), ("colon", ":"), ("semicolon", ";"),
        ("open parenthesis", "("), ("close parenthesis", ")"), ("open bracket", "["), ("close bracket", "]"),
        ("open quote", "\""), ("close quote", "\""), ("quotation mark", "\""), ("apostrophe", "'"),
        ("hyphen", "-"), ("dash", " — "), ("ellipsis", "..."), ("ampersand", "&"), ("at sign", "@"),
        ("hashtag", "#"), ("percent", "%"), ("dollar sign", "$"), ("new line", "\n"), ("new paragraph", "\n\n"),
    ]

    private static let hebrew: [(String, String)] = [
        ("סימן שאלה", "?"), ("סימן קריאה", "!"), ("נקודה-פסיק", ";"), ("נקודה פסיק", ";"),
        ("נקודתיים", ":"), ("נקודה", "."), ("פסיק", ","), ("סוגריים פותחים", "("), ("סוגריים סוגרים", ")"),
        ("מרכאות", "\""), ("גרש", "'"), ("מקף", "-"), ("שלוש נקודות", "..."), ("שורה חדשה", "\n"),
        ("פסקה חדשה", "\n\n"),
    ]

    private static let french: [(String, String)] = [
        ("point d'interrogation", "?"), ("point d'exclamation", "!"), ("point-virgule", ";"),
        ("point virgule", ";"), ("points de suspension", "..."), ("point", "."), ("virgule", ","),
        ("deux-points", ":"), ("deux points", ":"), ("parenthèse ouvrante", "("), ("parenthèse fermante", ")"),
        ("guillemets", "\""), ("tiret", "-"), ("nouvelle ligne", "\n"), ("nouveau paragraphe", "\n\n"),
    ]

    /// - Parameter language: detected language from the STT provider
    ///   ("english", "french", "fr", …); nil/unknown applies English + Hebrew only.
    public static func apply(_ text: String, language: String? = nil) -> String {
        guard !text.isEmpty else { return text }
        var rules = english + hebrew
        let lang = (language ?? "").lowercased()
        if lang == "fr" || lang.hasPrefix("french") { rules += french }

        var result = text
        for (spoken, replacement) in rules {
            result = replace(result, spoken, with: replacement)
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func isAttachingPunctuation(_ c: Character) -> Bool {
        ".,!?:;)]\"'".contains(c)
    }

    private static func replace(_ source: String, _ spoken: String, with replacement: String) -> String {
        var s = source
        var searchFrom = s.startIndex
        while searchFrom < s.endIndex,
              let r = s.range(of: spoken, options: [.caseInsensitive], range: searchFrom..<s.endIndex) {
            let leftOK = r.lowerBound == s.startIndex || !isWordChar(s[s.index(before: r.lowerBound)])
            let rightOK = r.upperBound == s.endIndex || !isWordChar(s[r.upperBound])
            guard leftOK && rightOK else {
                searchFrom = r.upperBound
                continue
            }
            var start = r.lowerBound
            if start > s.startIndex, s[s.index(before: start)] == " ",
               let first = replacement.first, isAttachingPunctuation(first) {
                start = s.index(before: start)
            }
            let offset = s.distance(from: s.startIndex, to: start) + replacement.count
            s.replaceSubrange(start..<r.upperBound, with: replacement)
            searchFrom = s.index(s.startIndex, offsetBy: min(offset, s.count))
        }
        return s
    }

    /// Adds "." when the text doesn't already end with punctuation.
    public static func addTrailingPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.unicodeScalars.last else { return text }
        if CharacterSet.punctuationCharacters.contains(last) || CharacterSet.symbols.contains(last) {
            return trimmed
        }
        return trimmed + "."
    }
}
