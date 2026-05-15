import Foundation
@testable import BashInterpreter

/// Shared helpers for `SandboxedOverlayFileSystemTests` and its
/// sibling suite `SandboxedOverlayFileSystemSecurityTests`. Each suite
/// is independent under swift-testing, but they all want the same
/// scratch-dir / `makeFs` boilerplate.
enum SandboxedOverlayTestHelpers {
    static func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("sbx-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func makeFs(
        root: String,
        mountPoint: String = "/batch",
        readOnly: Bool = false,
        allowSymlinks: Bool = false,
        includeTmpScratch: Bool = true,
        maxFileReadSize: Int64 = 10 * 1024 * 1024
    ) throws -> SandboxedOverlayFileSystem {
        try SandboxedOverlayFileSystem(.init(
            root: root,
            mountPoint: mountPoint,
            readOnly: readOnly,
            maxFileReadSize: maxFileReadSize,
            allowSymlinks: allowSymlinks,
            includeTmpScratch: includeTmpScratch))
    }
}
