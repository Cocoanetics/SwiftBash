import ArgumentParser
import BashInterpreter
import Foundation

/// `ls [OPTION]... [FILE]...` — list directory contents.
///
/// Supported flags:
/// - `-a` / `--all` — include hidden entries
/// - `-A` / `--almost-all` — include hidden entries except `.` and `..`
/// - `-l` — long listing format (mode, links, owner, size, mtime, name)
/// - `-h` / `--human-readable` — with `-l`, format sizes as 1.5K / 234M / 2G
/// - `-r` / `--reverse` — reverse sort order
/// - `-R` / `--recursive` — recurse into subdirectories
/// - `-S` — sort by size, largest first
/// - `-t` — sort by mtime, newest first
/// - `-d` / `--directory` — list the directory itself, not its contents
/// - `-F` / `--classify` — append `/` for dirs, `*` for executables, `@` for symlinks
/// - `-1` — one entry per line (the default; flag accepted for compatibility)
public struct LsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List directory contents."
    )

    @Argument(help: "Paths to list. Defaults to the current directory.")
    public var paths: [String] = []

    @Flag(name: [.customShort("a"), .customLong("all")],
          help: "Include hidden entries.")
    public var all: Bool = false

    @Flag(name: [.customShort("A"), .customLong("almost-all")],
          help: "Like -a but skip . and ..")
    public var almostAll: Bool = false

    @Flag(name: .customShort("l"), help: "Long listing format.")
    public var long: Bool = false

    @Flag(name: [.customShort("h"), .customLong("human-readable")],
          help: "With -l, print sizes like 1K 234M 2G.")
    public var humanReadable: Bool = false

    @Flag(name: [.customShort("r"), .customLong("reverse")],
          help: "Reverse sort order.")
    public var reverse: Bool = false

    @Flag(name: [.customShort("R"), .customLong("recursive")],
          help: "List subdirectories recursively.")
    public var recursive: Bool = false

    @Flag(name: .customShort("S"), help: "Sort by size, largest first.")
    public var sortBySize: Bool = false

    @Flag(name: .customShort("t"), help: "Sort by mtime, newest first.")
    public var sortByTime: Bool = false

    @Flag(name: [.customShort("d"), .customLong("directory")],
          help: "List directories themselves, not their contents.")
    public var directoryOnly: Bool = false

    @Flag(name: [.customShort("F"), .customLong("classify")],
          help: "Append indicator (/, *, @) to entries.")
    public var classify: Bool = false

    @Flag(name: .customShort("1"), help: "One entry per line (default).")
    public var oneLine: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let targets = paths.isEmpty ? ["."] : paths
        var hadError = false

        for (index, path) in targets.enumerated() {
            let resolved = Shell.bashCurrent.resolvePath(path)
            let meta: FileMetadata?
            do {
                meta = try await Shell.bashCurrent.fileSystem.metadata(resolved)
            } catch {
                Shell.bashCurrent.stderr("ls: \(path): \(error)\n")
                hadError = true
                continue
            }
            guard let meta else {
                Shell.bashCurrent.stderr("ls: \(path): No such file or directory\n")
                hadError = true
                continue
            }

            if directoryOnly || meta.kind != .directory {
                if index > 0 { Shell.bashCurrent.stdout("\n") }
                let entry = Entry(name: path, meta: meta)
                if long {
                    Shell.bashCurrent.stdout(formatLong(entry) + "\n")
                } else {
                    Shell.bashCurrent.stdout(formatEntry(name: path, meta: meta) + "\n")
                }
                continue
            }

            do {
                try await listDirectory(path: path, fullPath: resolved,
                                        showHeader: targets.count > 1 || recursive,
                                        leadingNewline: index > 0)
            } catch {
                Shell.bashCurrent.stderr("ls: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    // MARK: - Directory listing

    // ls listing assembles entry filtering, dotfile handling, long/short
    // format selection, and recursion in one place; rule budget needs
    // a surgical disable.
    // swiftlint:disable:next cyclomatic_complexity
    private func listDirectory(path: String, fullPath: String,
                               showHeader: Bool, leadingNewline: Bool) async throws {
        let rawEntries = try await Shell.bashCurrent.fileSystem.list(fullPath)
        // FileEntry now carries metadata inline — no need to round-trip
        // back through metadata(_:) per name. Filter hidden first.
        let visible: [FileEntry] = (all || almostAll)
            ? rawEntries
            : rawEntries.filter { !$0.name.hasPrefix(".") }
        var entries: [Entry] = visible.map {
            Entry(name: $0.name, meta: $0.metadata)
        }

        if all {
            // `.` is the directory itself; `..` is its parent. Stat
            // both so the long listing reports the right kind / mode
            // / mtime instead of falling back to file defaults.
            let dotMeta = (try? await Shell.bashCurrent.fileSystem.metadata(fullPath))
                ?? nil
            let parentPath = (fullPath as NSString).deletingLastPathComponent
            let dotDotMeta = (try? await Shell.bashCurrent.fileSystem
                .metadata(parentPath.isEmpty ? "/" : parentPath)) ?? nil
            entries.insert(Entry(name: "..", meta: dotDotMeta), at: 0)
            entries.insert(Entry(name: ".", meta: dotMeta), at: 0)
        }

        sort(&entries)
        if reverse { entries.reverse() }

        if leadingNewline { Shell.bashCurrent.stdout("\n") }
        if showHeader { Shell.bashCurrent.stdout("\(path):\n") }

        if long {
            // GNU ls prefaces long listings with "total N" — we don't
            // have block counts, but POSIX accepts a 0-or-count value.
            let total = entries.reduce(0) { $0 + Int(($1.meta?.size ?? 0) / 1024) }
            Shell.bashCurrent.stdout("total \(total)\n")
            for entry in entries {
                Shell.bashCurrent.stdout(formatLong(entry) + "\n")
            }
        } else {
            for entry in entries {
                Shell.bashCurrent.stdout(formatEntry(name: entry.name, meta: entry.meta) + "\n")
            }
        }

        if recursive {
            // Recurse into real subdirectories (not "." / "..").
            var subdirs: [Entry] = entries.filter { entry in
                guard entry.name != "." && entry.name != ".." else { return false }
                return entry.meta?.kind == .directory
            }
            sort(&subdirs)
            if reverse { subdirs.reverse() }
            for sub in subdirs {
                let subPath = path == "." ? "./\(sub.name)" : "\(path)/\(sub.name)"
                let subFull = joinPath(fullPath, sub.name)
                try await listDirectory(path: subPath, fullPath: subFull,
                                        showHeader: true, leadingNewline: true)
            }
        }
    }

    private func sort(_ entries: inout [Entry]) {
        if sortBySize {
            entries.sort { ($0.meta?.size ?? 0) > ($1.meta?.size ?? 0) }
        } else if sortByTime {
            entries.sort {
                let leftTime = $0.meta?.modifiedAt ?? Date(timeIntervalSince1970: 0)
                let rightTime = $1.meta?.modifiedAt ?? Date(timeIntervalSince1970: 0)
                return leftTime > rightTime
            }
        } else {
            entries.sort { $0.name < $1.name }
        }
    }

    // MARK: - Formatting

    private func formatEntry(name: String, meta: FileMetadata?) -> String {
        guard classify, let meta else { return name }
        switch meta.kind {
        case .directory: return name + "/"
        case .symlink: return name + "@"
        default: return name
        }
    }

    private func formatLong(_ entry: Entry) -> String {
        let host = Shell.bashCurrent.hostInfo
        let kind = entry.meta?.kind ?? .file
        // Real permission bits from FileMetadata.mode, formatted as
        // bash-style `rwxrw-r--`. Falls back to defaults only when
        // metadata is unavailable.
        let modeBits = entry.meta?.mode ?? (kind == .directory ? 0o755 : 0o644)
        let mode = formatMode(kind: kind, bits: modeBits)

        let nlinks = entry.meta?.linkCount ?? 1

        // Owner / group from synthetic-by-default `HostInfo`. Looking
        // up names per uid/gid would require a passwd-database
        // abstraction; for now the names track `hostInfo`'s and the
        // numeric ownership lives in `meta.uid` / `.gid` for callers
        // that want it.
        let owner = host.userName
        let group = host.groupName

        let size = entry.meta?.size ?? 0
        let sizeStr = humanReadable
            ? humanSize(size).leftPad(width: 5)
            : String(size).leftPad(width: 5)
        let mtime = entry.meta?.modifiedAt ?? Date(timeIntervalSince1970: 0)
        let suffix: String
        if classify {
            switch kind {
            case .directory: suffix = "/"
            case .symlink:   suffix = "@"
            default:         suffix = ""
            }
        } else {
            suffix = ""
        }
        var line = "\(mode) \(nlinks) \(owner) \(group)"
            + " \(sizeStr) \(formatDate(mtime)) \(entry.name)\(suffix)"
        if kind == .symlink, let target = entry.meta?.symlinkTarget {
            line += " -> \(target)"
        }
        return line
    }

    /// Format `mode` (low 12 bits of POSIX permission flags) as the
    /// 10-character bash-style string: `<kind><rwx><rwx><rwx>`.
    /// Honours setuid (`s`/`S`), setgid (`s`/`S`), and sticky bit
    /// (`t`/`T`).
    private func formatMode(kind: FileMetadata.Kind, bits: UInt16) -> String {
        let kindCh: Character
        switch kind {
        case .directory: kindCh = "d"
        case .symlink:   kindCh = "l"
        case .file:      kindCh = "-"
        case .other:     kindCh = "?"
        }
        // Owner/group/other rwx triples.
        let owner = rwxTriple(RwxTripleSpec(
            readBit: bits & 0o400, writeBit: bits & 0o200, execBit: bits & 0o100,
            extraBit: bits & 0o4000, extraOnChar: "s", extraOffChar: "S"))
        let group = rwxTriple(RwxTripleSpec(
            readBit: bits & 0o040, writeBit: bits & 0o020, execBit: bits & 0o010,
            extraBit: bits & 0o2000, extraOnChar: "s", extraOffChar: "S"))
        let other = rwxTriple(RwxTripleSpec(
            readBit: bits & 0o004, writeBit: bits & 0o002, execBit: bits & 0o001,
            extraBit: bits & 0o1000, extraOnChar: "t", extraOffChar: "T"))
        return String(kindCh) + owner + group + other
    }

    private struct RwxTripleSpec {
        let readBit: UInt16
        let writeBit: UInt16
        let execBit: UInt16
        let extraBit: UInt16
        let extraOnChar: Character
        let extraOffChar: Character
    }

    private func rwxTriple(_ spec: RwxTripleSpec) -> String {
        var out = ""
        out.append(spec.readBit != 0 ? "r" : "-")
        out.append(spec.writeBit != 0 ? "w" : "-")
        if spec.extraBit != 0 {
            // setuid/setgid/sticky takes the x position; case toggles
            // on whether the underlying execute bit is set.
            out.append(spec.execBit != 0 ? spec.extraOnChar : spec.extraOffChar)
        } else {
            out.append(spec.execBit != 0 ? "x" : "-")
        }
        return out
    }

    private func humanSize(_ bytes: Int64) -> String {
        let kib = 1024.0
        let total = Double(bytes)
        if total < kib { return String(bytes) }
        if total < kib * kib {
            let scaled = total / kib
            return scaled < 10 ? String(format: "%.1fK", scaled) : "\(Int(scaled.rounded()))K"
        }
        if total < kib * kib * kib {
            let scaled = total / (kib * kib)
            return scaled < 10 ? String(format: "%.1fM", scaled) : "\(Int(scaled.rounded()))M"
        }
        let scaled = total / (kib * kib * kib)
        return scaled < 10 ? String(format: "%.1fG", scaled) : "\(Int(scaled.rounded()))G"
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let sixMonthsAgo = now.addingTimeInterval(-180 * 24 * 60 * 60)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let mon = months[(comps.month ?? 1) - 1]
        let day = String(comps.day ?? 1).leftPad(width: 2)
        if date > sixMonthsAgo {
            let hour = String(format: "%02d", comps.hour ?? 0)
            let minute = String(format: "%02d", comps.minute ?? 0)
            return "\(mon) \(day) \(hour):\(minute)"
        }
        return "\(mon) \(day)  \(comps.year ?? 1970)"
    }

    private func joinPath(_ base: String, _ name: String) -> String {
        if base == "/" { return "/\(name)" }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    struct Entry {
        let name: String
        let meta: FileMetadata?
    }
}

private extension String {
    func leftPad(width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
