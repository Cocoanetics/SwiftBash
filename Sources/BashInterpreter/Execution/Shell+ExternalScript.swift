import Foundation

extension Shell {

    /// Try dispatching `argv[0]` as a path-invoked external script.
    ///
    /// Returns the script's exit status when handled (file exists, has
    /// a `#!`-shebang, and an interpreter is registered for it).
    /// Returns `nil` only when the candidate isn't path-shaped, or
    /// when the file exists but has no recognised shebang — both fall
    /// through to the caller's `command not found` branch.
    ///
    /// Behaviour mirrors the kernel's `binfmt_script` plus bash's own
    /// permission-error reporting:
    /// - token has no `/` → `nil` (treat as bare name, look up in PATH)
    /// - non-existent file → `127`, `No such file or directory`
    /// - directory or non-regular file → `126`, `Is a directory`
    /// - regular file without the execute bit set → `126`,
    ///   `Permission denied` (matches `bash ./script` when the file
    ///   isn't `chmod +x`'d)
    /// - filesystem error probing or reading the path (sandbox denial,
    ///   real EACCES, IO error) → `126` with a permission-shaped
    ///   diagnostic, NOT `command not found` — the path exists in the
    ///   user's command line, masking the failure as a lookup miss is
    ///   unhelpful
    /// - file present but no shebang → `nil` (might be a binary; let
    ///   the caller fall through)
    /// - shebang names an interpreter that isn't registered → `nil`
    func dispatchAsExternalScriptIfApplicable(
        argv: [String]
    ) async throws -> ExitStatus? {
        guard !scriptInterpreters.isEmpty else { return nil }
        guard let head = argv.first, looksLikePath(head) else { return nil }

        let resolved = resolvePath(head)
        let meta: FileMetadata?
        do {
            meta = try await fileSystem.metadata(resolved)
        } catch let err as FileSystemError {
            // The path is explicit (`./foo`, `/abs/path`); the user is
            // asking us to run THIS file. Surface the underlying FS
            // error as a 126 rather than masking it as a missing
            // command.
            stderr(
                "\(errorLocationPrefix())\(head): \(err.shellMessage())\n")
            return ExitStatus(126)
        }
        guard let meta else {
            stderr(
                "\(errorLocationPrefix())\(head): No such file or directory\n")
            return ExitStatus(127)
        }
        if meta.kind == .directory {
            stderr(
                "\(errorLocationPrefix())\(head): Is a directory\n")
            return ExitStatus(126)
        }
        // Bash refuses to execute a regular file without an execute
        // bit set (`./script` → `Permission denied` exit 126). Match
        // that here; otherwise we'd happily run a 0644 file the user
        // never marked as runnable. Filesystems whose `metadata`
        // doesn't track POSIX bits report mode 0 — treat those as
        // executable so in-memory test fixtures and the virtual /bin
        // overlay aren't blocked.
        //
        // Windows has no POSIX execute bit, so `RealFileSystem`'s
        // `windowsMetadata` reports `0o644` for every regular file —
        // applying the check there would block every script. Skip
        // the gate on Windows; if a script runs at all, the file
        // already exists and the OS handles the rest.
        #if !os(Windows)
        if meta.mode != 0, (meta.mode & 0o111) == 0 {
            stderr(
                "\(errorLocationPrefix())\(head): Permission denied\n")
            return ExitStatus(126)
        }
        #endif
        let data: Data
        do {
            data = try await fileSystem.readData(resolved)
        } catch let err as FileSystemError {
            // Same reasoning as the metadata branch above — surface
            // a real read failure on an explicit path rather than
            // hiding it as `command not found`.
            stderr(
                "\(errorLocationPrefix())\(head): \(err.shellMessage())\n")
            return ExitStatus(126)
        }
        let raw = String(decoding: data, as: UTF8.self)
        let (rewritten, shebangLine) = stripShebang(raw)

        // Run inside a fresh subshell — interpreters mutate
        // `Shell.current.positionalParameters` and `scriptName` while
        // executing, and we don't want those to leak into the parent.
        // `Shell.copy()` is the single source of truth for what
        // propagates; this stays consistent with `bash FILE` semantics.
        if let shebangLine,
           let parsed = parseShebangLine(shebangLine),
           let interpreter = scriptInterpreters[parsed.interpreter]
        {
            let context = ScriptInterpreterContext(
                scriptPath: resolved,
                source: rewritten,
                shebang: shebangLine,
                argv: [resolved] + Array(argv.dropFirst()))
            let sub = copy()
            sub.scriptName = resolved
            sub.positionalParameters = Array(argv.dropFirst())
            return try await sub.withCurrent {
                try await interpreter.run(context)
            }
        }

        // No shebang at all → real bash falls back to running the
        // file through `/bin/sh` after a failed `execve(ENOEXEC)`.
        // Since we ARE the shell, just interpret the contents
        // ourselves. The probe rejects obvious binaries (NUL bytes
        // in the first kilobyte) so we don't try to parse an ELF /
        // Mach-O / `.pyc` as bash source.
        //
        // When the file DID have a shebang but it pointed at an
        // interpreter we don't have (e.g. `#!/usr/bin/env python3`
        // on a host with no python registration), keep the previous
        // behaviour and return `nil`. Falling back to bash there
        // would mangle the user's actual interpreter intent.
        if shebangLine == nil, looksLikeTextScript(data) {
            let sub = copy()
            sub.scriptName = resolved
            sub.positionalParameters = Array(argv.dropFirst())
            return try await sub.withCurrent {
                try await sub.run(raw)
            }
        }

        return nil
    }

    /// Heuristic for "this file is a script the shell should
    /// interpret, not a binary it should refuse". Real bash uses
    /// the kernel's `ENOEXEC` from a failed `execve(2)`; we
    /// approximate by scanning the first 1 KiB for NUL bytes,
    /// which would never appear in well-formed bash source but
    /// almost always show up in ELF/Mach-O/PE headers and in
    /// most binary blobs (PNG, gzip, etc.).
    private func looksLikeTextScript(_ data: Data) -> Bool {
        return !data.prefix(1024).contains(0)
    }

    /// A token "looks like a path" if it contains a `/` (relative or
    /// absolute). Bare names like `swift-script` are looked up in the
    /// command registry only — they're not paths to script files.
    ///
    /// On Windows, `\` is also accepted because `NSTemporaryDirectory()`
    /// and friends return paths like `C:\Users\…\run.foo`. Without
    /// this, every Windows-shaped temp path falls through to
    /// `command not found`.
    private func looksLikePath(_ token: String) -> Bool {
        #if os(Windows)
        return token.contains("/") || token.contains("\\")
        #else
        return token.contains("/")
        #endif
    }
}
