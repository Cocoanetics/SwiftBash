import Foundation
@testable import BashInterpreter

/// Synthetic FS that rejects every read with `permissionDenied`.
/// Used to drive the dispatcher's explicit-path FS-error branch
/// without depending on chmod-able real disk state.
struct FailingFileSystem: FileSystem {
    func metadata(_ path: String) async throws -> FileMetadata? {
        throw FileSystemError.permissionDenied(path)
    }
    func list(_ path: String) async throws -> [FileEntry] {
        throw FileSystemError.permissionDenied(path)
    }
    func canonicalize(_ path: String, allowMissing: Bool) async throws -> String {
        path
    }
    func readData(_ path: String) async throws -> Data {
        throw FileSystemError.permissionDenied(path)
    }
    func writeData(_ data: Data, to path: String, append: Bool) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func touch(_ path: String) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func createDirectory(_ path: String, intermediates: Bool) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func remove(_ path: String, recursive: Bool) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func move(from: String, to destination: String) async throws {
        _ = destination
        throw FileSystemError.permissionDenied(from)
    }
    func copy(from: String, to destination: String) async throws {
        _ = destination
        throw FileSystemError.permissionDenied(from)
    }
}
