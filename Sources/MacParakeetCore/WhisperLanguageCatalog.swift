import Foundation

public struct WhisperLanguage: Hashable, Sendable, Identifiable {
    public let code: String
    public let englishName: String
    public let nativeName: String

    public init(code: String, englishName: String, nativeName: String) {
        self.code = code
        self.englishName = englishName
        self.nativeName = nativeName
    }

    public var id: String { code }
}

public enum WhisperLanguageCatalog {
    public static let autoCode = "auto"

    public static let auto = WhisperLanguage(
        code: autoCode,
        englishName: "Auto-detect",
        nativeName: ""
    )

    public static let all: [WhisperLanguage] = [
        WhisperLanguage(code: "af", englishName: "Afrikaans", nativeName: "Afrikaans"),
        WhisperLanguage(code: "sq", englishName: "Albanian", nativeName: "Shqip"),
        WhisperLanguage(code: "am", englishName: "Amharic", nativeName: "አማርኛ"),
        WhisperLanguage(code: "ar", englishName: "Arabic", nativeName: "العربية"),
        WhisperLanguage(code: "hy", englishName: "Armenian", nativeName: "Հայերեն"),
        WhisperLanguage(code: "as", englishName: "Assamese", nativeName: "অসমীয়া"),
        WhisperLanguage(code: "az", englishName: "Azerbaijani", nativeName: "Azərbaycan"),
        WhisperLanguage(code: "ba", englishName: "Bashkir", nativeName: "Башҡортса"),
        WhisperLanguage(code: "eu", englishName: "Basque", nativeName: "Euskara"),
        WhisperLanguage(code: "be", englishName: "Belarusian", nativeName: "Беларуская"),
        WhisperLanguage(code: "bn", englishName: "Bengali", nativeName: "বাংলা"),
        WhisperLanguage(code: "bs", englishName: "Bosnian", nativeName: "Bosanski"),
        WhisperLanguage(code: "br", englishName: "Breton", nativeName: "Brezhoneg"),
        WhisperLanguage(code: "bg", englishName: "Bulgarian", nativeName: "Български"),
        WhisperLanguage(code: "my", englishName: "Burmese", nativeName: "မြန်မာ"),
        WhisperLanguage(code: "yue", englishName: "Cantonese", nativeName: "粵語"),
        WhisperLanguage(code: "ca", englishName: "Catalan", nativeName: "Català"),
        WhisperLanguage(code: "zh", englishName: "Chinese", nativeName: "中文"),
        WhisperLanguage(code: "hr", englishName: "Croatian", nativeName: "Hrvatski"),
        WhisperLanguage(code: "cs", englishName: "Czech", nativeName: "Čeština"),
        WhisperLanguage(code: "da", englishName: "Danish", nativeName: "Dansk"),
        WhisperLanguage(code: "nl", englishName: "Dutch", nativeName: "Nederlands"),
        WhisperLanguage(code: "en", englishName: "English", nativeName: "English"),
        WhisperLanguage(code: "et", englishName: "Estonian", nativeName: "Eesti"),
        WhisperLanguage(code: "fo", englishName: "Faroese", nativeName: "Føroyskt"),
        WhisperLanguage(code: "fi", englishName: "Finnish", nativeName: "Suomi"),
        WhisperLanguage(code: "fr", englishName: "French", nativeName: "Français"),
        WhisperLanguage(code: "gl", englishName: "Galician", nativeName: "Galego"),
        WhisperLanguage(code: "ka", englishName: "Georgian", nativeName: "ქართული"),
        WhisperLanguage(code: "de", englishName: "German", nativeName: "Deutsch"),
        WhisperLanguage(code: "el", englishName: "Greek", nativeName: "Ελληνικά"),
        WhisperLanguage(code: "gu", englishName: "Gujarati", nativeName: "ગુજરાતી"),
        WhisperLanguage(code: "ht", englishName: "Haitian Creole", nativeName: "Kreyòl Ayisyen"),
        WhisperLanguage(code: "ha", englishName: "Hausa", nativeName: "Hausa"),
        WhisperLanguage(code: "haw", englishName: "Hawaiian", nativeName: "ʻŌlelo Hawaiʻi"),
        WhisperLanguage(code: "he", englishName: "Hebrew", nativeName: "עברית"),
        WhisperLanguage(code: "hi", englishName: "Hindi", nativeName: "हिन्दी"),
        WhisperLanguage(code: "hu", englishName: "Hungarian", nativeName: "Magyar"),
        WhisperLanguage(code: "is", englishName: "Icelandic", nativeName: "Íslenska"),
        WhisperLanguage(code: "id", englishName: "Indonesian", nativeName: "Bahasa Indonesia"),
        WhisperLanguage(code: "it", englishName: "Italian", nativeName: "Italiano"),
        WhisperLanguage(code: "ja", englishName: "Japanese", nativeName: "日本語"),
        WhisperLanguage(code: "jw", englishName: "Javanese", nativeName: "Basa Jawa"),
        WhisperLanguage(code: "kn", englishName: "Kannada", nativeName: "ಕನ್ನಡ"),
        WhisperLanguage(code: "kk", englishName: "Kazakh", nativeName: "Қазақша"),
        WhisperLanguage(code: "km", englishName: "Khmer", nativeName: "ខ្មែរ"),
        WhisperLanguage(code: "ko", englishName: "Korean", nativeName: "한국어"),
        WhisperLanguage(code: "lo", englishName: "Lao", nativeName: "ລາວ"),
        WhisperLanguage(code: "la", englishName: "Latin", nativeName: "Latina"),
        WhisperLanguage(code: "lv", englishName: "Latvian", nativeName: "Latviešu"),
        WhisperLanguage(code: "ln", englishName: "Lingala", nativeName: "Lingála"),
        WhisperLanguage(code: "lt", englishName: "Lithuanian", nativeName: "Lietuvių"),
        WhisperLanguage(code: "lb", englishName: "Luxembourgish", nativeName: "Lëtzebuergesch"),
        WhisperLanguage(code: "mk", englishName: "Macedonian", nativeName: "Македонски"),
        WhisperLanguage(code: "mg", englishName: "Malagasy", nativeName: "Malagasy"),
        WhisperLanguage(code: "ms", englishName: "Malay", nativeName: "Bahasa Melayu"),
        WhisperLanguage(code: "ml", englishName: "Malayalam", nativeName: "മലയാളം"),
        WhisperLanguage(code: "mt", englishName: "Maltese", nativeName: "Malti"),
        WhisperLanguage(code: "mi", englishName: "Maori", nativeName: "Māori"),
        WhisperLanguage(code: "mr", englishName: "Marathi", nativeName: "मराठी"),
        WhisperLanguage(code: "mn", englishName: "Mongolian", nativeName: "Монгол"),
        WhisperLanguage(code: "ne", englishName: "Nepali", nativeName: "नेपाली"),
        WhisperLanguage(code: "no", englishName: "Norwegian", nativeName: "Norsk"),
        WhisperLanguage(code: "nn", englishName: "Norwegian Nynorsk", nativeName: "Nynorsk"),
        WhisperLanguage(code: "oc", englishName: "Occitan", nativeName: "Occitan"),
        WhisperLanguage(code: "ps", englishName: "Pashto", nativeName: "پښتو"),
        WhisperLanguage(code: "fa", englishName: "Persian", nativeName: "فارسی"),
        WhisperLanguage(code: "pl", englishName: "Polish", nativeName: "Polski"),
        WhisperLanguage(code: "pt", englishName: "Portuguese", nativeName: "Português"),
        WhisperLanguage(code: "pa", englishName: "Punjabi", nativeName: "ਪੰਜਾਬੀ"),
        WhisperLanguage(code: "ro", englishName: "Romanian", nativeName: "Română"),
        WhisperLanguage(code: "ru", englishName: "Russian", nativeName: "Русский"),
        WhisperLanguage(code: "sa", englishName: "Sanskrit", nativeName: "संस्कृतम्"),
        WhisperLanguage(code: "sr", englishName: "Serbian", nativeName: "Српски"),
        WhisperLanguage(code: "sn", englishName: "Shona", nativeName: "ChiShona"),
        WhisperLanguage(code: "sd", englishName: "Sindhi", nativeName: "سنڌي"),
        WhisperLanguage(code: "si", englishName: "Sinhala", nativeName: "සිංහල"),
        WhisperLanguage(code: "sk", englishName: "Slovak", nativeName: "Slovenčina"),
        WhisperLanguage(code: "sl", englishName: "Slovenian", nativeName: "Slovenščina"),
        WhisperLanguage(code: "so", englishName: "Somali", nativeName: "Soomaali"),
        WhisperLanguage(code: "es", englishName: "Spanish", nativeName: "Español"),
        WhisperLanguage(code: "su", englishName: "Sundanese", nativeName: "Basa Sunda"),
        WhisperLanguage(code: "sw", englishName: "Swahili", nativeName: "Kiswahili"),
        WhisperLanguage(code: "sv", englishName: "Swedish", nativeName: "Svenska"),
        WhisperLanguage(code: "tl", englishName: "Tagalog", nativeName: "Tagalog"),
        WhisperLanguage(code: "tg", englishName: "Tajik", nativeName: "Тоҷикӣ"),
        WhisperLanguage(code: "ta", englishName: "Tamil", nativeName: "தமிழ்"),
        WhisperLanguage(code: "tt", englishName: "Tatar", nativeName: "Татар"),
        WhisperLanguage(code: "te", englishName: "Telugu", nativeName: "తెలుగు"),
        WhisperLanguage(code: "th", englishName: "Thai", nativeName: "ภาษาไทย"),
        WhisperLanguage(code: "bo", englishName: "Tibetan", nativeName: "བོད་སྐད་"),
        WhisperLanguage(code: "tr", englishName: "Turkish", nativeName: "Türkçe"),
        WhisperLanguage(code: "tk", englishName: "Turkmen", nativeName: "Türkmen"),
        WhisperLanguage(code: "uk", englishName: "Ukrainian", nativeName: "Українська"),
        WhisperLanguage(code: "ur", englishName: "Urdu", nativeName: "اردو"),
        WhisperLanguage(code: "uz", englishName: "Uzbek", nativeName: "Oʻzbekcha"),
        WhisperLanguage(code: "vi", englishName: "Vietnamese", nativeName: "Tiếng Việt"),
        WhisperLanguage(code: "cy", englishName: "Welsh", nativeName: "Cymraeg"),
        WhisperLanguage(code: "yi", englishName: "Yiddish", nativeName: "ייִדיש"),
        WhisperLanguage(code: "yo", englishName: "Yoruba", nativeName: "Yorùbá"),
    ]

    private static let byCode: [String: WhisperLanguage] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0) }
    )

    /// WhisperKit accepts a handful of alternate names for the same language
    /// token. Keep those searchable so the UI does not hide supported inputs
    /// behind one preferred English label.
    private static let aliasesByCode: [String: [String]] = [
        "ca": ["valencian"],
        "es": ["castilian"],
        "ht": ["haitian"],
        "lb": ["letzeburgesch"],
        "my": ["myanmar"],
        "nl": ["flemish"],
        "pa": ["panjabi"],
        "ps": ["pushto"],
        "ro": ["moldavian", "moldovan"],
        "si": ["sinhalese"],
        "zh": ["mandarin"],
    ]

    public static func canonicalCode(for rawCode: String?) -> String? {
        guard let rawCode else { return nil }
        let normalized = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        guard normalized != autoCode, normalized != "auto-detect" else { return nil }

        if byCode[normalized] != nil {
            return normalized
        }

        if let primarySubtag = normalized.split(separator: "-", maxSplits: 1).first.map(String.init),
           byCode[primarySubtag] != nil {
            return primarySubtag
        }

        return normalized
    }

    public static func language(forCode code: String) -> WhisperLanguage? {
        guard let canonical = canonicalCode(for: code) else { return nil }
        return byCode[canonical]
    }

    /// User-facing label for the picker button. Falls back to upper-cased code
    /// for unknown values so a stale UserDefaults entry still renders something.
    public static func displayLabel(for code: String) -> String {
        if code.isEmpty || code.lowercased() == autoCode {
            return auto.englishName
        }
        return language(forCode: code)?.englishName ?? code.uppercased()
    }

    /// Returns languages ranked by relevance to `query`.
    /// Empty query returns the alphabetical list as-is (no Auto row).
    /// Ranking: code-exact → code-prefix → English-prefix → native-prefix
    /// → alias-prefix → English-substring → native-substring → alias-substring.
    /// Within a rank, alphabetical by English name.
    public static func search(_ query: String) -> [WhisperLanguage] {
        let trimmed = normalizedSearchTerm(query)
        guard !trimmed.isEmpty else { return all }

        var results: [(rank: Int, language: WhisperLanguage)] = []
        for language in all {
            let english = normalizedSearchTerm(language.englishName)
            let native = normalizedSearchTerm(language.nativeName)
            let code = normalizedSearchTerm(language.code)
            let aliases = aliasesByCode[language.code, default: []].map(normalizedSearchTerm)
            let rank: Int
            if code == trimmed {
                rank = 0
            } else if code.hasPrefix(trimmed) {
                rank = 1
            } else if english.hasPrefix(trimmed) {
                rank = 2
            } else if !native.isEmpty && native.hasPrefix(trimmed) {
                rank = 3
            } else if aliases.contains(where: { $0.hasPrefix(trimmed) }) {
                rank = 4
            } else if english.contains(trimmed) {
                rank = 5
            } else if native.contains(trimmed) {
                rank = 6
            } else if aliases.contains(where: { $0.contains(trimmed) }) {
                rank = 7
            } else {
                continue
            }
            results.append((rank, language))
        }

        return results
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.language.englishName < rhs.language.englishName
            }
            .map(\.language)
    }

    private static func normalizedSearchTerm(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
