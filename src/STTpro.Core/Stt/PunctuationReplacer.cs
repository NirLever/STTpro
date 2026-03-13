namespace STTpro.Core.Stt;

/// <summary>
/// Replaces spoken punctuation words with actual punctuation characters.
/// Supports English, Hebrew, French, and other languages.
/// </summary>
public static class PunctuationReplacer
{
    private static readonly (string spoken, string replacement)[] Replacements =
    [
        // English
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("period", "."),
        ("full stop", "."),
        ("comma", ","),
        ("colon", ":"),
        ("semicolon", ";"),
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("open bracket", "["),
        ("close bracket", "]"),
        ("open quote", "\""),
        ("close quote", "\""),
        ("quotation mark", "\""),
        ("apostrophe", "'"),
        ("hyphen", "-"),
        ("dash", " — "),
        ("ellipsis", "..."),
        ("ampersand", "&"),
        ("at sign", "@"),
        ("hashtag", "#"),
        ("percent", "%"),
        ("dollar sign", "$"),
        ("new line", "\n"),
        ("new paragraph", "\n\n"),

        // Hebrew punctuation words
        ("סימן שאלה", "?"),
        ("סימן קריאה", "!"),
        ("נקודה", "."),
        ("פסיק", ","),
        ("נקודתיים", ":"),
        ("נקודה-פסיק", ";"),
        ("נקודה פסיק", ";"),
        ("סוגריים פותחים", "("),
        ("סוגריים סוגרים", ")"),
        ("מרכאות", "\""),
        ("גרש", "'"),
        ("מקף", "-"),
        ("שלוש נקודות", "..."),
        ("שורה חדשה", "\n"),
        ("פסקה חדשה", "\n\n"),

        // French punctuation words
        ("point d'interrogation", "?"),
        ("point d'exclamation", "!"),
        ("point", "."),
        ("virgule", ","),
        ("deux-points", ":"),
        ("deux points", ":"),
        ("point-virgule", ";"),
        ("point virgule", ";"),
        ("parenthèse ouvrante", "("),
        ("parenthèse fermante", ")"),
        ("guillemets", "\""),
        ("apostrophe", "'"),
        ("tiret", "-"),
        ("points de suspension", "..."),
        ("nouvelle ligne", "\n"),
        ("nouveau paragraphe", "\n\n"),
    ];

    public static string Apply(string text)
    {
        if (string.IsNullOrEmpty(text))
            return text;

        var result = text;

        foreach (var (spoken, replacement) in Replacements)
        {
            result = ReplaceCaseInsensitive(result, spoken, replacement);
        }

        // Clean up extra spaces around punctuation
        result = CleanupSpacing(result);

        return result;
    }

    private static string ReplaceCaseInsensitive(string source, string oldValue, string newValue)
    {
        int index = 0;
        while ((index = source.IndexOf(oldValue, index, StringComparison.OrdinalIgnoreCase)) >= 0)
        {
            // Check word boundaries to avoid partial matches
            bool leftBoundary = index == 0 || !char.IsLetterOrDigit(source[index - 1]);
            int endIndex = index + oldValue.Length;
            bool rightBoundary = endIndex >= source.Length || !char.IsLetterOrDigit(source[endIndex]);

            if (leftBoundary && rightBoundary)
            {
                // Remove leading space if punctuation attaches to previous word
                int removeStart = index;
                if (removeStart > 0 && source[removeStart - 1] == ' ' &&
                    newValue.Length > 0 && IsPunctuationChar(newValue[0]))
                {
                    removeStart--;
                }

                source = source[..removeStart] + newValue + source[endIndex..];
                index = removeStart + newValue.Length;
            }
            else
            {
                index += oldValue.Length;
            }
        }

        return source;
    }

    private static bool IsPunctuationChar(char c)
    {
        return c is '.' or ',' or '!' or '?' or ':' or ';' or ')' or ']' or '"' or '\'';
    }

    private static string CleanupSpacing(string text)
    {
        // Remove double spaces
        while (text.Contains("  "))
            text = text.Replace("  ", " ");

        return text.Trim();
    }
}
