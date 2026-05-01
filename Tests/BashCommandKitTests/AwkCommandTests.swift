import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct AwkCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    private func awk(_ input: String, _ program: String,
                     extra: String = "") async throws -> String {
        let cap = makeShell()
        let cmd = "printf %s '\(input.replacingOccurrences(of: "'", with: "'\\''"))' | awk \(extra) '\(program.replacingOccurrences(of: "'", with: "'\\''"))'"
        try await cap.shell.run(cmd)
        return cap.stdout
    }

    // MARK: - Basics

    @Test func passthrough() async throws {
        let out = try await awk("a\nb\nc\n", "{ print }")
        #expect(out == "a\nb\nc\n")
    }

    @Test func defaultActionPrintsLine() async throws {
        let out = try await awk("a\nb\nc\n", "1")
        #expect(out == "a\nb\nc\n")
    }

    @Test func fieldAccess() async throws {
        let out = try await awk("hello world\n", "{ print $2 }")
        #expect(out == "world\n")
    }

    @Test func nfBuiltin() async throws {
        let out = try await awk("a b c d\n", "{ print NF }")
        #expect(out == "4\n")
    }

    @Test func nrBuiltin() async throws {
        let out = try await awk("a\nb\nc\n", "{ print NR, $0 }")
        #expect(out == "1 a\n2 b\n3 c\n")
    }

    @Test func dollarZeroIsWholeLine() async throws {
        let out = try await awk("hi  there\n", "{ print $0 }")
        #expect(out == "hi  there\n")
    }

    // MARK: - Patterns

    @Test func regexPattern() async throws {
        let out = try await awk("apple\nbanana\ncherry\n", "/an/")
        #expect(out == "banana\n")
    }

    @Test func notRegexPattern() async throws {
        let out = try await awk("apple\nbanana\ncherry\n", "$0 !~ /an/")
        #expect(out == "apple\ncherry\n")
    }

    @Test func numericComparison() async throws {
        let out = try await awk("1\n2\n3\n4\n5\n", "$0 > 2 { print }")
        #expect(out == "3\n4\n5\n")
    }

    @Test func rangePattern() async throws {
        let out = try await awk("a\nstart\nb\nc\nend\nd\n", "/start/,/end/")
        #expect(out == "start\nb\nc\nend\n")
    }

    // MARK: - Assignments / arithmetic

    @Test func arithmetic() async throws {
        let out = try await awk("1 2\n3 4\n", "{ print $1 + $2 }")
        #expect(out == "3\n7\n")
    }

    @Test func compoundAssignment() async throws {
        let out = try await awk("3\n", "{ x = 10; x += $1; print x }")
        #expect(out == "13\n")
    }

    @Test func powerOperator() async throws {
        let out = try await awk("", "BEGIN { print 2^10 }")
        #expect(out == "1024\n")
    }

    @Test func incrementOperators() async throws {
        let out = try await awk("", "BEGIN { x = 5; print x++, ++x, --x, x-- }")
        #expect(out == "5 7 6 6\n")
    }

    @Test func ternary() async throws {
        let out = try await awk("", "BEGIN { print 1 < 2 ? \"yes\" : \"no\" }")
        #expect(out == "yes\n")
    }

    @Test func stringConcat() async throws {
        let out = try await awk("", #"BEGIN { print "foo" "bar" }"#)
        #expect(out == "foobar\n")
    }

    // MARK: - Control flow

    @Test func ifElse() async throws {
        let out = try await awk("", "BEGIN { x = 5; if (x > 3) print \"big\"; else print \"small\" }")
        #expect(out == "big\n")
    }

    @Test func whileLoop() async throws {
        let out = try await awk("", "BEGIN { i=1; while (i<=3) { print i; i++ } }")
        #expect(out == "1\n2\n3\n")
    }

    @Test func forLoop() async throws {
        let out = try await awk("", "BEGIN { for (i=1; i<=3; i++) print i }")
        #expect(out == "1\n2\n3\n")
    }

    @Test func breakAndContinue() async throws {
        let out = try await awk("",
            "BEGIN { for (i=1; i<=10; i++) { if (i==3) continue; if (i>5) break; print i } }")
        #expect(out == "1\n2\n4\n5\n")
    }

    // MARK: - Arrays

    @Test func basicArray() async throws {
        let out = try await awk("a\nb\nc\n",
            "{ a[NR] = $0 } END { for (i=1; i<=NR; i++) print i, a[i] }")
        #expect(out == "1 a\n2 b\n3 c\n")
    }

    @Test func forIn() async throws {
        let out = try await awk("",
            "BEGIN { a[\"x\"]=1; a[\"y\"]=2; for (k in a) sum += a[k]; print sum }")
        #expect(out == "3\n")
    }

    @Test func multiDimArray() async throws {
        let out = try await awk("",
            "BEGIN { a[1,2]=\"X\"; a[1,3]=\"Y\"; print a[1,2], a[1,3] }")
        #expect(out == "X Y\n")
    }

    @Test func deleteElement() async throws {
        let out = try await awk("",
            "BEGIN { a[\"x\"]=1; a[\"y\"]=2; delete a[\"x\"]; for (k in a) print k }")
        #expect(out == "y\n")
    }

    @Test func inOperator() async throws {
        let out = try await awk("",
            "BEGIN { a[\"x\"]=1; print (\"x\" in a), (\"y\" in a) }")
        #expect(out == "1 0\n")
    }

    // MARK: - Builtins

    @Test func length() async throws {
        let out = try await awk("hello\n", "{ print length($0) }")
        #expect(out == "5\n")
    }

    @Test func substr() async throws {
        let out = try await awk("", #"BEGIN { print substr("hello world", 7, 5) }"#)
        #expect(out == "world\n")
    }

    @Test func indexBuiltin() async throws {
        let out = try await awk("", #"BEGIN { print index("hello", "ll") }"#)
        #expect(out == "3\n")
    }

    @Test func splitBuiltin() async throws {
        let out = try await awk("",
            "BEGIN { n = split(\"a,b,c\", a, \",\"); print n, a[1], a[2], a[3] }")
        #expect(out == "3 a b c\n")
    }

    @Test func subBuiltin() async throws {
        let out = try await awk("foo bar foo\n", "{ sub(/foo/, \"X\"); print }")
        #expect(out == "X bar foo\n")
    }

    @Test func gsubBuiltin() async throws {
        let out = try await awk("foo bar foo\n", "{ gsub(/foo/, \"X\"); print }")
        #expect(out == "X bar X\n")
    }

    @Test func gensubBuiltin() async throws {
        // The replacement is `\2\1` — literal backslashes in the AWK
        // string source (otherwise `\2` would be interpreted as
        // octal char by the AWK lexer).
        let out = try await awk("",
            #"BEGIN { print gensub(/(.)(.)/, "\\2\\1", "g", "abcd") }"#)
        #expect(out == "badc\n")
    }

    @Test func matchBuiltin() async throws {
        let out = try await awk("",
            #"BEGIN { match("hello", /l+/); print RSTART, RLENGTH }"#)
        #expect(out == "3 2\n")
    }

    @Test func tolowerToupper() async throws {
        let out = try await awk("", #"BEGIN { print tolower("ABC"), toupper("abc") }"#)
        #expect(out == "abc ABC\n")
    }

    @Test func sprintfBuiltin() async throws {
        let out = try await awk("", #"BEGIN { print sprintf("%-10s|%5d", "hi", 42) }"#)
        #expect(out == "hi        |   42\n")
    }

    @Test func mathFunctions() async throws {
        let out = try await awk("", "BEGIN { print int(3.7), sqrt(16) }")
        #expect(out == "3 4\n")
    }

    // MARK: - printf

    @Test func printfFormat() async throws {
        let out = try await awk("", #"BEGIN { printf "%s = %d\n", "x", 42 }"#)
        #expect(out == "x = 42\n")
    }

    @Test func printfPadding() async throws {
        let out = try await awk("", #"BEGIN { printf "%05d\n", 42 }"#)
        #expect(out == "00042\n")
    }

    @Test func printfHex() async throws {
        let out = try await awk("", #"BEGIN { printf "%x\n", 255 }"#)
        #expect(out == "ff\n")
    }

    // MARK: - User-defined functions

    @Test func userFunction() async throws {
        let out = try await awk("",
            "function sq(n) { return n * n } BEGIN { print sq(7) }")
        #expect(out == "49\n")
    }

    @Test func recursiveFunction() async throws {
        let out = try await awk("",
            "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) } BEGIN { print fact(5) }")
        #expect(out == "120\n")
    }

    @Test func arrayPassedByReference() async throws {
        let out = try await awk("",
            "function fill(a) { a[\"x\"] = 42 } BEGIN { fill(arr); print arr[\"x\"] }")
        #expect(out == "42\n")
    }

    // MARK: - Field separator

    @Test func customFS() async throws {
        let out = try await awk("a,b,c\n", "{ print $2 }", extra: "-F,")
        #expect(out == "b\n")
    }

    @Test func dashVAssignment() async throws {
        let out = try await awk("", #"BEGIN { print x }"#, extra: "-v x=42")
        #expect(out == "42\n")
    }

    // MARK: - BEGIN / END

    @Test func beginAndEnd() async throws {
        let out = try await awk("a\nb\nc\n",
            #"BEGIN { print "start" } { count++ } END { print "end:", count }"#)
        #expect(out == "start\nend: 3\n")
    }

    // MARK: - next / exit

    @Test func nextSkipsRules() async throws {
        let out = try await awk("a\nb\nc\n",
            "/b/ { next } { print }")
        #expect(out == "a\nc\n")
    }

    @Test func exitTerminates() async throws {
        let out = try await awk("a\nb\nc\nd\n",
            "NR == 2 { exit } { print }")
        #expect(out == "a\n")
    }

    @Test func exitRunsEnd() async throws {
        let out = try await awk("a\nb\nc\n",
            #"NR == 2 { exit } { print } END { print "done" }"#)
        #expect(out == "a\ndone\n")
    }

    // MARK: - Getline

    @Test func getlineFromMain() async throws {
        // `next` is a keyword — use a different variable name.
        // Cycle 1: "a", getline → nxt="b". Cycle 2: lineIndex moved
        // to "c"; getline returns 0 at EOF and leaves nxt unchanged.
        let out = try await awk("a\nb\nc\n",
            "{ getline nxt; print $0, \"+\", nxt }")
        #expect(out == "a + b\nc + b\n")
    }

    // MARK: - Concat

    @Test func implicitConcat() async throws {
        let out = try await awk("",
            #"BEGIN { x = 3; y = 4; print "ans:" x+y }"#)
        #expect(out == "ans:7\n")
    }
}
#endif
