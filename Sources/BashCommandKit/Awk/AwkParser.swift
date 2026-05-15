import Foundation

/// Recursive-descent parser for AWK. Mirrors the precedence rules
/// laid out in just-bash's `parser2.ts`: assignment > ternary > pipe-
/// getline > or > and > in > concat > match > comparison > add/sub >
/// mul/div > unary > power > postfix > primary.
///
/// Print/printf use a sibling stack of "print-context" parsers so that
/// `>` and `>>` are redirection at top level but stay as comparison
/// inside `?:`. We mark a print arg's parsing context with the
/// `inPrint` flag throughout.
///
/// The parser state lives in ``AwkParserState`` (see
/// `AwkParserState.swift` / `AwkParserState+Expressions.swift`).
public struct AwkParser {

    public static func parse(_ source: String) throws -> AwkProgram {
        var lexer = AwkLexer(source)
        let toks = try lexer.tokenize()
        var state = AwkParserState(tokens: toks)
        return try state.parseProgram()
    }
}
