import Foundation
import CryptoKit
import NativeText

/// WeText owns number parsing; this actor confines its native handle off the UI thread.
actor NumberNormalization {
    static let shared = NumberNormalization()
    private var processor: UnsafeMutableRawPointer?
    private var protectedWords: NSRegularExpression?
    private static let candidates = try! NSRegularExpression(pattern: #"(?:百分之)?[负正]?[零〇一二两三四五六七八九十百千万亿幺0-9]+(?:[点.][零〇一二两三四五六七八九十百千万亿幺0-9]+)*"#)
    private static let literals = try! NSRegularExpression(pattern: #"https?://[^\s，。！？；、]+|www\.[^\s，。！？；、]+|`[^`\r\n]*`"#)
    private static let prefix = try! NSRegularExpression(pattern: #"(?:(?:版本(?:号)?|数字|数值|编号|序号|型号|价格|金额|比例|利率|等于)(?:是|为)?|第)$"#)
    private static let unit = try! NSRegularExpression(pattern: #"^(?:个|元|块|岁|年|月|日|号|小时|分钟|秒|毫秒|厘米|毫米|米|公里|克|千克|公斤|吨|摄氏度|度|倍|页|章|节|台|件|次|条|张|位|天|周|GB|MB|TB|KB|kg|km|cm|mm|%)"#)
    /// Spoken digit runs: 九零六零, 四零九零, 二零二四. A 零 inside a run of two or
    /// more digits is the signal; 一五一十, 三三两两 and 一一对应 have no 零 and the
    /// place-value guard below already covers 十百千万亿.
    private static let digitRun = try! NSRegularExpression(pattern: #"^[零〇一二三四五六七八九幺]{2,}$"#)
    private static let zeroInside = try! NSRegularExpression(pattern: #"[零〇]"#)
    /// Idioms that look like digit runs. Kept here because build-text-normalizer.sh
    /// copies the upstream whitelist over protected-words.tsv.
    private static let extraProtected = try! NSRegularExpression(pattern: #"七零八落|七零八碎|零七八碎|五零四散|零零星星|三三两两|七七八八|一一对应"#)
    /// ASR spells acronyms letter by letter: A.M.D / A M D should read AMD.
    /// Uppercase only, so e.g. / i.e. / a.m. and file names keep their dots.
    private static let spelledDots = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:[A-Z]\.){2,}"#)
    private static let spelledSpaces = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:[A-Z][ \t]+){2,}[A-Z](?![A-Za-z0-9])"#)
    deinit { if let processor { wetext_destroy_processor(processor) } }

    func prepare() throws {
        guard processor == nil else { return }
        func graph(_ name: String, digest: String) throws -> URL {
            guard let url = Bundle.module.url(forResource: name, withExtension: "fst", subdirectory: "Resources/WeText"),
                  SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw Failure("数字转换规则缺失或校验失败。")
            }
            return url
        }
        let tagger = try graph("zh_itn_tagger", digest: "ae9f5389aa65c1d24dc7bc761fe0b9c751bb76a152cc917af5bc52bb93b76563")
        let verbalizer = try graph("zh_itn_verbalizer", digest: "6aead1b68211a2bb56b6805e7840034e076b17b176d703cea153d15262680f53")
        guard let words = Bundle.module.url(forResource: "protected-words", withExtension: "tsv", subdirectory: "Resources/WeText") else { throw Failure("数字转换保护词表缺失。") }
        let alternatives = try String(contentsOf: words, encoding: .utf8).split(whereSeparator: \.isNewline)
            .compactMap { $0.split(separator: "\t").first }.map { NSRegularExpression.escapedPattern(for: String($0)) }
        let protection = try NSRegularExpression(pattern: alternatives.joined(separator: "|"))
        guard let handle = wetext_create_processor(tagger.path, verbalizer.path) else { throw Failure("数字转换引擎无法加载。") }
        protectedWords = protection; processor = handle
    }
    func normalize(_ text: String) throws -> String {
        try Task.checkCancellation()
        guard text.range(of: #"[零〇一二两三四五六七八九十百千万亿幺点负]"#, options: .regularExpression) != nil else { return Self.joinSpelledLetters(text) }
        try prepare()
        guard let processor, let protectedWords else { throw Failure("数字转换引擎尚未就绪。") }
        let whole = NSRange(text.startIndex..., in: text)
        let protected = (protectedWords.matches(in: text, range: whole) + Self.literals.matches(in: text, range: whole) + Self.extraProtected.matches(in: text, range: whole)).map(\.range)
        var output = text
        for match in Self.candidates.matches(in: text, range: whole).reversed() {
            try Task.checkCancellation()
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range])
            guard candidate.range(of: #"[零〇一二两三四五六七八九十百千万亿幺点负]"#, options: .regularExpression) != nil else { continue }
            let before = String(text[..<range.lowerBound].suffix(12)), after = String(text[range.upperBound...].prefix(12))
            let isolated = before.last?.isLetter != true && before.last?.isNumber != true && after.first?.isLetter != true && after.first?.isNumber != true
            let cue = Self.prefix.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil
            let unit = Self.unit.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil
            let time = after.hasPrefix("点") && (after.hasPrefix("点钟") || after.hasPrefix("点整") || before.range(of: #"(?:上午|下午|中午|凌晨|早上|晚上)$"#, options: .regularExpression) != nil)
            // Bare 一点 and spoken ranges are ambiguous; preserve them unless numeric context is clear.
            // A spoken digit run (九零六零/四零九零) is a serial number even between Han or Latin letters.
            let serial = Self.digitRun.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
                && Self.zeroInside.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
                && Set(candidate).count > 1
            guard isolated || cue || unit || time || serial || candidate.contains("点") || candidate.hasPrefix("百分之") else { continue }
            guard candidate.range(of: #"[一二三四五六七八九][一二三四五六七八九][十百千万亿]|[十百千万亿][一二三四五六七八九]{2,}$"#, options: .regularExpression) == nil else { continue }
            let digits = Array("零一二三四五六七八九")
            let spoken = String(candidate.map { character -> Character in
                if let digit = character.asciiValue, digit >= 48, digit <= 57 { return digits[Int(digit - 48)] }
                return character == "." ? "点" : character
            })
            let normalized: String
            if spoken.contains("点"), !spoken.hasPrefix("百分之") {
                let parts = spoken.components(separatedBy: "点")
                let integer = try convert(parts[0], processor: processor)
                let digitValues: [Character: Character] = ["零": "0", "〇": "0", "幺": "1", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
                let fractions = parts.dropFirst().map { part in part.compactMap { digitValues[$0] } }
                guard integer.range(of: #"^[+-]?[0-9]+$"#, options: .regularExpression) != nil,
                      zip(parts.dropFirst(), fractions).allSatisfy({ $0.count == $1.count }) else { continue }
                // WeText's time rule reads 零点零五 as 00:05; numeric segments keep decimal zeros.
                normalized = ([integer] + fractions.map { String($0) }).joined(separator: ".")
            } else { normalized = try convert(spoken, processor: processor) }
            guard normalized.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)*(?:万|亿)?%?$"#, options: .regularExpression) != nil else { continue }
            // Replace backwards using original UTF-16 offsets, preserving all untouched text and line breaks.
            if let destination = Range(match.range, in: output) { output.replaceSubrange(destination, with: normalized) }
        }
        return Self.joinSpelledLetters(output)
    }
    /// Joins letter-by-letter spelling produced by ASR: A.M.D → AMD, U.S.A. → USA,
    /// A M D → AMD. Only uppercase single letters are joined, so e.g. / i.e. / a.m.,
    /// decimals like 0.3.8 and file names are left alone.
    static func joinSpelledLetters(_ text: String) -> String {
        guard text.range(of: #"[A-Z]"#, options: .regularExpression) != nil else { return text }
        let joined = replace(Self.spelledDots, in: text) { $0.replacingOccurrences(of: ".", with: "") }
        return replace(Self.spelledSpaces, in: joined) { $0.components(separatedBy: .whitespaces).joined() }
    }
    private static func replace(_ regex: NSRegularExpression, in text: String, with transform: (String) -> String) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""; var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += transform(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
    private func convert(_ text: String, processor: UnsafeMutableRawPointer) throws -> String {
        guard let result = wetext_normalize(processor, text) else { throw Failure("数字转换失败。") }
        defer { wetext_free_string(result) }
        return String(cString: result)
    }

}
