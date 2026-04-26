import ArgumentParser
import BashInterpreter
import Foundation

/// Pure formatting helpers shared by stat/readlink/ln/chmod. The
/// actual filesystem ops now live on the ``FileSystem`` protocol.
enum FsTools {

    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func typeWord(_ kind: FileMetadata.Kind) -> String {
        switch kind {
        case .directory: return "directory"
        case .symlink: return "symbolic link"
        case .other: return "special file"
        case .file: return "regular file"
        }
    }

    static func symbolicMode(kind: FileMetadata.Kind, mode: UInt16) -> String {
        let kindCh: Character
        switch kind {
        case .directory: kindCh = "d"
        case .symlink: kindCh = "l"
        case .other: kindCh = "?"
        case .file: kindCh = "-"
        }
        let triplet: (UInt16) -> String = { bits in
            let r = (bits & 0b100) != 0 ? "r" : "-"
            let w = (bits & 0b010) != 0 ? "w" : "-"
            let x = (bits & 0b001) != 0 ? "x" : "-"
            return r + w + x
        }
        let owner = triplet((mode >> 6) & 0o7)
        let group = triplet((mode >> 3) & 0o7)
        let world = triplet(mode & 0o7)
        return String(kindCh) + owner + group + world
    }
}
