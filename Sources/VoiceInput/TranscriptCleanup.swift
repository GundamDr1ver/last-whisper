import Foundation

/// Conservative local cleanup. Whisper supplies sentence boundaries; rules never guess clauses.
enum TranscriptCleanup {
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Only isolated hesitation sounds; do not strip meaningful 那个/然后/就是 or reduplication.
        replace(#"(^|[，,。.!！?？\s])(?:嗯+|呃+)(?:[，,\s]+|$)"#, "$1")
        replace(#"(?i)(?<![\p{L}\p{N}_])(?:um+|uh+|uhm+|erm+)(?![\p{L}\p{N}_])[,，]?\s*"#, "")
        // A small set of unmistakable pronoun restarts; avoid changing names or numbers.
        replace(#"(?i)\b(I|we|you|he|she|it|they)(?:[ \t]+\1)+\b"#, "$1")
        replace(#"(我们|你们|他们)(?:[ \t]*\1)+"#, "$1")
        // Convert punctuation only next to Han text. Decimals, URLs and English sentences survive.
        replace(#"(?<=\p{Han})[,，][ \t]*"#, "，")
        replace(#"[,，][ \t]*(?=\p{Han})"#, "，")
        replace(#"(?<=\p{Han})[!！]"#, "！")
        replace(#"(?<=\p{Han})[?？]"#, "？")
        replace(#"(?<=\p{Han})\.(?=\s|$|\p{Han})"#, "。")
        replace(#"[ \t]+(?=[，。！？；：])"#, "")
        replace(#"[ \t]{2,}"#, " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return "" }
        let hasHan = text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        // Do not invent terminal punctuation for URLs, paths, code or a trailing quoted fragment.
        let tail = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let protectedTail = tail.contains("://") || tail.contains("/") || tail.contains("@") || tail.contains("`") || tail.contains("_")
        if hasHan, (last.isLetter || last.isNumber), !protectedTail { text += "。" }
        return text
    }
}
