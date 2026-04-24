import Foundation

/// Shell-character classification tables used by the tokenizer.
enum SyntaxClass {
    static let dquoteChars: Set<Character> = ["\\", "`", "$", "\"", "\n"]
    static let metaChars:   Set<Character> = ["(", ")", "<", ">", ";", "&", "|"]
    static let quoteChars:  Set<Character> = ["\"", "`", "'"]
    static let expChars:    Set<Character> = ["$", "<", ">"]
    static let breakChars:  Set<Character> = ["(", ")", "<", ">", ";", "&", "|",
                                              " ", "\t", "\n"]

    static func isBlank(_ c: Character)     -> Bool { c == " " || c == "\t" }
    static func isMeta(_ c: Character)      -> Bool { metaChars.contains(c) }
    static func isQuoteChar(_ c: Character) -> Bool { quoteChars.contains(c) }
    static func isExp(_ c: Character)       -> Bool { expChars.contains(c) }
    static func isBreak(_ c: Character)     -> Bool { breakChars.contains(c) }
}
