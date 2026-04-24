import Foundation

/// Flags attached to word tokens to guide later word expansion.
public struct TokenFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let hasDollar     = TokenFlags(rawValue: 1 << 0)
    public static let quoted        = TokenFlags(rawValue: 1 << 1)
    public static let assignment    = TokenFlags(rawValue: 1 << 2)
    public static let noSplit       = TokenFlags(rawValue: 1 << 3)
    public static let noGlob        = TokenFlags(rawValue: 1 << 4)
    public static let compAssign    = TokenFlags(rawValue: 1 << 5)
    public static let doubleQuoted  = TokenFlags(rawValue: 1 << 6)
}
