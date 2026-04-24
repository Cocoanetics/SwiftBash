import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class StandardCommandsTests: XCTestCase {

    func testRegisterAllInOneCall() throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        for name in ["date", "basename", "dirname", "realpath",
                     "seq", "sleep", "env", "whoami", "hostname"]
        {
            XCTAssertNotNil(cap.shell.commands[name],
                "expected `\(name)` to be registered")
        }
    }

    func testIntegrationExample() throws {
        // Mini script exercising a handful of the shipped commands end-to-end.
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment["HOME"] = "/Users/oliver"

        try cap.shell.run("""
            FILE=/tmp/data/report.txt
            NAME=$(basename $FILE .txt)
            DIR=$(dirname $FILE)
            echo "name=$NAME"
            echo "dir=$DIR"
            echo "sum=$(seq -s , 5)"
            """)

        XCTAssertEqual(cap.stdout,
                       "name=report\ndir=/tmp/data\nsum=1,2,3,4,5\n")
    }
}
