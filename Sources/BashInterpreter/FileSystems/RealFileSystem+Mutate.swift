import Foundation

extension RealFileSystem {

    // MARK: Directories

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws {
        do {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: intermediates)
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            throw FileSystemError.alreadyExists(path)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        } catch {
            throw FileSystemError.io(
                "mkdir \(path) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Removal / move / copy

    public func remove(_ path: String, recursive: Bool) async throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(path)
        }
        if isDir.boolValue && !recursive {
            // Match POSIX `rmdir` semantics: only remove if empty.
            let entries = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            if !entries.isEmpty {
                throw FileSystemError.isADirectory(path)
            }
        }
        do {
            try fileManager.removeItem(atPath: path)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        }
    }

    // `to:` matches the FileSystem protocol's public signature.
    // swiftlint:disable:next identifier_name
    public func move(from: String, to: String) async throws {
        do {
            try fileManager.moveItem(atPath: from, toPath: to)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(from)
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            throw FileSystemError.alreadyExists(to)
        } catch {
            throw FileSystemError.io(
                "mv \(from) \(to) failed: \(error.localizedDescription)")
        }
    }

    // `to:` matches the FileSystem protocol's public signature.
    // swiftlint:disable:next identifier_name
    public func copy(from: String, to: String) async throws {
        do {
            try fileManager.copyItem(atPath: from, toPath: to)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(from)
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            throw FileSystemError.alreadyExists(to)
        } catch {
            throw FileSystemError.io(
                "cp \(from) \(to) failed: \(error.localizedDescription)")
        }
    }
}
