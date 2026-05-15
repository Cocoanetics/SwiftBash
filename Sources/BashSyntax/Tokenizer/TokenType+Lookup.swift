import Foundation

extension TokenType {
    /// Words that become reserved tokens when they appear at command position.
    static let reservedWordTable: [String: TokenType] = [
        "if": .ifKw,
        "then": .thenKw,
        "else": .elseKw,
        "elif": .elifKw,
        "fi": .fiKw,
        "case": .caseKw,
        "esac": .esacKw,
        "for": .forKw,
        "select": .selectKw,
        "while": .whileKw,
        "until": .untilKw,
        "do": .doKw,
        "done": .doneKw,
        "in": .inKw,
        "function": .functionKw,
        "time": .timeKw,
        "{": .leftCurly,
        "}": .rightCurly,
        "!": .bang,
        "[[": .condStart,
        "]]": .condEnd,
        "coproc": .coprocKw
    ]

    /// Token types that can precede a reserved word or assignment.
    static let commandStartTypes: Set<TokenType> = [
        .andAnd, .bang, .barAnd, .doKw, .doneKw, .elifKw, .elseKw, .esacKw,
        .fiKw, .ifKw, .orOr, .semiSemi, .semiAnd, .semiSemiAnd, .thenKw,
        .timeKw, .timeOpt, .timeIgn, .coprocKw, .untilKw, .whileKw,
        .newline, .semicolon, .leftParen, .rightParen, .bar, .ampersand,
        .leftCurly, .rightCurly, .forKw, .caseKw, .selectKw, .inKw,
        .assignmentWord
    ]
}
