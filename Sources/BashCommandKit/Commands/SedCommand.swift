import ArgumentParser
import BashInterpreter
import Foundation

/// `sed [OPTIONS] {script} [FILE...]` — full GNU-flavoured stream editor.
///
/// Implements the entire sed command grammar: substitute (`s/PAT/REP/g`
/// with `i` `p` `w` `n-th` flags), text commands (`a`/`i`/`c` with
/// `\<NL>text` continuation), hold/exchange (`h`/`H`/`g`/`G`/`x`),
/// branches (`b`/`t`/`T` with labels), groups (`{ … }`), multi-line
/// (`n`/`N`/`P`/`D`), addresses (line, `$`, regex, `first~step`,
/// `,+N` relative offsets, ranges, negation `!`), transliteration
/// (`y/src/dst/`), reads/writes (`r`/`R`/`w`/`W`), and the
/// `=`/`l`/`F`/`v`/`q`/`Q`/`z` family.
///
/// Regex flavour follows POSIX BRE by default (with `\+`, `\?`, `\(…\)`
/// special); pass `-E` / `-r` / `--regexp-extended` for ERE.
///
/// Options: `-n` (quiet), `-e PROGRAM` (repeatable), `-f FILE`,
/// `-i` (in-place), `-E`/`-r` (extended regex). The `e` substitute /
/// command flag (shell exec) is intentionally blocked.
public struct SedCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sed",
        abstract: "Stream editor for filtering and transforming text."
    )

    @Option(name: [.customShort("e"), .customLong("expression")],
            parsing: .singleValue,
            help: "Append a program. May be repeated.")
    public var expressions: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")],
            parsing: .singleValue,
            help: "Read script from file. May be repeated.")
    public var scriptFiles: [String] = []

    @Argument(help: """
        When no -e or -f was given, the first positional is the program; \
        the rest are files. Otherwise all positionals are files.
        """)
    public var positionals: [String] = []

    @Flag(name: [.customShort("n"), .customLong("quiet")],
          help: "Suppress automatic printing of the pattern space.")
    public var quiet: Bool = false

    @Flag(name: [.customShort("E"), .customLong("regexp-extended")],
          help: "Use extended regular expressions.")
    public var extendedRegexp: Bool = false

    @Flag(name: .customShort("r"),
          help: "Use extended regular expressions (alias of -E).")
    public var rOption: Bool = false

    @Flag(name: [.customShort("i"), .customLong("in-place")],
          help: "Edit files in place.")
    public var inPlace: Bool = false

    public init() {}

    // `sed` execution combines script loading, file iteration, in-place
    // writeback, and stream pipelining. Splitting would scatter shared state.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        // Gather scripts and files.
        var scripts = expressions
        var files = positionals
        for scriptFile in scriptFiles {
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(scriptFile)
                // sed scripts may legitimately be partial UTF-8 in binary contexts.
                // swiftlint:disable:next optional_data_string_conversion
                let text = String(decoding: data, as: UTF8.self)
                scripts.append(text)
            } catch {
                Shell.bashCurrent.stderr("sed: couldn't open file \(scriptFile): \(error)\n")
                return ExitStatus(2)
            }
        }
        if expressions.isEmpty && scriptFiles.isEmpty {
            guard let first = positionals.first else {
                Shell.bashCurrent.stderr("sed: missing program\n")
                return ExitStatus(2)
            }
            scripts = [first]
            files = Array(positionals.dropFirst())
        }
        let extendedFlag = extendedRegexp || rOption

        let parsed: SedParser.ParseResult
        do {
            parsed = try SedParser.parse(scripts: scripts, extendedRegex: extendedFlag)
        } catch let err as SedScriptError {
            Shell.bashCurrent.stderr("sed: \(err.message)\n")
            return ExitStatus(2)
        }
        let effectiveSilent = quiet || parsed.silentMode

        if inPlace {
            if files.isEmpty {
                Shell.bashCurrent.stderr("sed: -i requires file arguments\n")
                return ExitStatus(2)
            }
            for path in files {
                try Task.checkCancellation()
                if path == "-" { continue }
                do {
                    let data = try await Shell.bashCurrent.readDataAtPath(path)
                    // sed input may legitimately be partial UTF-8.
                    // swiftlint:disable:next optional_data_string_conversion
                    let text = String(decoding: data, as: UTF8.self)
                    let result = await runScript(parsed.commands, on: text,
                                                 filename: path,
                                                 silent: effectiveSilent)
                    if let err = result.errorMessage {
                        Shell.bashCurrent.stderr(err + "\n")
                        return ExitStatus(result.exitCode ?? 1)
                    }
                    try await Shell.bashCurrent.writeData(Data(result.output.utf8),
                                              toPath: path, append: false)
                } catch {
                    Shell.bashCurrent.stderr("sed: \(path): \(error)\n")
                    return .failure
                }
            }
            return .success
        }

        // Read inputs into a single buffer (sed processes a single
        // logical stream).
        var content = ""
        if files.isEmpty {
            content = await Shell.bashCurrent.stdin.readAllString()
        } else {
            var stdinConsumed = false
            for path in files {
                let chunk: String
                if path == "-" {
                    if stdinConsumed {
                        chunk = ""
                    } else {
                        chunk = await Shell.bashCurrent.stdin.readAllString()
                        stdinConsumed = true
                    }
                } else {
                    do {
                        let data = try await Shell.bashCurrent.readDataAtPath(path)
                        // sed input may legitimately be partial UTF-8.
                        // swiftlint:disable:next optional_data_string_conversion
                        chunk = String(decoding: data, as: UTF8.self)
                    } catch {
                        Shell.bashCurrent.stderr("sed: \(path): No such file or directory\n")
                        return ExitStatus(2)
                    }
                }
                if !content.isEmpty && !chunk.isEmpty && !content.hasSuffix("\n") {
                    content += "\n"
                }
                content += chunk
            }
        }
        let displayName: String? = files.count == 1 ? files[0] : nil
        let result = await runScript(parsed.commands, on: content,
                                     filename: displayName,
                                     silent: effectiveSilent)
        if let err = result.errorMessage {
            Shell.bashCurrent.stderr(err + "\n")
            return ExitStatus(result.exitCode ?? 1)
        }
        Shell.bashCurrent.stdout(result.output)
        return ExitStatus(result.exitCode ?? 0)
    }

    private func runScript(_ cmds: [SedCommandNode], on content: String,
                           filename: String?, silent: Bool) async -> SedExecutor.RunResult {
        let inputEndsWithNewline = content.hasSuffix("\n")
        let lines = SedExecutor.splitLines(content)
        let executor = SedExecutor(commands: cmds, silent: silent,
                                   filename: filename)
        // sed file reads are sync from the executor's POV; pre-load any
        // r/R targets that the script names. Walk the AST to collect
        // filenames, then async-read them up-front into a closure cache.
        var fileCache: [String: String] = [:]
        for path in collectReadTargets(cmds) {
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(path)
                // sed `r` reads may legitimately be partial UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                fileCache[path] = String(decoding: data, as: UTF8.self)
            } catch {
                // Missing files yield empty input — matches sed semantics.
                fileCache[path] = ""
            }
        }
        let result = executor.run(lines: lines,
                                  inputEndsWithNewline: inputEndsWithNewline) { name in
            fileCache[name] ?? ""
        }
        // Flush any pending writes.
        for (path, content) in executor.pendingFileWrites {
            try? await Shell.bashCurrent.writeData(Data(content.utf8), toPath: path, append: false)
        }
        return result
    }

    private func collectReadTargets(_ cmds: [SedCommandNode]) -> Set<String> {
        var out = Set<String>()
        for cmd in cmds {
            switch cmd {
            case .readFile(_, let path), .readFileLine(_, let path):
                out.insert(path)
            case .group(_, let inner):
                out.formUnion(collectReadTargets(inner))
            default: break
            }
        }
        return out
    }
}
