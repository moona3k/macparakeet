import XCTest
@testable import MacParakeetCore

final class WhisperLanguageCatalogTests: XCTestCase {

    func testCatalogContainsExpectedLanguageCount() {
        // WhisperKit's `Constants.languages` resolves to 100 unique codes
        // (Cantonese has its own `yue` distinct from Mandarin's `zh`).
        XCTAssertEqual(WhisperLanguageCatalog.all.count, 100)
    }

    func testAllCodesAreUnique() {
        let codes = WhisperLanguageCatalog.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "duplicate language code in catalog")
    }

    func testCatalogIsSortedAlphabeticallyByEnglishName() {
        let names = WhisperLanguageCatalog.all.map(\.englishName)
        XCTAssertEqual(names, names.sorted(), "catalog must be alphabetical")
    }

    func testCanonicalLanguagesArePresent() {
        let codes = Set(WhisperLanguageCatalog.all.map(\.code))
        for code in ["en", "ko", "ja", "zh", "es", "fr", "vi", "hi", "ar", "ru", "yue"] {
            XCTAssertTrue(codes.contains(code), "missing expected language code \(code)")
        }
    }

    func testEveryEntryHasNonEmptyNames() {
        for language in WhisperLanguageCatalog.all {
            XCTAssertFalse(language.code.isEmpty)
            XCTAssertFalse(language.englishName.isEmpty, "missing english name for \(language.code)")
            XCTAssertFalse(language.nativeName.isEmpty, "missing native name for \(language.code)")
        }
    }

    func testLookupByCodeIsCaseInsensitive() {
        XCTAssertEqual(WhisperLanguageCatalog.language(forCode: "KO")?.englishName, "Korean")
        XCTAssertEqual(WhisperLanguageCatalog.language(forCode: "ko")?.englishName, "Korean")
    }

    func testLookupCanonicalizesLegacyRegionTags() {
        XCTAssertEqual(WhisperLanguageCatalog.canonicalCode(for: "KO_kr"), "ko")
        XCTAssertEqual(WhisperLanguageCatalog.language(forCode: "ko-kr")?.englishName, "Korean")
        XCTAssertEqual(WhisperLanguageCatalog.displayLabel(for: "ko-kr"), "Korean")
    }

    func testLookupReturnsNilForUnknownCode() {
        XCTAssertNil(WhisperLanguageCatalog.language(forCode: "xx"))
    }

    func testDisplayLabelHandlesAutoAndUnknownCodes() {
        XCTAssertEqual(WhisperLanguageCatalog.displayLabel(for: "auto"), "Auto-detect")
        XCTAssertEqual(WhisperLanguageCatalog.displayLabel(for: ""), "Auto-detect")
        XCTAssertEqual(WhisperLanguageCatalog.displayLabel(for: "ko"), "Korean")
        XCTAssertEqual(WhisperLanguageCatalog.displayLabel(for: "xx"), "XX")
    }

    func testEmptySearchReturnsFullAlphabeticalList() {
        let results = WhisperLanguageCatalog.search("")
        XCTAssertEqual(results.count, WhisperLanguageCatalog.all.count)
        XCTAssertEqual(results.first?.englishName, WhisperLanguageCatalog.all.first?.englishName)
    }

    func testCodeExactMatchOutranksPrefixMatch() {
        // "es" is the Spanish code AND the prefix of "Estonian".
        // Spanish should come first because code-exact outranks English-prefix.
        let results = WhisperLanguageCatalog.search("es")
        XCTAssertEqual(results.first?.code, "es", "code match should rank above prefix match")
        XCTAssertTrue(results.contains { $0.code == "et" }, "Estonian should still appear")
    }

    func testCodePrefixMatchesMultiCharacterCodes() {
        let results = WhisperLanguageCatalog.search("yu")
        XCTAssertEqual(results.first?.code, "yue")
    }

    func testEnglishPrefixMatchesAreReturned() {
        let results = WhisperLanguageCatalog.search("japan")
        XCTAssertEqual(results.first?.code, "ja")
    }

    func testNativeScriptSearchFindsKorean() {
        // Typing the first jamo of 한국어 should find Korean via native-prefix.
        let results = WhisperLanguageCatalog.search("한")
        XCTAssertEqual(results.first?.code, "ko")
    }

    func testAliasSearchFindsWhisperKitNames() {
        XCTAssertEqual(WhisperLanguageCatalog.search("mandarin").first?.code, "zh")
        XCTAssertEqual(WhisperLanguageCatalog.search("castilian").first?.code, "es")
        XCTAssertEqual(WhisperLanguageCatalog.search("myanmar").first?.code, "my")
    }

    func testNativeScriptSearchIsDiacriticInsensitive() {
        let results = WhisperLanguageCatalog.search("espanol")
        XCTAssertEqual(results.first?.code, "es")
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(WhisperLanguageCatalog.search("ZZZZZZZ").isEmpty)
    }

    func testNormalizationRoundTripIsLossless() {
        // `SpeechEnginePreference.normalizeLanguage` lowercases; ensure every
        // catalog code survives that pass unchanged so we never silently drop
        // a saved selection.
        for language in WhisperLanguageCatalog.all {
            XCTAssertEqual(
                SpeechEnginePreference.normalizeLanguage(language.code),
                language.code,
                "code \(language.code) should round-trip through normalizeLanguage"
            )
        }
    }

    func testAutoCodeNormalizesToNil() {
        XCTAssertNil(SpeechEnginePreference.normalizeLanguage(WhisperLanguageCatalog.autoCode))
    }
}
