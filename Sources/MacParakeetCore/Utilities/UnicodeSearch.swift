import Foundation

public enum UnicodeSearch {
    public static func makeKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public static func contains(_ text: String, normalizedQuery: String) -> Bool {
        makeKey(text).contains(normalizedQuery)
    }
}
