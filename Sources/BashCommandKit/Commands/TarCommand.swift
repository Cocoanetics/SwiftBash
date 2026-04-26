import ArgumentParser
import BashInterpreter
import Foundation

/// `tar [OPTIONS] [FILES...]` — read and write ustar archives.
///
/// Modes:
/// - `-c` / `--create` — create a new archive
/// - `-x` / `--extract` — extract files from an archive
/// - `-t` / `--list` — list archive contents
///
/// Options:
/// - `-f FILE` / `--file=FILE` — archive path (default stdin/stdout
///   for read/write modes)
/// - `-v` / `--verbose` — print each file processed (to stderr)
/// - `-C DIR` / `--directory=DIR` — change to DIR before operating
///
/// Out of scope: gzip / bzip2 / xz compression (`-z` `-j` `-J`),
/// tar.gz pipelines, sparse files, ACLs, xattrs, GNU extensions.
/// Use the existing `gzip` / `gunzip` commands in a pipeline for
/// compressed archives: `tar -c dir | gzip > archive.tar.gz`.
public struct TarCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tar",
        abstract: "Manipulate ustar-format archives."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then FILE arguments.")
    public var rawArgv: [String] = []

    public init() {}

    enum Mode { case create, extract, list }

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var mode: Mode? = nil
        var archivePath: String? = nil
        var verbose = false
        var changeDir: String? = nil
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-c" || a == "--create" { mode = .create; i += 1; continue }
            if a == "-x" || a == "--extract" { mode = .extract; i += 1; continue }
            if a == "-t" || a == "--list" { mode = .list; i += 1; continue }
            if a == "-v" || a == "--verbose" { verbose = true; i += 1; continue }
            if a == "-f" || a == "--file" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("tar: -f requires FILE\n"); return ExitStatus(2)
                }
                archivePath = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--file=") {
                archivePath = String(a.dropFirst("--file=".count)); i += 1; continue
            }
            if a == "-C" || a == "--directory" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("tar: -C requires DIR\n"); return ExitStatus(2)
                }
                changeDir = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--directory=") {
                changeDir = String(a.dropFirst("--directory=".count)); i += 1; continue
            }
            // Bundled flags like -cvf or -xvf.
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                var consumeFile = false
                for c in a.dropFirst() {
                    switch c {
                    case "c": mode = .create
                    case "x": mode = .extract
                    case "t": mode = .list
                    case "v": verbose = true
                    case "f": consumeFile = true
                    default:
                        shell.stderr("tar: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1
                if consumeFile {
                    guard i < rawArgv.count else {
                        shell.stderr("tar: -f requires FILE\n"); return ExitStatus(2)
                    }
                    archivePath = rawArgv[i]
                    i += 1
                }
                continue
            }
            files.append(a); i += 1
        }

        guard let mode else {
            shell.stderr("tar: must specify one of -c -x -t\n")
            return ExitStatus(2)
        }

        let cwd = changeDir.map { shell.resolvePath($0) } ?? shell.environment.workingDirectory
        switch mode {
        case .create:
            return await createArchive(files: files, archive: archivePath,
                                       verbose: verbose, cwd: cwd, shell: shell)
        case .extract:
            return await extractArchive(archive: archivePath,
                                        verbose: verbose, cwd: cwd, shell: shell)
        case .list:
            return await listArchive(archive: archivePath,
                                     verbose: verbose, shell: shell)
        }
    }

    // MARK: Create

    private func createArchive(files: [String], archive: String?,
                               verbose: Bool, cwd: String,
                               shell: Shell) async -> ExitStatus {
        var data = Data()
        for f in files {
            let abs = (f as NSString).isAbsolutePath ? f : (cwd as NSString).appendingPathComponent(f)
            do {
                try await emitEntry(name: f, abs: abs, into: &data,
                                    verbose: verbose, shell: shell)
            } catch {
                shell.stderr("tar: \(f): \(error)\n")
                return .failure
            }
        }
        // Two empty 512-byte blocks mark EOF.
        data.append(Data(repeating: 0, count: 1024))
        do {
            if let p = archive, p != "-" {
                try await shell.writeData(data, toPath: p, append: false)
            } else {
                shell.stdout(data)
            }
        } catch {
            shell.stderr("tar: \(error)\n")
            return .failure
        }
        return .success
    }

    private func emitEntry(name: String, abs: String, into data: inout Data,
                           verbose: Bool, shell: Shell) async throws {
        guard let meta = try await shell.fileSystem.metadata(abs) else {
            throw FileSystemError.notFound(name)
        }
        if verbose { shell.stderr(name + "\n") }
        switch meta.kind {
        case .directory:
            // Header for the dir itself, then walk.
            var dirName = name
            if !dirName.hasSuffix("/") { dirName += "/" }
            data.append(makeHeader(name: dirName, size: 0, kind: .directory,
                                   mtime: meta.modifiedAt, mode: 0o755))
            let entries = (try? await shell.fileSystem.list(abs)) ?? []
            for child in entries.sorted() {
                let childAbs = (abs as NSString).appendingPathComponent(child)
                let childName = (name as NSString).appendingPathComponent(child)
                try await emitEntry(name: childName, abs: childAbs, into: &data,
                                    verbose: verbose, shell: shell)
            }
        case .file:
            let body = try await shell.readDataAtPath(abs)
            data.append(makeHeader(name: name, size: Int64(body.count), kind: .file,
                                   mtime: meta.modifiedAt, mode: 0o644))
            data.append(body)
            // Pad to 512.
            let pad = 512 - body.count % 512
            if pad < 512 { data.append(Data(repeating: 0, count: pad)) }
        case .symlink:
            data.append(makeHeader(name: name, size: 0, kind: .symlink,
                                   mtime: meta.modifiedAt, mode: 0o777,
                                   linkName: meta.symlinkTarget ?? ""))
        case .other:
            // Skip special files quietly.
            return
        }
    }

    enum EntryKind { case file, directory, symlink }

    private func makeHeader(name: String, size: Int64, kind: EntryKind,
                            mtime: Date, mode: UInt32, linkName: String = "") -> Data {
        var hdr = Data(repeating: 0, count: 512)
        // name (offset 0, size 100). If name is longer, store last 100
        // bytes — adequate for the common case; long names need the
        // GNU @LongLink mechanism we don't implement.
        let nameBytes = Array(name.utf8.prefix(100))
        for (i, b) in nameBytes.enumerated() { hdr[i] = b }
        // mode (100, 8)
        writeOctal(&hdr, value: UInt64(mode), at: 100, length: 8)
        // uid (108, 8), gid (116, 8)
        writeOctal(&hdr, value: 0, at: 108, length: 8)
        writeOctal(&hdr, value: 0, at: 116, length: 8)
        // size (124, 12)
        writeOctal(&hdr, value: UInt64(size), at: 124, length: 12)
        // mtime (136, 12)
        writeOctal(&hdr, value: UInt64(mtime.timeIntervalSince1970), at: 136, length: 12)
        // checksum (148, 8) — placeholder spaces during compute.
        for i in 148..<156 { hdr[i] = 0x20 }
        // typeflag (156)
        switch kind {
        case .file: hdr[156] = 0x30           // '0'
        case .directory: hdr[156] = 0x35      // '5'
        case .symlink: hdr[156] = 0x32        // '2'
        }
        // linkname (157, 100)
        let linkBytes = Array(linkName.utf8.prefix(100))
        for (i, b) in linkBytes.enumerated() { hdr[157 + i] = b }
        // magic (257, 6) "ustar\0"
        let magic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72, 0x00]
        for (i, b) in magic.enumerated() { hdr[257 + i] = b }
        // version (263, 2) "00"
        hdr[263] = 0x30; hdr[264] = 0x30
        // checksum: sum of all 512 bytes (with checksum field as spaces).
        var sum: UInt64 = 0
        for b in hdr { sum += UInt64(b) }
        writeOctal(&hdr, value: sum, at: 148, length: 7)   // 6 octal + null
        hdr[154] = 0
        hdr[155] = 0x20                                    // trailing space
        return hdr
    }

    private func writeOctal(_ data: inout Data, value: UInt64, at offset: Int, length: Int) {
        // Length-1 octal digits, NUL-terminated.
        let digitCount = length - 1
        var s = String(value, radix: 8)
        while s.count < digitCount { s = "0" + s }
        let bytes = Array(s.suffix(digitCount).utf8)
        for (i, b) in bytes.enumerated() { data[offset + i] = b }
        data[offset + digitCount] = 0
    }

    // MARK: Extract / list

    private func extractArchive(archive: String?, verbose: Bool,
                                cwd: String, shell: Shell) async -> ExitStatus {
        guard let raw = await readArchiveData(archive: archive, shell: shell) else {
            return .failure
        }
        var pos = 0
        while pos + 512 <= raw.count {
            let hdr = raw.subdata(in: pos..<(pos + 512))
            if hdr.allSatisfy({ $0 == 0 }) { break }
            pos += 512
            guard let entry = parseHeader(hdr) else { continue }
            if verbose { shell.stderr(entry.name + "\n") }
            let dest = (cwd as NSString).appendingPathComponent(entry.name)
            switch entry.type {
            case "5":
                // directory
                try? FileManager.default.createDirectory(
                    atPath: dest, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: entry.mode])
            case "2":
                // symlink
                try? FileManager.default.removeItem(atPath: dest)
                try? FileManager.default.createSymbolicLink(
                    atPath: dest, withDestinationPath: entry.linkName)
            default:
                let body = raw.subdata(in: pos..<min(pos + Int(entry.size), raw.count))
                let parent = (dest as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: parent, withIntermediateDirectories: true)
                try? body.write(to: URL(fileURLWithPath: dest))
                try? FileManager.default.setAttributes(
                    [.posixPermissions: entry.mode], ofItemAtPath: dest)
                pos += Int(entry.size)
                let pad = 512 - Int(entry.size) % 512
                if pad < 512 { pos += pad }
            }
        }
        return .success
    }

    private func listArchive(archive: String?, verbose: Bool,
                             shell: Shell) async -> ExitStatus {
        guard let raw = await readArchiveData(archive: archive, shell: shell) else {
            return .failure
        }
        var pos = 0
        while pos + 512 <= raw.count {
            let hdr = raw.subdata(in: pos..<(pos + 512))
            if hdr.allSatisfy({ $0 == 0 }) { break }
            pos += 512
            guard let entry = parseHeader(hdr) else { continue }
            if verbose {
                let kind = entry.type == "5" ? "d" : (entry.type == "2" ? "l" : "-")
                shell.stdout("\(kind) \(entry.size) \(entry.name)\n")
            } else {
                shell.stdout(entry.name + "\n")
            }
            if entry.type != "5" && entry.type != "2" {
                pos += Int(entry.size)
                let pad = 512 - Int(entry.size) % 512
                if pad < 512 { pos += pad }
            }
        }
        return .success
    }

    private func readArchiveData(archive: String?, shell: Shell) async -> Data? {
        do {
            if let p = archive, p != "-" {
                return try await shell.readDataAtPath(p)
            }
            return await shell.stdin.readAllData()
        } catch {
            shell.stderr("tar: \(error)\n")
            return nil
        }
    }

    struct ArchiveEntry {
        let name: String
        let mode: Int
        let size: UInt64
        let type: String
        let linkName: String
    }

    private func parseHeader(_ hdr: Data) -> ArchiveEntry? {
        let name = readString(hdr, at: 0, length: 100)
        guard !name.isEmpty else { return nil }
        let mode = Int(readOctal(hdr, at: 100, length: 8) ?? 0o644)
        let size = readOctal(hdr, at: 124, length: 12) ?? 0
        let typeFlag = String(decoding: hdr.subdata(in: 156..<157), as: UTF8.self)
        let linkName = readString(hdr, at: 157, length: 100)
        return ArchiveEntry(name: name, mode: mode, size: size,
                            type: typeFlag, linkName: linkName)
    }

    private func readString(_ data: Data, at offset: Int, length: Int) -> String {
        let slice = data.subdata(in: offset..<min(offset + length, data.count))
        var bytes: [UInt8] = []
        for b in slice {
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readOctal(_ data: Data, at offset: Int, length: Int) -> UInt64? {
        let s = readString(data, at: offset, length: length)
            .trimmingCharacters(in: .whitespaces)
        return UInt64(s, radix: 8)
    }
}
