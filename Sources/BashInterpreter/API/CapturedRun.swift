import Foundation

/// The result of ``Shell/runCapturing(_:)`` — exit status plus the
/// full UTF-8-decoded stdout and stderr.
public struct CapturedRun: Sendable, Equatable {
    public let exitStatus: ExitStatus
    public let stdout: String
    public let stderr: String

    public init(exitStatus: ExitStatus, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}
