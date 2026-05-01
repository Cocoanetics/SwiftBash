import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct GetoptsCommandTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: Single-letter flags

    @Test func singleFlag() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "a" opt -a; do
                echo "$opt"
            done
            """)
        #expect(cap.stdout == "a\n")
    }

    @Test func unknownOptionDefaultMode() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "a" opt -x; do
                echo "$opt"
            done
            """)
        #expect(cap.stdout == "?\n")
        #expect(cap.stderr.contains("illegal option"))
    }

    @Test func unknownOptionSilentMode() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts ":a" opt -x; do
                echo "opt=$opt arg=$OPTARG"
            done
            """)
        #expect(cap.stdout == "opt=? arg=x\n")
        #expect(cap.stderr == "")
    }

    // MARK: Bundled flags

    @Test func bundledFlags() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "abc" opt -abc; do
                echo "$opt"
            done
            """)
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func mixedFlagsInSeparateArgs() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "abc" opt -a -b -c; do
                echo "$opt"
            done
            """)
        #expect(cap.stdout == "a\nb\nc\n")
    }

    // MARK: Options with arguments

    @Test func optionWithArgSeparate() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "b:" opt -b value; do
                echo "$opt=$OPTARG"
            done
            """)
        #expect(cap.stdout == "b=value\n")
    }

    @Test func optionWithArgGlued() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "b:" opt -bvalue; do
                echo "$opt=$OPTARG"
            done
            """)
        #expect(cap.stdout == "b=value\n")
    }

    @Test func missingArgDefaultMode() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "b:" opt -b; do
                echo "$opt"
            done
            """)
        #expect(cap.stdout == "?\n")
        #expect(cap.stderr.contains("requires an argument"))
    }

    @Test func missingArgSilentMode() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts ":b:" opt -b; do
                echo "opt=$opt arg=$OPTARG"
            done
            """)
        #expect(cap.stdout == "opt=: arg=b\n")
        #expect(cap.stderr == "")
    }

    // MARK: Termination

    @Test func dashDashEndsOptions() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "a" opt -a -- nope; do
                echo "$opt"
            done
            echo "OPTIND=$OPTIND"
            """)
        #expect(cap.stdout == "a\nOPTIND=3\n")
    }

    @Test func nonOptionEndsOptions() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "a" opt -a file.txt; do
                echo "$opt"
            done
            echo "OPTIND=$OPTIND"
            """)
        #expect(cap.stdout == "a\nOPTIND=2\n")
    }

    @Test func reachesEndCleanly() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts "abc" opt -a -b; do
                echo "$opt"
            done
            echo "done"
            """)
        #expect(cap.stdout == "a\nb\ndone\n")
    }

    // MARK: Real-world idiom — case dispatch

    @Test func caseDispatchKitchenSink() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            while getopts ":vf:o:" opt -v -f input.txt -o output.txt; do
                case "$opt" in
                    v) echo "verbose" ;;
                    f) echo "in=$OPTARG" ;;
                    o) echo "out=$OPTARG" ;;
                esac
            done
            """)
        #expect(cap.stdout == "verbose\nin=input.txt\nout=output.txt\n")
    }

    // MARK: Positional-parameters input

    @Test func usesPositionalParametersWhenNoArgs() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["-a", "-b", "value"]
        try await cap.shell.run("""
            while getopts "ab:" opt; do
                case "$opt" in
                    a) echo "got-a" ;;
                    b) echo "got-b $OPTARG" ;;
                esac
            done
            """)
        #expect(cap.stdout == "got-a\ngot-b value\n")
    }
}
