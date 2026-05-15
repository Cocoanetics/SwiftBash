import Foundation

extension RealFileSystem {

    // MARK: Reading

    public func readData(_ path: String) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let error as NSError where error.code == NSFileReadInapplicableStringEncodingError {
            throw FileSystemError.isADirectory(path)
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        }
    }

    public func openRead(_ path: String) async throws -> InputSource {
        // True streaming: feed 64 KB chunks into an AsyncStream from a
        // background read on a FileHandle.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError
                                    || error.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        }

        let stream = AsyncStream<Data> { continuation in
            Task.detached {
                let chunkSize = 64 * 1024
                while !Task.isCancelled {
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                try? handle.close()
                continuation.finish()
            }
        }
        return InputSource(bytes: stream)
    }

    // MARK: Writing

    public func writeData(_ data: Data, to path: String, append: Bool) async throws {
        let url = URL(fileURLWithPath: path)
        if !append {
            do {
                try data.write(to: url)
                return
            } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
                throw FileSystemError.permissionDenied(path)
            } catch let error as NSError where error.code == NSFileWriteFileExistsError {
                throw FileSystemError.alreadyExists(path)
            } catch {
                throw FileSystemError.io(
                    "write to \(path) failed: \(error.localizedDescription)")
            }
        }
        // Append mode.
        if !fileManager.fileExists(atPath: path) {
            _ = fileManager.createFile(atPath: path, contents: nil)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw FileSystemError.io(
                "open \(path) for append failed: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func openWrite(_ path: String, append: Bool) async throws -> OutputSink {
        // Prime the file (creates parent? no — caller's job) and open
        // a FileHandle for streaming writes.
        let url = URL(fileURLWithPath: path)
        if append {
            if !fileManager.fileExists(atPath: path) {
                if !fileManager.createFile(atPath: path, contents: nil) {
                    throw FileSystemError.io("could not create \(path)")
                }
            }
        } else {
            // Truncate by writing zero bytes.
            do {
                try Data().write(to: url)
            } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
                throw FileSystemError.permissionDenied(path)
            } catch {
                throw FileSystemError.io(
                    "open \(path) for write failed: \(error.localizedDescription)")
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw FileSystemError.io(
                "open \(path) for write failed: \(error.localizedDescription)")
        }
        if append { _ = try? handle.seekToEnd() }

        let handleBox = FileHandleBox(handle: handle)
        return OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { [handleBox] data in handleBox.write(data) },
            onFinish: { [handleBox] in handleBox.close() })
    }

    public func makeTempPath(prefix: String) async throws -> String {
        let dir = NSTemporaryDirectory() + "swift-bash"
        try? await createDirectory(dir, intermediates: true)
        return "\(dir)/\(prefix)-\(UUID().uuidString)"
    }

    public func touch(_ path: String) async throws {
        if !fileManager.fileExists(atPath: path) {
            if !fileManager.createFile(atPath: path, contents: Data()) {
                throw FileSystemError.io("could not create \(path)")
            }
            return
        }
        // Update mtime to now.
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }
}
