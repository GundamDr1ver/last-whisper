import XCTest
@testable import VoiceInput

final class NumberNormalizationTests: XCTestCase {
    func testIntegersDecimalsPercentagesAndVersions() async throws {
        let normalizer = NumberNormalization()
        for (source, expected) in [
            ("零", "0"), ("一", "1"), ("两", "2"), ("八", "8"), ("八。", "8。"), ("一百二十三", "123"),
            ("零点五", "0.5"), ("零点零五", "0.05"), ("零点零零五", "0.005"), ("零点五零", "0.50"), ("三点一四", "3.14"), ("负零点五", "-0.5"),
            ("百分之三十", "30%"), ("零点三点八", "0.3.8"),
            ("版本零点三点八", "版本0.3.8"), ("版本零点零五点零八", "版本0.05.08"), ("0点三点八", "0.3.8"), ("0点3点8", "0.3.8"), ("负0.5", "-0.5"),
            ("价格是八元，内存三十二GB。", "价格是8元，内存32GB。"),
            ("二零二六年十月三十一日", "2026年10月31日"),
            ("需要两千三百个，价格零点五元。", "需要2300个，价格0.5元。")
        ] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, expected, source)
        }
    }
    func testCommonWordsAndAmbiguousRangesStayUnchanged() async throws {
        let normalizer = NumberNormalization()
        for source in [
            "一起去吃饭，我有一点意见，别三心二意。",
            "我一点都不想动，喝一点水，慢一点。",
            "一方面要快，另一方面要准。",
            "这个不一定，一定要保留，一般都这样。",
            "一旦开始就不要停止，万一失败怎么办。",
            "这个是一定的，这是一般情况。",
            "一点点，一点一滴，十有八九。",
            "我们星期一见，一个人去。", "三五百", "十五六"
        ] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, source)
        }
    }
    func testMixedLanguageWhitespaceLineBreaksAndLiteralsArePreserved() async throws {
        let normalizer = NumberNormalization()
        for (source, expected) in [
            ("Hello, how are you? 今天 review PR。", "Hello, how are you? 今天 review PR。"),
            ("API v0.3.8 costs $0.50, 50% off.", "API v0.3.8 costs $0.50, 50% off."),
            ("\t八\n零点五\r\n版本零点三点八  ", "\t8\n0.5\r\n版本0.3.8  "),
            ("🐱 八，👨‍👩‍👧‍👦 零点五，八", "🐱 8，👨‍👩‍👧‍👦 0.5，8"),
            ("访问 https://example.com/八，输入 `八 + 零点五`。", "访问 https://example.com/八，输入 `八 + 零点五`。"),
            ("", ""), (" \n\t", " \n\t")
        ] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, expected, source)
            let repeated = try await normalizer.normalize(result)
            XCTAssertEqual(repeated, expected)
        }
    }
    func testSpokenDigitRunsBecomeArabicInsideHanAndLatinText() async throws {
        let normalizer = NumberNormalization()
        for (source, expected) in [
            ("出九零六零xt这种中端卡", "出9060xt这种中端卡"),
            ("四零九零Ti显卡", "4090Ti显卡"),
            ("三零六零和六八零零", "3060和6800"),
            ("二零二四年", "2024年"),
            ("给九零六零加内存", "给9060加内存"),
            ("AMD比英伟达更先说出'all in ai', 出九零六零xt这种中端卡选择不竞争",
             "AMD比英伟达更先说出'all in ai', 出9060xt这种中端卡选择不竞争")
        ] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, expected, source)
            let repeated = try await normalizer.normalize(result)
            XCTAssertEqual(repeated, expected, source)
        }
    }
    func testIdiomsThatLookLikeDigitRunsStaySpoken() async throws {
        let normalizer = NumberNormalization()
        for source in ["七零八落", "五零四散", "零零星星", "三三两两", "一一对应", "七零八碎"] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, source)
        }
    }
    func testDecimalsKeepTrailingZerosWhenSpokenAsDigits() async throws {
        let normalizer = NumberNormalization()
        for (source, expected) in [
            ("九点零六零", "9.060"), ("负九点零六", "-9.06"), ("零点零六", "0.06"), ("出九点零六零xt", "出9.060xt")
        ] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, expected, source)
        }
    }
    func testSpelledLettersJoinWithoutDotsOrSpaces() async throws {
        let normalizer = NumberNormalization()
        for (source, expected) in [
            ("A.M.D", "AMD"), ("出A.M.D和U.S.A.", "出AMD和USA"), ("A M D", "AMD"),
            ("A.M.D比英伟达更先说出'all in ai'", "AMD比英伟达更先说出'all in ai'"),
            ("A.I. 技术", "AI 技术"), ("版本0.3.8", "版本0.3.8"),
            ("e.g. 和 i.e. 和 a.m.", "e.g. 和 i.e. 和 a.m.")
        ] {
            let result = try await normalizer.normalize(source)
            XCTAssertEqual(result, expected, source)
            let repeated = try await normalizer.normalize(result)
            XCTAssertEqual(repeated, expected, source)
        }
    }
    func testCancellationIsNotReportedAsANormalizedResult() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NumberNormalization().normalize("零点五")
        }
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testWarmConversionTiming() async throws {
        let normalizer = NumberNormalization()
        try await normalizer.prepare()
        let start = Date()
        for _ in 0..<100 {
            let result = try await normalizer.normalize("版本零点三点八，需要三十二GB内存，价格是零点五元。")
            XCTAssertEqual(result, "版本0.3.8，需要32GB内存，价格是0.5元。")
        }
        print("WeText: average \(Date().timeIntervalSince(start) * 10) ms per conversion")
    }
}
