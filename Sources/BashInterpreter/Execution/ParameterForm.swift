import Foundation

/// A parsed form of the body between `${` and `}` in a parameter
/// expansion. Produced by ``ParameterFormParser/parse(_:)`` and
/// evaluated against a ``Shell``'s environment.
///
/// Examples and their forms:
/// ```
/// ${name}            → .plain("name")
/// ${#name}           → .length("name")
/// ${name-x}          → .defaultValue("name", checkEmpty: false,  value: "x")
/// ${name:-x}         → .defaultValue("name", checkEmpty: true,   value: "x")
/// ${name=x}          → .assignDefault("name", checkEmpty: false, value: "x")
/// ${name:=x}         → .assignDefault("name", checkEmpty: true,  value: "x")
/// ${name?msg}        → .errorIfUnset("name", checkEmpty: false,  message: "msg")
/// ${name:?msg}       → .errorIfUnset("name", checkEmpty: true,   message: "msg")
/// ${name+x}          → .alternative("name", checkEmpty: false,   value: "x")
/// ${name:+x}         → .alternative("name", checkEmpty: true,    value: "x")
/// ${name#pat}        → .removePrefix("name", pat, longest: false)
/// ${name##pat}       → .removePrefix("name", pat, longest: true)
/// ${name%pat}        → .removeSuffix("name", pat, longest: false)
/// ${name%%pat}       → .removeSuffix("name", pat, longest: true)
/// ${name/pat/rep}    → .replace("name", pat, rep, all: false, anchor: .any)
/// ${name//pat/rep}   → .replace("name", pat, rep, all: true,  anchor: .any)
/// ${name/#pat/rep}   → .replace("name", pat, rep, all: false, anchor: .start)
/// ${name/%pat/rep}   → .replace("name", pat, rep, all: false, anchor: .end)
/// ${name:offset}     → .substring("name", offset, length: nil)
/// ${name:off:len}    → .substring("name", off, length: len)
/// ```
enum ParameterForm: Equatable {
    case plain(String)
    case length(String)
    case defaultValue(name: String, checkEmpty: Bool, value: String)
    case assignDefault(name: String, checkEmpty: Bool, value: String)
    case errorIfUnset(name: String, checkEmpty: Bool, message: String)
    case alternative(name: String, checkEmpty: Bool, value: String)
    case removePrefix(name: String, pattern: String, longest: Bool)
    case removeSuffix(name: String, pattern: String, longest: Bool)
    case replace(name: String,
                 pattern: String,
                 replacement: String,
                 all: Bool,
                 anchor: ReplaceAnchor)
    case substring(name: String, offset: Int, length: Int?)
    /// `${!arr[@]}` / `${!arr[*]}` — list of indices of the array
    /// (sparse-aware: only set slots are reported, in sorted order).
    case indices(String)
    /// `${!name}` — indirect expansion: `name` is a variable whose
    /// value is the *real* parameter name to look up.
    case indirect(String)
    /// `${name^}` `${name^^}` `${name,}` `${name,,}` — case conversion.
    /// `all=true` for `^^` / `,,`; `pattern` empty means "match every
    /// char" (matches bash short-form behaviour).
    case caseConvert(name: String,
                     toUpper: Bool,
                     all: Bool,
                     pattern: String)

    enum ReplaceAnchor: Equatable {
        case any   // matches at any position
        case start // anchored to the beginning of the value
        case end   // anchored to the end of the value
    }
}
