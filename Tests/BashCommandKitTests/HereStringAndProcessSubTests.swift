import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct HereStringAndProcessSubTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: <<< here-strings

    @Test func hereStringFeedsBodyAsStdin() async throws {
        let cap = makeShell()
        try await cap.shell.run("cat <<< hello")
        #expect(cap.stdout == "hello\n")
    }

    @Test func hereStringExpandsVariables() async throws {
        let cap = makeShell()
        cap.shell.environment["NAME"] = "world"
        try await cap.shell.run(#"cat <<< "hello $NAME""#)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func hereStringInPipeline() async throws {
        let cap = makeShell()
        try await cap.shell.run("grep o <<< 'hello world'")
        #expect(cap.stdout == "hello world\n")
    }

    @Test func hereStringWithCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"cat <<< $(echo computed)"#)
        #expect(cap.stdout == "computed\n")
    }

    // MARK: <(cmd) input process substitution

    @Test func inputProcessSubstitutionGivesPath() async throws {
        // The argv that `cat` sees is the temp path; `cat` opens it and
        // dumps the captured bytes.
        let cap = makeShell()
        try await cap.shell.run("cat <(echo first)")
        #expect(cap.stdout == "first\n")
    }

    @Test func twoInputSubstitutionsBothWork() async throws {
        let cap = makeShell()
        cap.shell.register(name: "twocat") { argv in
            for path in argv.dropFirst() {
                let data = try await Shell.bashCurrent.fileSystem.readData(
                    Shell.bashCurrent.resolvePath(path))
                Shell.bashCurrent.stdout(data)
            }
            return .success
        }
        try await cap.shell.run("twocat <(echo a) <(echo b)")
        #expect(cap.stdout == "a\nb\n")
    }

    @Test func inputSubstitutionCleansUp() async throws {
        // After the command finishes, the temp file is removed.
        let cap = makeShell()
        cap.shell.register(name: "echopath") { argv in
            Shell.bashCurrent.stdout(argv.dropFirst().joined(separator: " ") + "\n")
            return .success
        }
        try await cap.shell.run("echopath <(echo gone)")
        // Capture the path that was substituted.
        let printed = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // It must not still exist on the FS.
        #expect(try await cap.shell.fileSystem.metadata(printed) == nil,
                "temp file should be removed after the outer command")
    }

    @Test func nestedInputSub() async throws {
        let cap = makeShell()
        try await cap.shell.run("cat <(cat <(echo deep))")
        #expect(cap.stdout == "deep\n")
    }

    // MARK: >(cmd) output process substitution

    @Test func outputProcessSubstitution() async throws {
        let cap = makeShell()
        // `echo > >(cat)`: echo writes its line to a temp path; after
        // it finishes, we read the temp and feed it to cat. Cat ends
        // up writing the same line back to the outer stdout.
        try await cap.shell.run("echo hello > >(cat)")
        #expect(cap.stdout == "hello\n")
    }

    @Test func outputSubAcrossChains() async throws {
        let cap = makeShell()
        // The consumer (`grep o`) only ever sees 'one' and 'two', not
        // 'three' (no 'o'). Outer command runs first, then consumer.
        try await cap.shell.run("""
            { echo one; echo two; echo three; } > >(grep o)
            """)
        #expect(cap.stdout == "one\ntwo\n")
    }

    @Test func outputSubCleansUp() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo hi > >(cat)")
        // /tmp/swift-bash directory may exist (we made it) but no
        // procsub-out-* leftovers should remain.
        let entries = ((try? await cap.shell.fileSystem.list(
            "/tmp/swift-bash")) ?? []).map(\.name)
        let leftovers = entries.filter { $0.hasPrefix("procsub-out-") }
        #expect(leftovers.isEmpty,
                "temp file should be cleaned up: \(leftovers)")
    }

    // MARK: Mix

    @Test func diffStylePattern() async throws {
        let cap = makeShell()
        // Synthetic diff that just concatenates two captured streams.
        cap.shell.register(name: "join") { argv in
            for path in argv.dropFirst() {
                let data = try await Shell.bashCurrent.fileSystem.readData(
                    Shell.bashCurrent.resolvePath(path))
                Shell.bashCurrent.stdout(data)
            }
            return .success
        }
        try await cap.shell.run("join <(echo left) <(echo right)")
        #expect(cap.stdout == "left\nright\n")
    }
}
