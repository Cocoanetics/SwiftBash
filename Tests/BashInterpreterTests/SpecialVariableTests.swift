import Testing
import Foundation
@testable import BashInterpreter

/// Bash's special and dynamic variables beyond `$RANDOM` (see
/// `RandomVariableTests`). `$-` used to abort the script with "bad
/// parameter body"; the others expanded to nothing, or, for `$_`, to
/// whatever the host environment held.
@Suite(.timeLimit(.minutes(1))) struct SpecialVariableTests {

    private func makeShell(files: [String: String] = [:]) async throws -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        cap.shell.installShellBuiltin(name: "capture") { _ in
            Shell.bashCurrent.stdout(await Shell.bashCurrent.stdin.readAllString())
            return .success
        }
        for (path, text) in files {
            try await cap.shell.fileSystem.writeData(
                Data(text.utf8), to: path, append: false)
        }
        return cap
    }

    // MARK: $-

    @Test func dashListsTheOptionFlags() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo "$-"
            set -eu; echo "${-}"; set +eu
            case $- in *i*) echo interactive;; *) echo script;; esac
            """#)
        #expect(cap.stdout == "hB\nehuB\nscript\n")
    }

    @Test func dashShowsACommandString() async throws {
        let cap = try await makeShell(files: ["/s.sh": #"echo "script $-""# + "\n"])
        try await cap.shell.run(#"""
            bash -c 'echo "$-"; (echo "sub $-"); echo "$(echo "cs $-")"'
            bash -Cc 'echo "$-"'
            bash -c 'bash /s.sh; source /s.sh'
            echo "$-"
            """#)
        #expect(cap.stdout == """
            hBc
            sub hBc
            cs hBc
            hBCc
            script hB
            script hBc
            hB

            """)
    }

    @Test func dashShowsAnInteractiveShell() async throws {
        let cap = try await makeShell()
        cap.shell.interactive = true
        try await cap.shell.run("[[ $- == *i* ]] && echo interactive")
        #expect(cap.stdout == "interactive\n")
    }

    // MARK: $SECONDS

    @Test func secondsCountsFromStartOrAssignment() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo "$SECONDS"
            SECONDS=100; echo "$SECONDS $((SECONDS + 1))"
            SECONDS=abc; echo "$SECONDS"
            unset SECONDS; echo "[$SECONDS]"
            """#)
        #expect(cap.stdout == "0\n100 101\n0\n[]\n")
    }

    // MARK: $LINENO

    @Test func linenoFollowsTheScript() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo "a $LINENO"
            f() {
              echo "f $LINENO"
            }
            f
            eval 'echo "eval $LINENO"'
            for i in 1; do
              echo "loop $LINENO"
            done
            [[ $LINENO -eq 10 ]] && echo "cond ok"
            trap 'echo "err $LINENO"' ERR
            false
            """#)
        #expect(cap.stdout == "a 1\nf 3\neval 6\nloop 8\ncond ok\nerr 12\n")
    }

    /// Bash takes a simple command's line from where its second token
    /// ends (its first, for an assignment), so words that span lines
    /// move it; diagnostics use the same line.
    @Test func linenoOfACommandSpanningLines() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo "a
            $LINENO"
            echo \
              "b $LINENO"
            x="1
            2" echo "c $LINENO"
            a=$LINENO b="
            " c=$LINENO; echo "d $a $c"
            nosuch "
            "
            echo "e $((
            LINENO))"
            > /dev/stdout \
            echo "f $LINENO"
            """#)
        #expect(cap.stdout == "a\n2\nb 4\nc 6\nd 7 7\ne 12\nf 13\n")
        #expect(cap.stderr == "swift-bash: line 10: nosuch: command not found\n")
    }

    /// A command substitution's lines count on from the line of the
    /// command that runs it, in a word or in a heredoc body.
    @Test func linenoInCommandSubstitutionsAndHeredocs() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            true
            y=$(echo "a $LINENO"
            echo "b $LINENO")
            echo "$y"
            capture <<EOF
            c $LINENO
            d $(echo $LINENO)
            $(nosuch)
            EOF
            eval 'nosuch2'
            """#)
        #expect(cap.stdout == "a 3\nb 4\nc 5\nd 5\n\n")
        #expect(cap.stderr == """
            swift-bash: line 5: nosuch: command not found
            swift-bash: line 10: nosuch2: command not found

            """)
    }

    // MARK: FUNCNAME, BASH_SOURCE, BASH_LINENO

    @Test func callStackInAScript() async throws {
        let cap = try await makeShell(files: [
            "/lib.sh": #"""
                libfn() { echo "libfn: ${FUNCNAME[*]} | ${BASH_SOURCE[*]} | ${BASH_LINENO[*]}"; }
                echo "sourced: [${FUNCNAME[*]}] ${BASH_SOURCE[*]} | ${BASH_LINENO[*]}"

                """#
        ])
        cap.shell.scriptFile = "/work/main.sh"
        try await cap.shell.run(#"""
            f() { g; }
            g() { echo "g: ${FUNCNAME[*]} | ${BASH_SOURCE[*]} | ${BASH_LINENO[*]}"; }
            echo "top: [${FUNCNAME[*]}] ${BASH_SOURCE[*]} | ${BASH_LINENO[*]}"
            f
            . /lib.sh
            libfn
            echo "dir=${BASH_SOURCE[0]%/*}"
            """#)
        #expect(cap.stdout == """
            top: [] /work/main.sh | 0
            g: g f main | /work/main.sh /work/main.sh /work/main.sh | 1 4 0
            sourced: [] /lib.sh /work/main.sh | 5 0
            libfn: libfn main | /lib.sh /work/main.sh | 6 0
            dir=/work

            """)
    }

    @Test func callStackWithoutAScriptFile() async throws {
        // Like `bash -c`: no `main` frame.
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            f() { echo "f: ${FUNCNAME[*]} | ${BASH_SOURCE[*]} | ${BASH_LINENO[*]}"; }
            f
            echo "top: ${#FUNCNAME[@]} ${#BASH_SOURCE[@]} ${#BASH_LINENO[@]}"
            """#)
        #expect(cap.stdout == "f: f | environment | 2\ntop: 0 0 0\n")
    }

    @Test func sourceInsideAFunctionShowsInFuncname() async throws {
        let cap = try await makeShell(files: [
            "/lib.sh": #"echo "${FUNCNAME[*]} | ${BASH_LINENO[*]}""# + "\n"
        ])
        cap.shell.scriptFile = "/main.sh"
        try await cap.shell.run("""
            wrap() { . /lib.sh; }
            wrap
            """)
        #expect(cap.stdout == "source wrap main | 1 2 0\n")
    }

    @Test func unsetMakesThemOrdinary() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            unset LINENO FUNCNAME
            f() { echo "[${FUNCNAME[*]}] [$LINENO]"; }
            f
            """#)
        #expect(cap.stdout == "[] []\n")
    }

    // MARK: $_

    @Test func underscoreIsThePreviousCommandsLastArgument() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo a b c
            echo "$_"
            x=1
            echo "[$_]"
            f() { echo "in f: $_"; }
            f arg
            echo "after: $_"
            """#)
        #expect(cap.stdout == "a b c\nc\n[]\nin f: []\nafter: arg\n")
    }

    // MARK: $BASH_SUBSHELL, $BASHPID

    @Test func bashSubshellCountsSubshellLevels() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo $BASH_SUBSHELL
            ( echo $BASH_SUBSHELL; ( echo $BASH_SUBSHELL ) )
            echo $(echo $BASH_SUBSHELL)
            { echo $BASH_SUBSHELL; } & wait
            echo $BASH_SUBSHELL | capture
            { echo $BASH_SUBSHELL; } | capture
            f() { echo $BASH_SUBSHELL; }; f | capture
            """#)
        #expect(cap.stdout == "0\n1\n2\n1\n1\n0\n1\n1\n")
    }

    @Test func pipelineStagesThatRunShellCodeCountAsSubshells() async throws {
        let cap = try await makeShell(files: [
            "/lib.sh": #"echo "source $BASH_SUBSHELL""# + "\n"
        ])
        try await cap.shell.run(#"""
            f() { echo "fn $BASH_SUBSHELL"; }
            x=f; $x | capture
            eval f | capture
            source /lib.sh | capture
            echo "plain $BASH_SUBSHELL" | capture
            """#)
        #expect(cap.stdout == "fn 1\nfn 1\nsource 1\nplain 0\n")
    }

    @Test func linenoCountsTheShebangLine() async throws {
        let cap = try await makeShell(files: [
            "/script.sh": "#!/bin/bash\necho \"line $LINENO\"\n"
        ])
        try await cap.shell.run("bash /script.sh")
        #expect(cap.stdout == "line 2\n")
    }

    @Test func underscoreIsTheScriptsPathInsideIt() async throws {
        let cap = try await makeShell(files: ["/us.sh": #"echo "[$_]""# + "\n"])
        try await cap.shell.fileSystem.chmod("/us.sh", mode: 0o755)
        // Scripts dispatch only once some interpreter is registered; a
        // shebang-less script then runs as bash.
        cap.shell.registerScriptInterpreter(name: "unused") { _ in .success }
        try await cap.shell.run(": old; ./us.sh")
        #expect(cap.stdout == "[./us.sh]\n", "stderr: \(cap.stderr)")
    }

    @Test func bashpidDiffersInSubshells() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            [ "$BASHPID" = "$$" ] && echo shell
            ( [ "$BASHPID" != "$$" ] && echo subshell )
            [ "$(echo $BASHPID)" != "$$" ] && echo substitution
            """#)
        #expect(cap.stdout == "shell\nsubshell\nsubstitution\n")
    }

    // MARK: $UID, $EUID, $PPID

    @Test func identityVariables() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"echo "$UID $EUID $PPID"; [ "$EUID" -ne 0 ] && echo not-root"#)
        let uid = cap.shell.hostInfo.uid
        #expect(cap.stdout == "\(uid) \(uid) 0\n" + (uid != 0 ? "not-root\n" : ""))
    }

    @Test func dynamicVariablesStayOutOfTheEnvironment() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("x=$SECONDS$LINENO$BASHPID$BASH_SUBSHELL$UID")
        let leaked = ["SECONDS", "LINENO", "BASHPID", "BASH_SUBSHELL", "UID"]
            .filter { cap.shell.environment.variables[$0] != nil }
        #expect(leaked.isEmpty)
    }
}
