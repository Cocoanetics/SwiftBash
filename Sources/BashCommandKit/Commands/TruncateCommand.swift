import ArgumentParser
import BashInterpreter
import Foundation

/// `truncate -s SIZE FILE...` — shrink or extend each FILE to the
/// given byte size. Extending pads with zero bytes; shrinking
/// discards the trailing data.
///
/// Size accepts a plain byte count or a relative form (`+10`,
/// `-10`) and the suffixes `K M G` (powers of 1024).
public struct TruncateCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "truncate",
        abstract: "Shrink or extend the size of a file."
    )

    @Option(name: .customShort("s"),
            help: "Target size: NNN[KMG], or +NNN / -NNN to adjust.")
    public var size: String = ""

    @Flag(name: .customShort("c"),
          help: "Don't create files that don't exist.")
    public var noCreate: Bool = false

    @Argument(help: "Files to truncate.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard !size.isEmpty else {
            Shell.bashCurrent.stderr("truncate: missing -s SIZE\n")
            return .failure
        }
        guard let parsed = Self.parseSize(size) else {
            Shell.bashCurrent.stderr("truncate: invalid size: \(size)\n")
            return .failure
        }
        if files.isEmpty {
            Shell.bashCurrent.stderr("truncate: missing file operand\n")
            return .failure
        }
        var hadError = false
        for file in files {
            let resolved = Shell.bashCurrent.resolvePath(file)
            do {
                let existing = try? await Shell.bashCurrent.fileSystem
                    .readData(resolved)
                if existing == nil && noCreate { continue }
                let current = existing ?? Data()
                let target = Self.applySize(parsed, to: current.count)
                var newData: Data
                if target <= current.count {
                    newData = current.prefix(target)
                } else {
                    newData = current
                    newData.append(Data(repeating: 0, count: target - current.count))
                }
                try await Shell.bashCurrent.fileSystem.writeData(
                    newData, to: resolved, append: false)
            } catch {
                Shell.bashCurrent.stderr("truncate: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    enum SizeOp { case absolute(Int), plus(Int), minus(Int) }

    static func parseSize(_ text: String) -> SizeOp? {
        var body = text[...]
        var operation: (Int) -> SizeOp = { .absolute($0) }
        if let first = body.first {
            if first == "+" {
                operation = { .plus($0) }; body = body.dropFirst()
            } else if first == "-" {
                operation = { .minus($0) }; body = body.dropFirst()
            }
        }
        var multiplier = 1
        if let last = body.last {
            switch last {
            case "K", "k": multiplier = 1024
            case "M", "m": multiplier = 1024 * 1024
            case "G", "g": multiplier = 1024 * 1024 * 1024
            default: break
            }
            if multiplier != 1 { body = body.dropLast() }
        }
        guard let value = Int(body), value >= 0 else { return nil }
        return operation(value * multiplier)
    }

    static func applySize(_ operation: SizeOp, to current: Int) -> Int {
        switch operation {
        case .absolute(let value): return value
        case .plus(let delta):     return current + delta
        case .minus(let delta):    return max(0, current - delta)
        }
    }
}
