import Testing
@testable import BashInterpreter

/// bash's dynamic `$RANDOM`: a fresh 0…32767 value per read, seeded by
/// assignment. It used to expand to the empty string.
@Suite(.timeLimit(.minutes(1))) struct RandomVariableTests {

    private func values(_ output: String) -> [Int] {
        output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    }

    @Test func eachReadIsAFreshValueInRange() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run("for i in 1 2 3 4 5 6 7 8; do echo $RANDOM; done")
        let read = values(cap.stdout)
        #expect(read.count == 8)
        #expect(read.allSatisfy { (0...32767).contains($0) })
        #expect(Set(read).count > 1)
    }

    @Test func bracedAndDefaultedFormsExpandToo() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run(#"echo "${RANDOM} ${RANDOM:-unset} ${#RANDOM}""#)
        let read = values(cap.stdout)
        #expect(read.count == 3)
        #expect(read.prefix(2).allSatisfy { (0...32767).contains($0) })
        #expect((1...5).contains(read[2]))
    }

    @Test func assignmentSeedsARepeatableSequence() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run(#"""
            RANDOM=42; a="$RANDOM $RANDOM $RANDOM"
            RANDOM=42; b="$RANDOM $RANDOM $RANDOM"
            [ "$a" = "$b" ] && echo same "$a"
            """#)
        #expect(cap.stdout.hasPrefix("same "))
        #expect(values(cap.stdout).count == 3)
    }

    @Test func seedsAreRepeatableAcrossShells() async throws {
        let first = CapturingShell()
        let second = CapturingShell()
        _ = try await first.shell.run("RANDOM=7; echo $RANDOM $RANDOM")
        _ = try await second.shell.run("RANDOM=7; echo $RANDOM $RANDOM")
        #expect(first.stdout == second.stdout)
        #expect(values(first.stdout).count == 2)
    }

    @Test func unseededShellsDiffer() async throws {
        // 8 draws from 32768 values each: identical runs would take a
        // ~2^-120 coincidence, i.e. a shared fixed seed.
        let first = CapturingShell()
        let second = CapturingShell()
        let script = "for i in 1 2 3 4 5 6 7 8; do echo $RANDOM; done"
        _ = try await first.shell.run(script)
        _ = try await second.shell.run(script)
        #expect(first.stdout != second.stdout)
    }

    @Test func arithmeticReadsAFreshValue() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run(#"""
            echo $((RANDOM % 1)) $(( RANDOM >= 0 && RANDOM <= 32767 ))
            RANDOM=3; x=$((RANDOM)); RANDOM=3; y=$((RANDOM)); [ "$x" = "$y" ] && echo seeded
            """#)
        #expect(cap.stdout == "0 1\nseeded\n")
    }

    @Test func subshellsReseedInsteadOfReplayingTheParent() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run("RANDOM=11; (echo $RANDOM $RANDOM); echo $RANDOM $RANDOM")
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first != lines.last)
        // The parent still gets its seeded sequence.
        let reference = CapturingShell()
        _ = try await reference.shell.run("RANDOM=11; echo $RANDOM $RANDOM")
        #expect(lines.last.map { $0 + "\n" } == reference.stdout)
    }

    @Test func unsetMakesItAnOrdinaryVariable() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run(#"unset RANDOM; echo "[$RANDOM]"; RANDOM=5; echo "$RANDOM $RANDOM""#)
        #expect(cap.stdout == "[]\n5 5\n")
    }

    @Test func staysOutOfTheEnvironment() async throws {
        // Bash doesn't export it, so `env` doesn't list it.
        let cap = CapturingShell()
        _ = try await cap.shell.run("x=$RANDOM; RANDOM=3; y=$RANDOM")
        #expect(cap.shell.environment.variables["RANDOM"] == nil)
    }

    @Test func separateSubshellsDiffer() async throws {
        let cap = CapturingShell()
        _ = try await cap.shell.run(
            "(for i in 1 2 3 4; do echo $RANDOM; done); echo ==; (for i in 1 2 3 4; do echo $RANDOM; done)")
        let halves = cap.stdout.components(separatedBy: "==\n")
        #expect(halves.count == 2)
        #expect(halves.first != halves.last)
    }
}
