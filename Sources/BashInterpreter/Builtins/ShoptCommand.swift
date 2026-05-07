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

        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                names.append(contentsOf: argv.dropFirst(i + 1)); break
            }
            if a.hasPrefix("-") && a.count > 1 {
                for c in a.dropFirst() {
                    switch c {
                    case "s": mode = .set
                    case "u": mode = .unset
                    case "q": mode = .quiet
                    case "p": printMode = true
                    case "o": break // we don't differentiate -o options here
                    default:
                        Shell.bashCurrent.stderr("shopt: invalid option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            names.append(a); i += 1
        }

        switch mode {
        case .list:
            let keys = names.isEmpty
                ? Array(Shell.bashCurrent.shoptOptions.keys).sorted()
                : names
            var anyOff = false
            for key in keys {
                let on = Shell.bashCurrent.shoptOptions[key] ?? false
                if printMode {
                    Shell.bashCurrent.stdout(
                        "shopt -\(on ? "s" : "u") \(key)\n")
                } else {
                    Shell.bashCurrent.stdout("\(key)\t\(on ? "on" : "off")\n")
                }
                if !on { anyOff = true }
            }
            return (names.isEmpty || !anyOff) ? .success : .failure

        case .set, .unset:
            let value = (mode == .set)
            for key in names {
                Shell.bashCurrent.shoptOptions[key] = value
            }
            return .success

        case .quiet:
            for key in names {
                if !(Shell.bashCurrent.shoptOptions[key] ?? false) {
                    return .failure
                }
            }
            return .success
        }
    }

    private enum Mode { case list, set, unset, quiet }
}
