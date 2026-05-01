import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct VirtualBinFileSystemTests {

    // MARK: list /bin and /usr/bin

    @Test func lsBinShowsRegisteredFileShadowedCommands() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        // Out of the catalog only registered commands appear. Shell's
        // default registry includes echo (a /bin entry) and pwd
        // (a /bin entry) so both should be listed.
        let entries = try await shell.withCurrent {
            try await shell.fileSystem.list("/bin")
        }
        #expect(entries.contains("echo"))
        #expect(entries.contains("pwd"))
        // Pure shell built-ins like `cd` must NOT appear under /bin.
        #expect(!entries.contains("cd"))
        #expect(!entries.contains("export"))
    }

    @Test func lsBinIsSorted() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let entries = try await shell.withCurrent {
            try await shell.fileSystem.list("/bin")
        }
        #expect(entries == entries.sorted())
    }

    @Test func unregisteringHidesShadowEntry() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let before = try await shell.withCurrent {
            try await shell.fileSystem.list("/bin")
        }
        #expect(before.contains("echo"))
        shell.unregister("echo")
        let after = try await shell.withCurrent {
            try await shell.fileSystem.list("/bin")
        }
        #expect(!after.contains("echo"))
    }

    // MARK: stat /bin/<name>

    @Test func statShadowFileReportsExecutableMode() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let meta = try await shell.withCurrent {
            try await shell.fileSystem.metadata("/bin/echo")
        }
        #expect(meta != nil)
        #expect(meta?.kind == .file)
        #expect(meta?.mode == 0o755)
    }

    @Test func statUnregisteredShadowFileIsNil() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        // Catalog knows about /bin/cat, but our default registry
        // doesn't include `cat` — it's a kit command. So stat is nil.
        let meta = try await shell.withCurrent {
            try await shell.fileSystem.metadata("/bin/cat")
        }
        #expect(meta == nil)
    }

    @Test func statShadowDirectoryReportsDirectory() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let meta = try await shell.withCurrent {
            try await shell.fileSystem.metadata("/bin")
        }
        #expect(meta?.kind == .directory)
    }

    // MARK: read /bin/<name> returns a stub, not a real binary

    @Test func readShadowFileReturnsBuiltinMarker() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let data = try await shell.withCurrent {
            try await shell.fileSystem.readData("/bin/echo")
        }
        let s = String(decoding: data, as: UTF8.self)
        #expect(s == "swift-bash built-in command: echo\n")
    }

    // MARK: writes are rejected

    @Test func writeToShadowFileIsPermissionDenied() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        await #expect(throws: FileSystemError.self) {
            try await shell.withCurrent {
                try await shell.fileSystem.writeData(
                    Data("nope".utf8),
                    to: "/bin/echo",
                    append: false)
            }
        }
    }

    @Test func chmodShadowFileIsPermissionDenied() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        await #expect(throws: FileSystemError.self) {
            try await shell.withCurrent {
                try await shell.fileSystem.chmod("/bin/echo", mode: 0o777)
            }
        }
    }

    // MARK: pass-through behavior

    @Test func writingOutsideBinForwardsToBacking() async throws {
        let backing = InMemoryFileSystem()
        let shell = Shell(fileSystem: backing)
        try await shell.withCurrent {
            try await shell.fileSystem.writeData(
                Data("hi".utf8),
                to: "/note",
                append: false)
        }
        let raw = try await backing.readData("/note")
        #expect(String(decoding: raw, as: UTF8.self) == "hi")
    }

    // MARK: idempotent wrapping

    @Test func shellInitDoesNotDoubleWrap() {
        let inner = InMemoryFileSystem()
        let s1 = Shell(fileSystem: inner)
        // First wrap: s1.fileSystem is a VirtualBinFileSystem.
        #expect(s1.fileSystem is VirtualBinFileSystem)
        // Re-using the wrapped fs in another Shell must NOT double-wrap.
        let s2 = Shell(fileSystem: s1.fileSystem)
        guard let outer = s2.fileSystem as? VirtualBinFileSystem else {
            Issue.record("expected outer to be VirtualBinFileSystem")
            return
        }
        // Backing should be the original InMemory, not another wrapper.
        #expect(outer.backing is InMemoryFileSystem)
    }

    @Test func subshellCopyDoesNotDoubleWrap() {
        let s = Shell(fileSystem: InMemoryFileSystem())
        let sub = s.copy()
        guard let outer = sub.fileSystem as? VirtualBinFileSystem else {
            Issue.record("expected wrapper")
            return
        }
        #expect(outer.backing is InMemoryFileSystem)
    }
}
