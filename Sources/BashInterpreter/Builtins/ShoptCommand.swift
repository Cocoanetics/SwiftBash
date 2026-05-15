import Foundation

/// `shopt [-pqsu] [-o] [optname …]` — query and set shell options.
///
/// Modes:
/// - bare `shopt` lists every option and its current `on`/`off` state.
/// - `shopt -s NAME` enables, `-u NAME` disables, `-q NAME` returns
///   `0` if on else `1` (no output).
/// - `-p` prints in `shopt -s NAME` / `shopt -u NAME` form.
/// - Unknown option names are silently accepted (set/unset) so scripts
///   that toggle bash 4-only features don't crash on us.
public struct ShoptCommand: Command {
    public let name = "shopt"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var mode: Mode = .list
        var printMode = false
        var names: [String] = []

        switch parseFlags(argv, mode: &mode, printMode: &printMode, names: &names) {
        case .success: break
        case .failure(let status): return status
        }

        switch mode {
        case .list:
            return runList(names: names, printMode: printMode)
        case .set, .unset:
            let value = (mode == .set)
            for key in names {
                Shell.bashCurrent.shoptOptions[key] = value
            }
            return .success
        case .quiet:
            for key in names where !(Shell.bashCurrent.shoptOptions[key] ?? false) {
                return .failure
            }
            return .success
        }
    }

    private enum FlagParseResult {
        case success
        case failure(ExitStatus)
    }

    private func parseFlags(_ argv: [String],
                            mode: inout Mode,
                            printMode: inout Bool,
                            names: inout [String]) -> FlagParseResult {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" {
                names.append(contentsOf: argv.dropFirst(index + 1))
                return .success
            }
            if arg.hasPrefix("-") && arg.count > 1 {
                for char in arg.dropFirst() {
                    switch char {
                    case "s": mode = .set
                    case "u": mode = .unset
                    case "q": mode = .quiet
                    case "p": printMode = true
                    case "o": break // we don't differentiate -o options here
                    default:
                        Shell.bashCurrent.stderr("shopt: invalid option: -\(char)\n")
                        return .failure(ExitStatus(2))
                    }
                }
                index += 1
                continue
            }
            names.append(arg)
            index += 1
        }
        return .success
    }

    private func runList(names: [String], printMode: Bool) -> ExitStatus {
        let keys = names.isEmpty
            ? Array(Shell.bashCurrent.shoptOptions.keys).sorted()
            : names
        var anyOff = false
        for key in keys {
            let enabled = Shell.bashCurrent.shoptOptions[key] ?? false
            if printMode {
                Shell.bashCurrent.stdout(
                    "shopt -\(enabled ? "s" : "u") \(key)\n")
            } else {
                Shell.bashCurrent.stdout("\(key)\t\(enabled ? "on" : "off")\n")
            }
            if !enabled { anyOff = true }
        }
        return (names.isEmpty || !anyOff) ? .success : .failure
    }

    private enum Mode { case list, set, unset, quiet }
}
