import XCTest
@testable import BashSyntax

final class ParserTests: XCTestCase {

    // MARK: Helpers

    private func parse(_ s: String,
                       file: StaticString = #filePath, line: UInt = #line) -> Node {
        do {
            return try BashSyntax.parseSingle(s)
        } catch {
            XCTFail("parse failed: \(error)", file: file, line: line)
            return Node(kind: .command(parts: []), range: 0..<0)
        }
    }

    // MARK: Simple commands / pipelines / lists

    func testPipeline() async {
        let node = parse("cat file | grep foo | wc -l")
        guard case .pipeline(let parts) = node.kind else {
            return XCTFail("expected pipeline, got \(node.kindName)")
        }
        let kinds = parts.map(\.kindName)
        XCTAssertEqual(kinds, ["command", "pipe", "command", "pipe", "command"])
    }

    func testPipelineBarAnd() async {
        let node = parse("a |& b")
        guard case .pipeline(let parts) = node.kind else {
            return XCTFail()
        }
        if case .pipe(let p) = parts[1].kind { XCTAssertEqual(p, "|&") }
    }

    func testBang() async {
        let node = parse("! false")
        guard case .pipeline(let parts) = node.kind else {
            return XCTFail("expected pipeline with bang, got \(node.kindName)")
        }
        XCTAssertEqual(parts.first?.kindName, "reservedword")
    }

    func testSemicolonListSplitsCommands() async {
        let node = parse("a; b; c")
        guard case .list(let parts) = node.kind else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(parts.map(\.kindName),
                       ["command", "operator", "command", "operator", "command"])
    }

    func testAndOrChaining() async {
        let node = parse("a && b || c")
        guard case .list(let parts) = node.kind else {
            return XCTFail()
        }
        XCTAssertEqual(parts.map(\.kindName),
                       ["command", "operator", "command", "operator", "command"])
    }

    func testBackgroundedCommand() async {
        let node = parse("sleep 10 &")
        guard case .list(let parts) = node.kind else {
            return XCTFail("expected list, got \(node.kindName)")
        }
        XCTAssertEqual(parts.last?.kindName, "operator")
        if case .operator(let op) = parts.last!.kind {
            XCTAssertEqual(op, "&")
        }
    }

    // MARK: Assignments

    func testAssignment() async {
        let node = parse("FOO=bar echo $FOO")
        guard case .command(let parts) = node.kind else {
            return XCTFail()
        }
        XCTAssertEqual(parts[0].kindName, "assignment")
        if case .assignment(let w, _) = parts[0].kind {
            XCTAssertEqual(w, "FOO=bar")
        }
    }

    func testMultipleAssignments() async {
        let node = parse("A=1 B=2 C=3")
        guard case .command(let parts) = node.kind else {
            return XCTFail()
        }
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.kindName == "assignment" })
    }

    // MARK: Redirections

    func testSimpleRedirect() async {
        let node = parse("cat > out")
        guard case .command(let parts) = node.kind else { return XCTFail() }
        XCTAssertEqual(parts.last?.kindName, "redirect")
    }

    func testRedirectWithFD() async {
        let node = parse("cmd 2> err")
        guard case .command(let parts) = node.kind,
              let redir = parts.last,
              case .redirect(let input, let type, _, _) = redir.kind
        else { return XCTFail() }
        XCTAssertEqual(input, 2)
        XCTAssertEqual(type, ">")
    }

    func testDuplicateFDRedirect() async {
        let node = parse("cmd 2>&1")
        guard case .command(let parts) = node.kind,
              let redir = parts.last,
              case .redirect(_, let type, _, _) = redir.kind
        else { return XCTFail() }
        XCTAssertEqual(type, ">&")
    }

    func testAppendRedirect() async {
        let node = parse("echo hi >> log")
        guard case .command(let parts) = node.kind,
              let redir = parts.last,
              case .redirect(_, let type, _, _) = redir.kind
        else { return XCTFail() }
        XCTAssertEqual(type, ">>")
    }

    // MARK: Compound commands

    func testSubshell() async {
        let node = parse("(cd /tmp && ls)")
        guard case .compound = node.kind else {
            return XCTFail("expected compound, got \(node.kindName)")
        }
    }

    func testGroup() async {
        let node = parse("{ a; b; }")
        guard case .compound(let list, _) = node.kind else {
            return XCTFail("expected compound")
        }
        XCTAssertEqual(list.first?.kindName, "reservedword")
        XCTAssertEqual(list.last?.kindName, "reservedword")
    }

    func testIf() async {
        let node = parse("if true; then echo yes; else echo no; fi")
        guard case .compound(let list, _) = node.kind,
              let ifNode = list.first,
              case .ifCommand = ifNode.kind
        else {
            return XCTFail("expected compound(if), got \(node.kindName)")
        }
    }

    func testWhile() async {
        let node = parse("while true; do echo hi; done")
        guard case .compound(let list, _) = node.kind,
              let inner = list.first,
              case .whileCommand = inner.kind
        else { return XCTFail() }
    }

    func testUntil() async {
        let node = parse("until false; do echo hi; done")
        guard case .compound(let list, _) = node.kind,
              case .untilCommand = list.first?.kind
        else { return XCTFail() }
    }

    func testForIn() async {
        let node = parse("for x in a b c; do echo $x; done")
        guard case .compound(let list, _) = node.kind,
              case .forCommand(let parts) = list.first?.kind
        else { return XCTFail() }
        let kinds = parts.map(\.kindName)
        XCTAssertTrue(kinds.contains("reservedword"))
        XCTAssertTrue(kinds.contains("word"))
    }

    func testCase() async {
        let node = parse("case $x in a) echo a ;; b) echo b ;; esac")
        guard case .compound(let list, _) = node.kind,
              case .caseCommand = list.first?.kind
        else { return XCTFail() }
    }

    // MARK: Function definitions

    func testFunctionBareName() async {
        let node = parse("hello() { echo world; }")
        guard case .function(let name, _, _) = node.kind else {
            return XCTFail("expected function, got \(node.kindName)")
        }
        if case .word(let w, _) = name.kind { XCTAssertEqual(w, "hello") }
    }

    func testFunctionKeyword() async {
        let node = parse("function hello { echo world; }")
        guard case .function(let name, _, _) = node.kind else {
            return XCTFail("expected function, got \(node.kindName)")
        }
        if case .word(let w, _) = name.kind { XCTAssertEqual(w, "hello") }
    }

    // MARK: Substitutions inside words

    func testCommandSubstitutionExpands() async {
        let node = parse("echo $(date +%s)")
        guard case .command(let parts) = node.kind else { return XCTFail() }
        if case .word(_, let wordParts) = parts[1].kind {
            XCTAssertEqual(wordParts.count, 1)
            XCTAssertEqual(wordParts.first?.kindName, "commandsubstitution")
        } else {
            XCTFail("expected word with substitution child")
        }
    }

    func testProcessSubstitutionExpands() async {
        let node = parse("diff <(a) <(b)")
        guard case .command(let parts) = node.kind else { return XCTFail() }
        if case .word(_, let wordParts) = parts[1].kind {
            XCTAssertEqual(wordParts.first?.kindName, "processsubstitution")
        } else {
            XCTFail("expected word with process substitution child")
        }
    }

    func testVariableReference() async {
        let node = parse("echo $HOME")
        guard case .command(let parts) = node.kind else { return XCTFail() }
        if case .word(_, let wordParts) = parts[1].kind {
            XCTAssertEqual(wordParts.first?.kindName, "parameter")
            if case .parameter(let v) = wordParts.first?.kind {
                XCTAssertEqual(v, "HOME")
            }
        } else {
            XCTFail()
        }
    }

    func testParameterExpansion() async {
        let node = parse("echo ${foo:-bar}")
        guard case .command(let parts) = node.kind else { return XCTFail() }
        if case .word(_, let wordParts) = parts[1].kind {
            if case .parameter(let v) = wordParts.first?.kind {
                XCTAssertEqual(v, "foo:-bar")
            }
        } else {
            XCTFail()
        }
    }

    func testTildeExpansion() async {
        let node = parse("ls ~/bin")
        guard case .command(let parts) = node.kind else { return XCTFail() }
        if case .word(_, let wordParts) = parts[1].kind {
            XCTAssertEqual(wordParts.first?.kindName, "tilde")
            if case .tilde(let v) = wordParts.first?.kind {
                XCTAssertEqual(v, "~")
            }
        } else { XCTFail() }
    }

    func testNestedSubstitutions() async {
        let node = parse("echo $(echo $(echo inner))")
        guard case .command(let parts) = node.kind,
              case .word(_, let wordParts) = parts[1].kind,
              case .commandSubstitution(let inner) = wordParts.first?.kind
        else { return XCTFail() }
        if case .command(let innerParts) = inner.kind,
           case .word(_, let innerWordParts) = innerParts[1].kind
        {
            XCTAssertEqual(innerWordParts.first?.kindName, "commandsubstitution")
        } else {
            XCTFail("expected nested command substitution")
        }
    }

    // MARK: Parse returns multiple top-level parts

    func testMultipleTopLevel() async throws {
        let parts = try BashSyntax.parse("a\nb\nc")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.kindName == "command" })
    }

    // MARK: Position tracking

    func testRangesAreAccurate() async throws {
        let src = "echo hello"
        let node = try BashSyntax.parseSingle(src)
        XCTAssertEqual(node.range, 0..<10)
        XCTAssertEqual(node.source(from: src), "echo hello")
        if case .command(let parts) = node.kind {
            XCTAssertEqual(parts[0].range, 0..<4)
            XCTAssertEqual(parts[1].range, 5..<10)
        }
    }

    func testSubstitutionRangeMappedToOriginalSource() async throws {
        let src = "echo $(date)"
        let node = try BashSyntax.parseSingle(src)
        guard case .command(let parts) = node.kind,
              case .word(_, let wordParts) = parts[1].kind,
              case .commandSubstitution(let cmd) = wordParts.first?.kind
        else { return XCTFail() }
        // Inner body is positioned against the ORIGINAL source.
        XCTAssertEqual(cmd.source(from: src), "date")
    }

    // MARK: convertPositions dump

    func testDumpWithSource() async throws {
        let src = "echo hi"
        let node = try BashSyntax.parseSingle(src)
        let out = node.dump(source: src)
        XCTAssertTrue(out.contains("s='echo hi'"))
        XCTAssertTrue(out.contains("s='echo'"))
        XCTAssertTrue(out.contains("s='hi'"))
        XCTAssertFalse(out.contains("pos="))
    }

    // MARK: Visitor

    func testVisitorCountsCommands() async throws {
        struct Counter: NodeVisitor {
            var commandCount = 0
            mutating func visitCommand(_ node: Node, parts: [Node]) -> Bool {
                commandCount += 1
                return true
            }
        }
        let node = try BashSyntax.parseSingle("a && b | c || d")
        var v = Counter()
        node.walk(&v)
        XCTAssertEqual(v.commandCount, 4)
    }
}
