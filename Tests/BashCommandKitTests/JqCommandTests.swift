import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct JqCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    /// Helper: pipe `input` into `jq <filterArgs>`, return stdout.
    private func run(_ input: String, _ filter: String,
                     extraFlags: [String] = []) async throws -> String {
        let cap = makeShell()
        let argList = (extraFlags + [filter]).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        try await cap.shell.run("printf %s '\(input.replacingOccurrences(of: "'", with: "'\\''"))' | jq \(argList)")
        return cap.stdout
    }

    // MARK: - Basics

    @Test func identityFilter() async throws {
        let out = try await run("{\"a\":1}", ".")
        #expect(out == "{\n  \"a\": 1\n}\n")
    }

    @Test func fieldAccess() async throws {
        let out = try await run("{\"a\":1,\"b\":2}", ".a")
        #expect(out == "1\n")
    }

    @Test func nestedFieldAccess() async throws {
        let out = try await run("{\"a\":{\"b\":42}}", ".a.b")
        #expect(out == "42\n")
    }

    @Test func arrayIndex() async throws {
        let out = try await run("[10,20,30]", ".[1]")
        #expect(out == "20\n")
    }

    @Test func arrayIndexNegative() async throws {
        let out = try await run("[10,20,30]", ".[-1]")
        #expect(out == "30\n")
    }

    @Test func arraySlice() async throws {
        let out = try await run("[1,2,3,4,5]", ".[1:4]", extraFlags: ["-c"])
        #expect(out == "[2,3,4]\n")
    }

    @Test func iterate() async throws {
        let out = try await run("[1,2,3]", ".[]")
        #expect(out == "1\n2\n3\n")
    }

    @Test func pipeAndArrayConstruction() async throws {
        let out = try await run("[1,2,3]", "[.[] | . * 2]", extraFlags: ["-c"])
        #expect(out == "[2,4,6]\n")
    }

    // MARK: - Compact / raw / sort-keys

    @Test func compactOutput() async throws {
        let out = try await run("{\"b\":2,\"a\":1}", ".", extraFlags: ["-c"])
        #expect(out == "{\"b\":2,\"a\":1}\n")
    }

    @Test func rawOutput() async throws {
        let out = try await run("\"hello\"", ".", extraFlags: ["-r"])
        #expect(out == "hello\n")
    }

    @Test func sortKeys() async throws {
        let out = try await run("{\"b\":2,\"a\":1}", ".", extraFlags: ["-cS"])
        #expect(out == "{\"a\":1,\"b\":2}\n")
    }

    // MARK: - Object construction

    @Test func objectConstruction() async throws {
        let out = try await run("{\"name\":\"alice\"}", "{n: .name}", extraFlags: ["-c"])
        #expect(out == "{\"n\":\"alice\"}\n")
    }

    @Test func objectShorthand() async throws {
        let out = try await run("{\"foo\":42}", "{foo}", extraFlags: ["-c"])
        #expect(out == "{\"foo\":42}\n")
    }

    // MARK: - Builtins

    @Test func length() async throws {
        let out = try await run("[1,2,3,4]", "length")
        #expect(out == "4\n")
    }

    @Test func keysSorted() async throws {
        let out = try await run("{\"b\":1,\"a\":2}", "keys", extraFlags: ["-c"])
        #expect(out == "[\"a\",\"b\"]\n")
    }

    @Test func keysUnsorted() async throws {
        let out = try await run("{\"b\":1,\"a\":2}", "keys_unsorted", extraFlags: ["-c"])
        #expect(out == "[\"b\",\"a\"]\n")
    }

    @Test func type() async throws {
        let out = try await run("[null,true,1,\"x\",[],{}]", "[.[] | type]", extraFlags: ["-c"])
        #expect(out == "[\"null\",\"boolean\",\"number\",\"string\",\"array\",\"object\"]\n")
    }

    @Test func sortAndUnique() async throws {
        let out = try await run("[3,1,2,1,3]", "sort | unique", extraFlags: ["-c"])
        #expect(out == "[1,2,3]\n")
    }

    @Test func mapDouble() async throws {
        let out = try await run("[1,2,3]", "map(. * 2)", extraFlags: ["-c"])
        #expect(out == "[2,4,6]\n")
    }

    @Test func selectFilter() async throws {
        let out = try await run("[1,2,3,4]", "[.[] | select(. > 2)]", extraFlags: ["-c"])
        #expect(out == "[3,4]\n")
    }

    @Test func add() async throws {
        let out = try await run("[1,2,3,4]", "add")
        #expect(out == "10\n")
    }

    @Test func toEntriesAndBack() async throws {
        let out = try await run("{\"a\":1,\"b\":2}", "to_entries | from_entries", extraFlags: ["-cS"])
        #expect(out == "{\"a\":1,\"b\":2}\n")
    }

    @Test func reduceSum() async throws {
        let out = try await run("[1,2,3,4]", "reduce .[] as $x (0; . + $x)")
        #expect(out == "10\n")
    }

    @Test func ifThenElse() async throws {
        let out = try await run("3", "if . > 2 then \"big\" else \"small\" end", extraFlags: ["-r"])
        #expect(out == "big\n")
    }

    @Test func variableBinding() async throws {
        let out = try await run("5", ". as $x | $x + $x")
        #expect(out == "10\n")
    }

    @Test func tryCatch() async throws {
        let out = try await run("null", "try (.a.b) catch \"oops\"", extraFlags: ["-r"])
        #expect(out == "null\n")
    }

    @Test func optionalSuffix() async throws {
        let out = try await run("1", ".foo?", extraFlags: ["-c"])
        #expect(out == "")
    }

    @Test func stringInterpolation() async throws {
        let out = try await run("{\"name\":\"world\"}", "\"hello \\(.name)\"", extraFlags: ["-r"])
        #expect(out == "hello world\n")
    }

    @Test func recurseDoubleDot() async throws {
        let out = try await run("[1,[2,[3]]]", "[..]", extraFlags: ["-c"])
        #expect(out == "[[1,[2,[3]]],1,[2,[3]],2,[3],3]\n")
    }

    @Test func updateAssignment() async throws {
        let out = try await run("{\"a\":1}", ".a = 5", extraFlags: ["-c"])
        #expect(out == "{\"a\":5}\n")
    }

    @Test func updatePipeAssignment() async throws {
        let out = try await run("{\"a\":1}", ".a |= . + 10", extraFlags: ["-c"])
        #expect(out == "{\"a\":11}\n")
    }

    @Test func delPath() async throws {
        let out = try await run("{\"a\":1,\"b\":2}", "del(.b)", extraFlags: ["-c"])
        #expect(out == "{\"a\":1}\n")
    }

    @Test func splitJoin() async throws {
        let out = try await run("\"a,b,c\"", "split(\",\") | join(\"|\")", extraFlags: ["-r"])
        #expect(out == "a|b|c\n")
    }

    @Test func ascii() async throws {
        let out = try await run("\"hello\"", "ascii_upcase", extraFlags: ["-r"])
        #expect(out == "HELLO\n")
    }

    @Test func contains() async throws {
        let out = try await run("[\"foobar\",\"foobaz\"]", "[.[] | contains(\"foo\")]", extraFlags: ["-c"])
        #expect(out == "[true,true]\n")
    }

    @Test func slurpMode() async throws {
        let out = try await run("1\n2\n3", ". | length", extraFlags: ["-s"])
        #expect(out == "3\n")
    }

    @Test func nullInputAndArg() async throws {
        let cap = makeShell()
        try await cap.shell.run("jq -n --arg name oliver '$name'")
        #expect(cap.stdout == "\"oliver\"\n")
    }

    @Test func nullInputAndArgjson() async throws {
        let cap = makeShell()
        try await cap.shell.run("jq -n --argjson n 42 '$n + 1'")
        #expect(cap.stdout == "43\n")
    }

    @Test func formatBase64() async throws {
        let out = try await run("\"hi\"", "@base64", extraFlags: ["-r"])
        #expect(out == "aGk=\n")
    }

    @Test func formatCsv() async throws {
        let out = try await run("[\"a\",\"b\",\"c,d\"]", "@csv", extraFlags: ["-r"])
        #expect(out == "a,b,\"c,d\"\n")
    }

    @Test func multipleOutputs() async throws {
        let out = try await run("[1,2,3]", ".[]")
        #expect(out == "1\n2\n3\n")
    }

    @Test func altOperator() async throws {
        let out = try await run("null", ". // \"default\"", extraFlags: ["-r"])
        #expect(out == "default\n")
    }

    @Test func notFunction() async throws {
        let out = try await run("true", "not")
        #expect(out == "false\n")
    }

    @Test func paths() async throws {
        let out = try await run("{\"a\":{\"b\":1}}", "[paths]", extraFlags: ["-c"])
        #expect(out == "[[\"a\"],[\"a\",\"b\"]]\n")
    }

    @Test func defFunction() async throws {
        let out = try await run("5", "def square: . * .; square")
        #expect(out == "25\n")
    }

    @Test func defWithArg() async throws {
        let out = try await run("3", "def add(n): . + n; add(7)")
        #expect(out == "10\n")
    }

    @Test func anyAll() async throws {
        let out = try await run("[true,false,true]", "[any, all]", extraFlags: ["-c"])
        #expect(out == "[true,false]\n")
    }

    @Test func minMax() async throws {
        let out = try await run("[3,1,4,1,5,9,2,6]", "[min, max]", extraFlags: ["-c"])
        #expect(out == "[1,9]\n")
    }

    @Test func reverseString() async throws {
        let out = try await run("[1,2,3]", "reverse", extraFlags: ["-c"])
        #expect(out == "[3,2,1]\n")
    }

    @Test func flatten() async throws {
        let out = try await run("[[1,2],[3,[4]]]", "flatten", extraFlags: ["-c"])
        #expect(out == "[1,2,3,4]\n")
    }

    @Test func range() async throws {
        let out = try await run("null", "[range(3)]", extraFlags: ["-c"])
        #expect(out == "[0,1,2]\n")
    }

    @Test func first() async throws {
        let out = try await run("[10,20,30]", "first")
        #expect(out == "10\n")
    }

    @Test func tostream() async throws {
        let out = try await run("{\"a\":1}", "[tostream]", extraFlags: ["-c"])
        // tostream emits leaf entries plus end markers
        #expect(out.contains("[\"a\"]"))
        #expect(out.contains("1"))
    }

    @Test func test_regex() async throws {
        let out = try await run("\"hello\"", "test(\"^h\")")
        #expect(out == "true\n")
    }

    @Test func gsubReplaces() async throws {
        let out = try await run("\"foo bar foo\"", "gsub(\"foo\"; \"x\")", extraFlags: ["-r"])
        #expect(out == "x bar x\n")
    }
}
