import Foundation

/// A user-facing error for the CLI. Conforms to `LocalizedError` so that
/// ArgumentParser prints the `message` as the error output instead of a
/// type-name fallback.
struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
