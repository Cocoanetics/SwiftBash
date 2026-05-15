import ArgumentParser
import BashInterpreter
import Foundation

/// Pure formatting helpers shared by stat/readlink/ln/chmod. The
/// actual filesystem ops now live on the ``FileSystem`` protocol.
enum FsTools {

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
            let read = (bits & 0b100) != 0 ? "r" : "-"
            let write = (bits & 0b010) != 0 ? "w" : "-"
            let execute = (bits & 0b001) != 0 ? "x" : "-"
            return read + write + execute
        }
        let owner = triplet((mode >> 6) & 0o7)
        let group = triplet((mode >> 3) & 0o7)
        let world = triplet(mode & 0o7)
        return String(kindCh) + owner + group + world
    }
}
