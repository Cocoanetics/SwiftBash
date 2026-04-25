import ArgumentParser
import BashInterpreter
import Foundation

/// `cat [FILE...]` — concatenate file contents to stdout. With no
/// files, copies stdin through unchanged (useful in pipelines).
public struct CatCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Concatenate files (or stdin) to stdout."
    )

    @Argument(help: "Files to read. When empty, reads stdin.")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if files.isEmpty {
            // Stream chunks through as they arrive — binary-safe.
            for await chunk in shell.stdin.bytes {
                shell.stdout(chunk)
            }
            return .success
        }
        var hadError = false
        for path in files {
            if path == "-" {
                for await chunk in shell.stdin.bytes {
                    shell.stdout(chunk)
                }
                continue
            }
            let resolved = shell.resolvePath(path)
            do {
                let source = try await shell.fileSystem.openRead(resolved)
                for await chunk in source.bytes {
                    shell.stdout(chunk)
                }
            } catch FileSystemError.notFound {
                shell.stderr("cat: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("cat: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("cat: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }
}
