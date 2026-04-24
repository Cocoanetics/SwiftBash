import Foundation

/// A single token emitted by the tokenizer.
public struct Token: Hashable, Sendable {
    public var type: TokenType
    public var value: String
    public var range: Range<Int>
    public var flags: TokenFlags

    public init(type: TokenType, value: String,
                range: Range<Int>, flags: TokenFlags = []) {
        self.type = type
        self.value = value
        self.range = range
        self.flags = flags
    }
}
