import Foundation

/// Shell-character classification tables used by the tokenizer.
enum SyntaxClass {
    static let dquoteChars: Set<Character> = ["\\", "`", "$", "\"", "\n"]
    static let metaChars: Set<Character> = ["(", ")", "<", ">", ";", "&", "|"]
    static let quoteChars: Set<Character> = ["\"", "`", "'"]
    static let expChars: Set<Character> = ["$", "<", ">"]
    static let breakChars: Set<Character> = ["(", ")", "<", ">", ";", "&", "|",
                                              " ", "\t", "\n"]

    static func isBlank(_ char: Character) -> Bool { char == " " || char == "\t" }
    static func isMeta(_ char: Character) -> Bool { metaChars.contains(char) }
    static func isQuoteChar(_ char: Character) -> Bool { quoteChars.contains(char) }
    static func isExp(_ char: Character) -> Bool { expChars.contains(char) }
    static func isBreak(_ char: Character) -> Bool { breakChars.contains(char) }
}
