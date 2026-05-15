import Foundation

extension Shell {

    /// Register `interpreter` under its `name`, replacing any existing
    /// entry with the same name. Used by the dispatcher to honor
    /// `#!`-shebangs on path-invoked scripts (`./script.swift`,
    /// `/abs/path/script.py`).
    public func registerScriptInterpreter(_ interpreter: ScriptInterpreter) {
        scriptInterpreters[interpreter.name] = interpreter
    }

    /// Closure-form registration — equivalent to wrapping `body` in a
    /// ``ClosureScriptInterpreter``.
    public func registerScriptInterpreter(
        name: String,
        _ body: @Sendable @escaping (ScriptInterpreterContext) async throws -> ExitStatus
    ) {
        scriptInterpreters[name] = ClosureScriptInterpreter(name: name, body: body)
    }

    /// Remove a previously-registered interpreter. Returns the removed
    /// entry, or `nil` if no interpreter was registered under `name`.
    @discardableResult
    public func unregisterScriptInterpreter(_ name: String) -> ScriptInterpreter? {
        scriptInterpreters.removeValue(forKey: name)
    }
}

// MARK: - Shebang parsing

/// Parse a `#!`-shebang line. Returns the interpreter basename and the
/// raw argv as the kernel would assemble it for `execve` (interpreter
/// path followed by interpreter args). Returns `nil` if `line` is not
/// a valid shebang.
///
/// This honors the common `/usr/bin/env`-prefix pattern: a shebang
/// like `#!/usr/bin/env swift-script --strict` reports its
/// interpreter as `"swift-script"` rather than `"env"`, and keeps
/// `--strict` as part of the interpreter argv. Both `env` and
/// `env -S` (split-args) forms are handled.
///
/// Resolution rules:
/// - Strip leading `#!` and any whitespace before the path.
/// - Tokenise on whitespace (Linux's `binfmt_script` keeps everything
///   after the first space as one argument; macOS / Darwin splits on
///   whitespace. We follow Darwin's behaviour because that's the host
///   SwiftBash typically targets, and `env -S` makes it portable).
/// - If the interpreter is `env`, walk past `-S`, `-i`, and any
///   `KEY=value` tokens and any `--` separator until we find the real
///   interpreter, then treat that as the dispatch target.
public func parseShebangLine(_ line: String) -> (interpreter: String, argv: [String])? {
    guard line.hasPrefix("#!") else { return nil }
    var rest = Substring(line.dropFirst(2))
    while rest.first == " " || rest.first == "\t" {
        rest.removeFirst()
    }
    let tokens = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard !tokens.isEmpty else { return nil }
    var argv = tokens
    var idx = 0
    let interpreterPath = argv[idx]
    idx += 1
    let interpreterBase = pathBasename(interpreterPath)
    if interpreterBase != "env" {
        return (interpreterBase, argv)
    }
    // env-prefix: skip over -S, -i, KEY=value, and `--` until the real
    // interpreter token surfaces.
    while idx < argv.count {
        let tok = argv[idx]
        if tok == "--" { idx += 1; break }
        if tok.hasPrefix("-") {
            // -S splits its single arg further (env -S "swift-script -O"),
            // but we already split on whitespace upstream. So just step
            // over the flag itself.
            idx += 1
            continue
        }
        if tok.contains("=") && !tok.hasPrefix("=") {
            idx += 1
            continue
        }
        break
    }
    guard idx < argv.count else { return nil }
    let realInterpreter = argv[idx]
    let realBase = pathBasename(realInterpreter)
    // Reassemble argv as the kernel would for `execve`: the real
    // interpreter path comes first, followed by its own args.
    argv = Array(argv[idx...])
    return (realBase, argv)
}

private func pathBasename(_ path: String) -> String {
    if let slash = path.lastIndex(of: "/") {
        return String(path[path.index(after: slash)...])
    }
    return path
}

/// Strip a leading `#!shebang` line so script interpreters never see
/// it. The trailing newline is kept so subsequent line numbers stay
/// in lock-step with the original file: `print("oops")` on physical
/// line 2 of a shebang'd script still surfaces as "line 2" in
/// interpreter diagnostics.
///
/// Comment syntax differs across languages (`#` for Python / shell,
/// `//` for Swift / JS / C, `--` for Lua), so we don't try to rewrite
/// `#!` into something language-specific. Stripping is the universal
/// option: every language tolerates a blank first line.
///
/// Returns the source with the shebang line removed and the original
/// shebang line (without trailing newline) when one was present.
public func stripShebang(_ source: String) -> (source: String, shebang: String?) {
    guard source.hasPrefix("#!") else { return (source, nil) }
    let rest = source.dropFirst(2)
    if let newlineIdx = rest.firstIndex(of: "\n") {
        let shebangLine = "#!" + rest[..<newlineIdx]
        // Drop the shebang content, keep the newline so line numbers
        // below stay accurate. The body therefore begins with `\n`,
        // and the original line 2 is still at line 2.
        let stripped = String(rest[newlineIdx...])
        return (stripped, shebangLine)
    }
    // Whole file is a shebang line with no trailing newline. Empty
    // body, but surface the shebang for diagnostics.
    return ("", "#!" + rest)
}
