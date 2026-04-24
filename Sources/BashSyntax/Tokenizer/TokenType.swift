import Foundation

/// Enumerates every token kind the bash tokenizer can emit.
///
/// The specific operator values are important: the parser dispatches on them.
public enum TokenType: Hashable, Sendable {
    // Words
    case word
    case assignmentWord
    case redirectWord
    case number

    // Reserved words
    case bang            // !
    case ifKw
    case thenKw
    case elseKw
    case elifKw
    case fiKw
    case caseKw
    case esacKw
    case forKw
    case selectKw
    case whileKw
    case untilKw
    case doKw
    case doneKw
    case functionKw
    case coprocKw
    case inKw
    case timeKw
    case timeOpt          // -p
    case timeIgn          // --
    case leftCurly        // {
    case rightCurly       // }
    case condStart        // [[
    case condEnd          // ]]

    // Operators
    case andAnd           // &&
    case orOr             // ||
    case bar              // |
    case barAnd           // |&
    case ampersand        // &
    case andGreater       // &>
    case andGreaterGreater // &>>
    case semicolon        // ;
    case semiSemi         // ;;
    case semiAnd          // ;&
    case semiSemiAnd      // ;;&
    case lessLess         // <<
    case lessLessMinus    // <<-
    case lessLessLess     // <<<
    case lessAnd          // <&
    case greaterAnd       // >&
    case lessGreater      // <>
    case greaterBar       // >|
    case greaterGreater   // >>
    case less             // <
    case greater          // >
    case leftParen        // (
    case rightParen       // )
    case newline
    case dash             // - (only in redirect contexts)

    case eof
}
