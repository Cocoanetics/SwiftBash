import Testing
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct SeqCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.install(SeqCommand.self)
        return cap
    }

    @Test func oneArg() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 3")
        #expect(cap.stdout == "1\n2\n3\n")
    }

    @Test func twoArgs() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 2 5")
        #expect(cap.stdout == "2\n3\n4\n5\n")
    }

    @Test func threeArgsIncrement() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 1 2 9")
        #expect(cap.stdout == "1\n3\n5\n7\n9\n")
    }

    @Test func descending() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 5 -1 1")
        #expect(cap.stdout == "5\n4\n3\n2\n1\n")
    }

    @Test func customSeparator() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq -s , 4")
        #expect(cap.stdout == "1,2,3,4\n")
    }

    @Test func emptySequenceIfRangeInverted() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 5 1")   // first > last with default step 1
        #expect(cap.stdout == "\n", "empty list plus trailing newline")
    }

    @Test func zeroIncrementFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("seq 1 0 10")
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("zero"), "\(cap.stderr)")
    }

    @Test func floatIncrement() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 1 0.5 2")
        #expect(cap.stdout == "1\n1.5\n2\n")
    }

    @Test func tooManyArgsFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("seq 1 2 3 4")
        #expect(!status.isSuccess)
    }

    @Test func commandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run("out=$(seq -s , 3); echo $out")
        #expect(cap.stdout == "1,2,3\n")
    }
}
