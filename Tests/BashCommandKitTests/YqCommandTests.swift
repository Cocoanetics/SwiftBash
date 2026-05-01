import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct YqCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func readScalarField() async throws {
        let cap = makeShell()
        let yaml = "name: alice\nage: 30\n"
        try await cap.shell.run("printf '\(yaml)' | yq -o json -c .name")
        #expect(cap.stdout == "\"alice\"\n")
    }

    @Test func readNumber() async throws {
        let cap = makeShell()
        let yaml = "name: alice\nage: 30\n"
        try await cap.shell.run("printf '\(yaml)' | yq -o json -c .age")
        #expect(cap.stdout == "30\n")
    }

    @Test func nestedMapping() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf 'a:\n  b:\n    c: hi\n' | yq -o json -c .a.b.c"#)
        #expect(cap.stdout == "\"hi\"\n")
    }

    @Test func blockSequence() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf 'items:\n  - one\n  - two\n  - three\n' | yq -o json -c '.items[1]'"#)
        #expect(cap.stdout == "\"two\"\n")
    }

    @Test func flowMapping() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf 'a: {x: 1, y: 2}\n' | yq -o json -c '.a.y'"#)
        #expect(cap.stdout == "2\n")
    }

    @Test func flowSequence() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf 'x: [10, 20, 30]\n' | yq -o json -c '.x[2]'"#)
        #expect(cap.stdout == "30\n")
    }

    @Test func emitYaml() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf 'a: 1\nb: 2\n' | yq ."#)
        #expect(cap.stdout.contains("a: 1"))
        #expect(cap.stdout.contains("b: 2"))
    }

    @Test func filterArray() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf '- a\n- b\n- c\n' | yq -o json -c '[.[] | select(. != "b")]'"#)
        #expect(cap.stdout == "[\"a\",\"c\"]\n")
    }
}
