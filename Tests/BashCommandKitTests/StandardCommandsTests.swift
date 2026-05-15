import Testing
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct StandardCommandsTests {

    @Test func registerAllInOneCall() {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        for name in ["date", "basename", "dirname", "realpath",
                     "seq", "sleep", "env", "whoami", "hostname"] {
            #expect(cap.shell.commands[name] != nil,
                "expected `\(name)` to be registered")
        }
    }

    @Test func integrationExample() async throws {
        // Mini script exercising a handful of the shipped commands end-to-end.
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment["HOME"] = "/Users/oliver"

        try await cap.shell.run("""
            FILE=/tmp/data/report.txt
            NAME=$(basename $FILE .txt)
            DIR=$(dirname $FILE)
            echo "name=$NAME"
            echo "dir=$DIR"
            echo "sum=$(seq -s , 5)"
            """)

        #expect(cap.stdout == "name=report\ndir=/tmp/data\nsum=1,2,3,4,5\n")
    }
}
