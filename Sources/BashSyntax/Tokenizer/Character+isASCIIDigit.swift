import Foundation

extension Character {
    var isASCIIDigit: Bool {
        guard let a = asciiValue else { return false }
        return a >= 0x30 && a <= 0x39
    }
}
