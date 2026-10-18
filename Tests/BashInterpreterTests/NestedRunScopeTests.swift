import Testing
import Foundation
@testable import BashInterpreter

/// `eval`, `source` and trap bodies run nested inside the script. Only
/// the outermost run is the shell: `exit` there ends the script, the
/// EXIT trap fires once, and `break` reaches the enclosing loop. Before,
/// every nested run swallowed `exit` and fired the EXIT trap itself.
@Suite(.timeLimit(.minutes(1))) struct NestedRunScopeTests {

    private func makeShell(files: [String: String] = [:]) async throws -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        for (path, text) in files {
            try await cap.shell.fileSystem.writeData(
                Data(text.utf8), to: path, append: false)
        }
        return cap
    }

    // MARK: exit

    @Test func exitInsideEvalEndsTheScript() async throws {
        let cap = try await makeShell()
        let status = try await cap.shell.run("eval 'exit 3'; echo unreachable")
        #expect(cap.stdout == "")
        #expect(status == ExitStatus(3))
    }

    @Test func exitInsideASourcedFileEndsTheScript() async throws {
        let cap = try await makeShell(files: ["/lib.sh": "echo lib\nexit 4\n"])
        let status = try await cap.shell.run(". /lib.sh; echo unreachable")
        #expect(cap.stdout == "lib\n")
        #expect(status == ExitStatus(4))
    }

    @Test func exitInsideAnErrTrapExits() async throws {
        let cap = try await makeShell()
        let status = try await cap.shell.run(
            "trap 'echo in-err; exit 7' ERR; false; echo unreachable")
        #expect(cap.stdout == "in-err\n")
        #expect(status == ExitStatus(7))
    }

    @Test func exitInsideADebugTrapExits() async throws {
        let cap = try await makeShell()
        let status = try await cap.shell.run("trap 'exit 8' DEBUG; echo unreachable")
        #expect(cap.stdout == "")
        #expect(status == ExitStatus(8))
    }

    @Test func exitInsideASubshellsEvalOrTrapEndsTheSubshell() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            ( eval 'exit 3'; echo unreachable ); echo "eval st=$?"
            ( trap 'exit 7' ERR; false; echo unreachable ); echo "err st=$?"
            v=$(eval 'exit 4'; echo unreachable); echo "sub st=$? v=$v"
            """#)
        #expect(cap.stdout == "eval st=3\nerr st=7\nsub st=4 v=\n")
    }

    @Test func parentExitTrapDoesNotFireInSubshells() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            trap 'echo bye' EXIT
            ( eval 'echo in-group' ); v=$(eval 'echo in-sub'); echo "$v"
            """#)
        #expect(cap.stdout == "in-group\nin-sub\nbye\n")
    }

    // MARK: EXIT trap

    @Test func exitTrapFiresOnceAfterSourceAndEval() async throws {
        let cap = try await makeShell(files: ["/lib.sh": "echo lib\n"])
        try await cap.shell.run("""
            trap 'echo bye' EXIT
            . /lib.sh
            eval 'echo evaluated'
            echo end
            """)
        #expect(cap.stdout == "lib\nevaluated\nend\nbye\n")
    }

    @Test func interactiveShellFiresExitTrapOnlyOnExit() async throws {
        let cap = try await makeShell()
        cap.shell.interactive = true
        try await cap.shell.run("trap 'echo bye' EXIT")
        try await cap.shell.run("echo next")
        #expect(cap.stdout == "next\n")
        let status = try await cap.shell.run("exit 2")
        #expect(cap.stdout == "next\nbye\n")
        #expect(status == ExitStatus(2))
    }

    @Test func exitInsideTheExitTrapSetsTheStatus() async throws {
        let cap = try await makeShell()
        let status = try await cap.shell.run(
            "trap 'echo in-trap; exit 5' EXIT; exit 3")
        #expect(cap.stdout == "in-trap\n")
        #expect(status == ExitStatus(5))
    }

    // MARK: Traps in subshells and child shells

    @Test func aSubshellsOwnExitTrapFiresWhenItEnds() async throws {
        let cap = try await makeShell()
        cap.shell.installShellBuiltin(name: "capture") { _ in
            Shell.bashCurrent.stdout(await Shell.bashCurrent.stdin.readAllString())
            return .success
        }
        try await cap.shell.run(#"""
            ( trap 'echo group-exit' EXIT; echo group-body )
            v=$(trap 'echo sub-exit' EXIT; echo sub-body); echo "v=[$v]"
            { trap 'echo stage-exit' EXIT; echo stage-body; } | capture
            { trap 'echo job-exit' EXIT; echo job-body; } & wait
            ( trap 'exit 6' EXIT; exit 2 ); echo "st=$?"
            """#)
        #expect(cap.stdout == """
            group-body
            group-exit
            v=[sub-body
            sub-exit]
            stage-body
            stage-exit
            job-body
            job-exit
            st=6

            """)
    }

    @Test func subshellsDoNotRunTheParentsErrTrap() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            trap 'echo parent-err' ERR
            ( false; echo after ); echo end
            """#)
        #expect(cap.stdout == "after\nend\n")
    }

    @Test func aSubshellStillListsTheParentsTraps() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            trap 'echo bye' EXIT
            saved=$(trap -p EXIT); echo "$saved"
            ( trap - EXIT; echo "after reset: [$(trap -p EXIT)]" )
            """#)
        #expect(cap.stdout == "trap -- 'echo bye' EXIT\nafter reset: []\nbye\n")
    }

    @Test func aChildBashStartsWithoutTraps() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("""
            trap 'echo parent-exit' EXIT
            bash -c 'echo child'
            echo end
            """)
        #expect(cap.stdout == "child\nend\nparent-exit\n")
    }

    // MARK: break / continue

    @Test func evalBreakAndContinueReachTheEnclosingLoop() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("""
            for i in 1 2 3; do eval break; echo "never $i"; done
            for i in 1 2; do eval continue; echo "never $i"; done
            echo after
            """)
        #expect(cap.stdout == "after\n")
        #expect(cap.stderr == "")
    }

    @Test func sourcedBreakEndsTheEnclosingLoop() async throws {
        let cap = try await makeShell(files: ["/brk.sh": "break\n"])
        try await cap.shell.run(
            #"for i in 1 2 3; do . /brk.sh; echo "never $i"; done; echo after"#)
        #expect(cap.stdout == "after\n")
        #expect(cap.stderr == "")
    }

    @Test func breakInAFunctionLeavesTheCallersLoopAlone() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            g() { break; echo "g continues"; }
            for i in 1 2; do g; echo "loop $i"; done
            """#)
        #expect(cap.stdout == "g continues\nloop 1\ng continues\nloop 2\n")
        #expect(cap.stderr.components(separatedBy: "only meaningful").count == 3)
    }

    @Test func breakOutsideALoopWarnsAndContinues() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"break; echo "st=$?""#)
        #expect(cap.stdout == "st=0\n")
        #expect(cap.stderr.contains("break: only meaningful"))
    }

    @Test func breakInASubshellGroupWarnsAndContinues() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"for i in 1 2; do (break; echo in); echo "loop $i"; done"#)
        #expect(cap.stdout == "in\nloop 1\nin\nloop 2\n")
    }
}
