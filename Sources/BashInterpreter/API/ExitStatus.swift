import Foundation

/// The exit status of a command or pipeline.
///
/// Mirrors POSIX: `0` means success, any non-zero value means failure.
/// Note that arithmetic commands (`((…))`) use inverted truthiness
/// internally — `(( 1 ))` succeeds (exit 0), `(( 0 ))` fails (exit 1).
public struct ExitStatus: Hashable, Sendable, CustomStringConvertible {
    public let code: Int32

    public init(_ code: Int32) {
        self.code = code
    }

    public var isSuccess: Bool { code == 0 }

    public static let success = ExitStatus(0)
    public static let failure = ExitStatus(1)

    public var description: String { "ExitStatus(\(code))" }
}
