import Foundation

extension Shell {

    /// Open `path` for reading. Intercepts the four `/dev/` standard
    /// entries before falling through to ``fileSystem``:
    ///
    /// - `/dev/null` → empty `InputSource`
    /// - `/dev/stdin` → the shell's `stdin`
    /// - `/dev/stdout`, `/dev/stderr` → empty `InputSource` (POSIX
    ///   permits "reading" them, but they yield nothing here)
    ///
    /// Anything else routes to `fileSystem.openRead(_:)`. Callers should
    /// prefer this over reaching into `fileSystem` directly so scripts
    /// referencing `/dev/...` work uniformly across `RealFileSystem`,
    /// `InMemoryFileSystem`, and any sandboxed embedder.
    public func openInputPath(_ path: String) async throws -> InputSource {
        let resolved = resolvePath(path)
        switch resolved {
        case "/dev/null":
            return .empty
        case "/dev/stdin":
            return stdin
        case "/dev/stdout", "/dev/stderr":
            return .empty
        default:
            return try await fileSystem.openRead(resolved)
        }
    }

    /// Open `path` for writing. Intercepts the four `/dev/` standard
    /// entries before falling through to ``fileSystem``:
    ///
    /// - `/dev/null` → ``OutputSink/discard``
    /// - `/dev/stdout` → ``OutputSink/proxy(to:)`` over `self.stdout`
    /// - `/dev/stderr` → ``OutputSink/proxy(to:)`` over `self.stderr`
    /// - `/dev/stdin` → ``FileSystemError/permissionDenied(_:)``
    ///
    /// The proxy variants stay open after the redirection's `finish()`
    /// fires, so the shell's real fd1/fd2 keep working for everything
    /// after the redirection unwinds.
    public func openOutputPath(_ path: String,
                               append: Bool = false) async throws -> OutputSink
    {
        let resolved = resolvePath(path)
        switch resolved {
        case "/dev/null":
            return .discard
        case "/dev/stdout":
            return .proxy(to: stdout)
        case "/dev/stderr":
            return .proxy(to: stderr)
        case "/dev/stdin":
            throw FileSystemError.permissionDenied(path)
        default:
            return try await fileSystem.openWrite(resolved, append: append)
        }
    }

    /// Read the full contents of `path`. Convenience over
    /// ``openInputPath(_:)`` for callers that want a `Data` blob — and
    /// faster for the magic paths since it skips an `AsyncStream` round
    /// trip.
    public func readDataAtPath(_ path: String) async throws -> Data {
        let resolved = resolvePath(path)
        switch resolved {
        case "/dev/null":
            return Data()
        case "/dev/stdin":
            return await stdin.readAllData()
        case "/dev/stdout", "/dev/stderr":
            return Data()
        default:
            return try await fileSystem.readData(resolved)
        }
    }

    /// Stat-like inspection that mirrors `FileSystem.metadata(_:)` but
    /// synthesises a "regular file"-shaped `FileMetadata` for the magic
    /// `/dev/...` paths. Commands that pre-check existence (e.g. `grep`
    /// walking its file arguments) need this so the magic paths aren't
    /// rejected on a sandboxed `FileSystem`.
    public func metadataAtPath(_ path: String) async throws -> FileMetadata? {
        let resolved = resolvePath(path)
        switch resolved {
        case "/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr":
            return FileMetadata(
                kind: .other,
                size: 0,
                modifiedAt: Date(timeIntervalSince1970: 0))
        default:
            return try await fileSystem.metadata(resolved)
        }
    }

    /// Write `data` to `path`. Mirror of ``readDataAtPath(_:)`` for
    /// writers that already have the full payload in memory.
    public func writeData(_ data: Data,
                          toPath path: String,
                          append: Bool = false) async throws
    {
        let resolved = resolvePath(path)
        switch resolved {
        case "/dev/null":
            return
        case "/dev/stdout":
            stdout.write(data)
        case "/dev/stderr":
            stderr.write(data)
        case "/dev/stdin":
            throw FileSystemError.permissionDenied(path)
        default:
            try await fileSystem.writeData(
                data, to: resolved, append: append)
        }
    }
}
