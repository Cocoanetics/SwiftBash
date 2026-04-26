import ArgumentParser
import BashInterpreter
import Foundation

public struct PkillCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pkill",
        abstract: "Signal processes by name."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then PATTERN")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var sig: Int32 = SIGTERM
        var fullCommand = false
        var pattern: String? = nil
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-f" { fullCommand = true; i += 1; continue }
            if a == "-s" {
                guard i + 1 < rawArgv.count, let s = parseSignal(rawArgv[i + 1]) else {
                    Shell.current.stderr("pkill: invalid signal\n"); return ExitStatus(2)
                }
                sig = s; i += 2; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                let body = String(a.dropFirst())
                if body == "f" { fullCommand = true; i += 1; continue }
                if let s = parseSignal(body) { sig = s; i += 1; continue }
                Shell.current.stderr("pkill: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            pattern = a; i += 1
        }
        guard let pat = pattern else {
            Shell.current.stderr("pkill: missing pattern\n")
            return ExitStatus(2)
        }
        guard let regex = try? NSRegularExpression(pattern: pat) else {
            Shell.current.stderr("pkill: invalid pattern\n")
            return ExitStatus(2)
        }
        let matches = ProcessList.allProcesses().filter { p in
            let target = fullCommand ? p.command : p.comm
            let ns = target as NSString
            return regex.firstMatch(in: target,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        }
        var hadError = false
        for p in matches {
            if Foundation.kill(p.pid, sig) != 0 {
                Shell.current.stderr("pkill: \(p.pid): \(String(cString: strerror(errno)))\n")
                hadError = true
            }
        }
        return matches.isEmpty ? ExitStatus(1) : (hadError ? .failure : .success)
    }
}
