import ArgumentParser
import BashInterpreter
import Foundation

/// `jq [OPTIONS] FILTER [FILE...]` — command-line JSON processor.
///
/// A native Swift implementation that mirrors stedolan/jq's surface
/// area: a recursive-descent parser, a streaming evaluator, and the
/// full builtin library (math, type, string, array, object, control,
/// path, navigation, SQL, date, formatters).
///
/// Supported options: `-r`/`--raw-output`, `-c`/`--compact-output`,
/// `-e`/`--exit-status`, `-s`/`--slurp`, `-n`/`--null-input`,
/// `-j`/`--join-output`, `-S`/`--sort-keys`, `-R`/`--raw-input`,
/// `--tab`, `--indent N`, `--arg NAME VALUE`, `--argjson NAME VALUE`,
/// `--slurpfile NAME FILE`, `--rawfile NAME FILE`,
/// `--args`/`--jsonargs` (positional). Color flags (`-C`, `-M`, `-a`)
/// are accepted but ignored.
///
/// Flags can appear anywhere on the command line, matching jq's
/// behaviour — that's why we hand-parse argv instead of using
/// ``ParsableBashCommand``'s @Flag declarations.
public struct JqCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "jq",
        abstract: "Command-line JSON processor."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILTER, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var raw = false
        var rawInput = false
        var compact = false
        var exitStatus = false
        var slurp = false
        var nullInput = false
        var joinOutput = false
        var sortKeys = false
        var useTab = false
        var indent = 2

        var filter: String? = nil
        var files: [String] = []
        var namedArgs: [String: JqValue] = [:]
        var positional: [JqValue] = []
        var inArgsMode: ArgsMode = .none

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            switch inArgsMode {
            case .args:
                positional.append(.string(a))
                i += 1
                continue
            case .jsonargs:
                if let v = try? JqJSON.parse(a) {
                    positional.append(v)
                } else {
                    shell.stderr("jq: invalid JSON in --jsonargs: \(a)\n")
                    return ExitStatus(2)
                }
                i += 1
                continue
            case .none:
                break
            }

            // Long flags
            switch a {
            case "--raw-output": raw = true; i += 1; continue
            case "--raw-input": rawInput = true; i += 1; continue
            case "--compact-output": compact = true; i += 1; continue
            case "--exit-status": exitStatus = true; i += 1; continue
            case "--slurp": slurp = true; i += 1; continue
            case "--null-input": nullInput = true; i += 1; continue
            case "--join-output": joinOutput = true; i += 1; continue
            case "--ascii-output": i += 1; continue
            case "--sort-keys": sortKeys = true; i += 1; continue
            case "--color-output", "--monochrome-output": i += 1; continue
            case "--tab": useTab = true; i += 1; continue
            case "--indent":
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    shell.stderr("jq: --indent requires a number\n")
                    return ExitStatus(2)
                }
                indent = n; i += 2; continue
            case "--arg":
                guard i + 2 < rawArgv.count else {
                    shell.stderr("jq: --arg requires NAME VALUE\n")
                    return ExitStatus(2)
                }
                namedArgs[rawArgv[i + 1]] = .string(rawArgv[i + 2])
                i += 3; continue
            case "--argjson":
                guard i + 2 < rawArgv.count else {
                    shell.stderr("jq: --argjson requires NAME VALUE\n")
                    return ExitStatus(2)
                }
                if let v = try? JqJSON.parse(rawArgv[i + 2]) {
                    namedArgs[rawArgv[i + 1]] = v
                } else {
                    shell.stderr("jq: invalid JSON for --argjson \(rawArgv[i + 1])\n")
                    return ExitStatus(2)
                }
                i += 3; continue
            case "--slurpfile", "--rawfile":
                guard i + 2 < rawArgv.count else {
                    shell.stderr("jq: \(a) requires NAME FILE\n")
                    return ExitStatus(2)
                }
                let name = rawArgv[i + 1]
                let path = rawArgv[i + 2]
                do {
                    let data = try await shell.readDataAtPath(path)
                    let text = String(decoding: data, as: UTF8.self)
                    if a == "--slurpfile" {
                        let vs = try JqJSON.parseStream(text)
                        namedArgs[name] = .array(vs)
                    } else {
                        namedArgs[name] = .string(text)
                    }
                } catch {
                    shell.stderr("jq: cannot read file \(path): \(error)\n")
                    return ExitStatus(2)
                }
                i += 3; continue
            case "--args": inArgsMode = .args; i += 1; continue
            case "--jsonargs": inArgsMode = .jsonargs; i += 1; continue
            case "--help":
                shell.stdout("jq - command-line JSON processor\n")
                return .success
            case "--version":
                shell.stdout("jq-1.7 (swift-bash)\n")
                return .success
            default: break
            }

            // Short flags: a single dash followed by one or more flag
            // chars. `-` on its own is the stdin marker.
            if a == "-" {
                files.append("-"); i += 1; continue
            }
            if a.hasPrefix("-") && !a.hasPrefix("--") && a.count > 1 {
                let chars = Array(a.dropFirst())
                var unknown = false
                for c in chars {
                    switch c {
                    case "r": raw = true
                    case "R": rawInput = true
                    case "c": compact = true
                    case "e": exitStatus = true
                    case "s": slurp = true
                    case "n": nullInput = true
                    case "j": joinOutput = true
                    case "a": break
                    case "S": sortKeys = true
                    case "C", "M": break
                    default: unknown = true
                    }
                }
                if unknown {
                    shell.stderr("jq: invalid option: \(a)\n")
                    return ExitStatus(2)
                }
                i += 1
                continue
            }
            if a.hasPrefix("--") {
                shell.stderr("jq: unknown option: \(a)\n")
                return ExitStatus(2)
            }

            // Positional: filter, then files
            if filter == nil {
                filter = a
            } else {
                files.append(a)
            }
            i += 1
        }
        let filterStr = filter ?? "."

        let ast: JqAST
        do {
            ast = try JqParser.parse(filterStr)
        } catch let e as JqError {
            shell.stderr("jq: \(e.message)\n")
            return ExitStatus(3)
        } catch {
            shell.stderr("jq: \(error)\n")
            return ExitStatus(3)
        }

        // Collect inputs.
        var inputContents: [String] = []
        if nullInput {
            // no inputs
        } else if files.isEmpty || (files.count == 1 && files[0] == "-") {
            inputContents.append(await shell.stdin.readAllString())
        } else {
            for f in files {
                if f == "-" {
                    inputContents.append(await shell.stdin.readAllString())
                    continue
                }
                do {
                    let data = try await shell.readDataAtPath(f)
                    inputContents.append(String(decoding: data, as: UTF8.self))
                } catch {
                    shell.stderr("jq: error: cannot read file \(f): \(error)\n")
                    return ExitStatus(2)
                }
            }
        }

        var values: [JqValue] = []
        do {
            if nullInput {
                values = [.null]
            } else if rawInput {
                if slurp {
                    values = [.string(inputContents.joined())]
                } else {
                    let combined = inputContents.joined()
                    values = combined.split(omittingEmptySubsequences: false,
                                            whereSeparator: { $0 == "\n" })
                        .map { .string(String($0)) }
                    if values.last == .string("") { values.removeLast() }
                }
            } else if slurp {
                var slurped: [JqValue] = []
                for c in inputContents {
                    let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        slurped.append(contentsOf: try JqJSON.parseStream(c))
                    }
                }
                values = [.array(slurped)]
            } else {
                for c in inputContents {
                    let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    values.append(contentsOf: try JqJSON.parseStream(c))
                }
            }
        } catch let e as JqError {
            shell.stderr("jq: \(e.message)\n")
            return ExitStatus(2)
        } catch {
            shell.stderr("jq: \(error)\n")
            return ExitStatus(2)
        }

        let env: [String: String] = shell.environment.variables

        // Build a shared variable map carrying --arg/--argjson and $ARGS.
        var sharedVars: [String: JqValue] = [:]
        for (name, val) in namedArgs {
            sharedVars["$\(name)"] = val
        }
        var argsObj = JqObject()
        argsObj["positional"] = .array(positional)
        var named = JqObject()
        for (k, v) in namedArgs { named[k] = v }
        argsObj["named"] = .object(named)
        sharedVars["$ARGS"] = .object(argsObj)

        var allOutputs: [JqValue] = []
        for v in values {
            do {
                let ctx2 = JqContext(env: env)
                ctx2.vars = sharedVars
                let results = try JqEvaluator.evaluate(v, ast, ctx: ctx2)
                allOutputs.append(contentsOf: results)
            } catch let e as JqError {
                shell.stderr("jq: error: \(e.message)\n")
                return ExitStatus(5)
            } catch let e as JqThrown {
                shell.stderr("jq: error: \(e.description)\n")
                return ExitStatus(5)
            } catch {
                shell.stderr("jq: error: \(error)\n")
                return ExitStatus(5)
            }
        }

        let opts = JqFormatter.Options(
            compact: compact, raw: raw, sortKeys: sortKeys,
            useTab: useTab, indent: indent)
        var out = ""
        for v in allOutputs {
            out += JqFormatter.format(v, options: opts)
            if !joinOutput {
                out += "\n"
            }
        }
        shell.stdout(out)

        if exitStatus {
            let allFalsy = allOutputs.isEmpty || allOutputs.allSatisfy { v in
                switch v {
                case .null, .bool(false): return true
                default: return false
                }
            }
            return allFalsy ? ExitStatus(1) : .success
        }
        return .success
    }

    private enum ArgsMode { case none, args, jsonargs }
}
