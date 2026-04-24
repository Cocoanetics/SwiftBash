import Foundation

/// Thrown by `break` / `continue` built-ins and caught by loop handlers
/// (`executeWhileLike`, `executeFor`). `remainingLevels` counts how many
/// enclosing loops still need to be unwound; each loop decrements by 1
/// before acting or re-throwing.
struct LoopControlSignal: Error {
    enum Kind { case breakLoop, continueLoop }
    let kind: Kind
    var remainingLevels: Int
}
