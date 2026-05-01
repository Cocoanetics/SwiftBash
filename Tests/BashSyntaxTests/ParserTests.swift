import Testing
@testable import BashSyntax

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct ParserTests {

    // MARK: Helpers

    private func parse(_ s: String,
                       sourceLocation: SourceLocation = #_sourceLocation) -> Node {
        do {
            return try BashSyntax.parseSingle(s)
        } catch {
            Issue.record("parse failed: \(error)", sourceLocation: sourceLocation)
            return Node(kind: .command(parts: []), range: 0..<0)
        }
    }

    // MARK: Simple commands / pipelines / lists

    @Test func pipeline() {
        let node = parse("cat file | grep foo | wc -l")
        guard case .pipeline(let parts) = node.kind else {
            Issue.record("expected pipeline, got \(node.kindName)")
            return
        }
        let kinds = parts.map(\.kindName)
        #expect(kinds == ["command", "pipe", "command", "pipe", "command"])
    }

    @Test func pipelineBarAnd() {
        let node = parse("a |& b")
        guard case .pipeline(let parts) = node.kind else {
            Issue.record("expected pipeline")
            return
        }
        if case .pipe(let p) = parts[1].kind { #expect(p == "|&") }
    }

    @Test func bang() {
        let node = parse("! false")
        guard case .pipeline(let parts) = node.kind else {
            Issue.record("expected pipeline with bang, got \(node.kindName)")
            return
        }
        #expect(parts.first?.kindName == "reservedword")
    }

    @Test func semicolonListSplitsCommands() {
        let node = parse("a; b; c")
        guard case .list(let parts) = node.kind else {
            Issue.record("expected list")
            return
        }
        #expect(parts.map(\.kindName)
                == ["command", "operator", "command", "operator", "command"])
    }

    @Test func andOrChaining() {
        let node = parse("a && b || c")
        guard case .list(let parts) = node.kind else {
            Issue.record("expected list")
            return
        }
        #expect(parts.map(\.kindName)
                == ["command", "operator", "command", "operator", "command"])
    }

    @Test func backgroundedCommand() {
        let node = parse("sleep 10 &")
        guard case .list(let parts) = node.kind else {
            Issue.record("expected list, got \(node.kindName)")
            return
        }
        #expect(parts.last?.kindName == "operator")
        if case .operator(let op) = parts.last!.kind {
            #expect(op == "&")
        }
    }

    // MARK: Assignments

    @Test func assignment() {
        let node = parse("FOO=bar echo $FOO")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        #expect(parts[0].kindName == "assignment")
        if case .assignment(let w, _) = parts[0].kind {
            #expect(w == "FOO=bar")
        }
    }

    @Test func multipleAssignments() {
        let node = parse("A=1 B=2 C=3")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.kindName == "assignment" })
    }

    // MARK: Redirections

    @Test func simpleRedirect() {
        let node = parse("cat > out")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        #expect(parts.last?.kindName == "redirect")
    }

    @Test func redirectWithFD() {
        let node = parse("cmd 2> err")
        guard case .command(let parts) = node.kind,
              let redir = parts.last,
              case .redirect(let input, let type, _, _) = redir.kind
        else {
            Issue.record("expected command with redirect")
            return
        }
        #expect(input == 2)
        #expect(type == ">")
    }

    @Test func duplicateFDRedirect() {
        let node = parse("cmd 2>&1")
        guard case .command(let parts) = node.kind,
              let redir = parts.last,
              case .redirect(_, let type, _, _) = redir.kind
        else {
            Issue.record("expected command with redirect")
            return
        }
        #expect(type == ">&")
    }

    @Test func appendRedirect() {
        let node = parse("echo hi >> log")
        guard case .command(let parts) = node.kind,
              let redir = parts.last,
              case .redirect(_, let type, _, _) = redir.kind
        else {
            Issue.record("expected command with redirect")
            return
        }
        #expect(type == ">>")
    }

    // MARK: Compound commands

    @Test func subshell() {
        let node = parse("(cd /tmp && ls)")
        guard case .compound = node.kind else {
            Issue.record("expected compound, got \(node.kindName)")
            return
        }
    }

    @Test func group() {
        let node = parse("{ a; b; }")
        guard case .compound(let list, _) = node.kind else {
            Issue.record("expected compound")
            return
        }
        #expect(list.first?.kindName == "reservedword")
        #expect(list.last?.kindName == "reservedword")
    }

    @Test func ifStatement() {
        let node = parse("if true; then echo yes; else echo no; fi")
        guard case .compound(let list, _) = node.kind,
              let ifNode = list.first,
              case .ifCommand = ifNode.kind
        else {
            Issue.record("expected compound(if), got \(node.kindName)")
            return
        }
    }

    @Test func whileLoop() {
        let node = parse("while true; do echo hi; done")
        guard case .compound(let list, _) = node.kind,
              let inner = list.first,
              case .whileCommand = inner.kind
        else {
            Issue.record("expected compound(while)")
            return
        }
    }

    @Test func untilLoop() {
        let node = parse("until false; do echo hi; done")
        guard case .compound(let list, _) = node.kind,
              case .untilCommand = list.first?.kind
        else {
            Issue.record("expected compound(until)")
            return
        }
    }

    @Test func forIn() {
        let node = parse("for x in a b c; do echo $x; done")
        guard case .compound(let list, _) = node.kind,
              case .forCommand(let parts) = list.first?.kind
        else {
            Issue.record("expected compound(for)")
            return
        }
        let kinds = parts.map(\.kindName)
        #expect(kinds.contains("reservedword"))
        #expect(kinds.contains("word"))
    }

    @Test func caseStatement() {
        let node = parse("case $x in a) echo a ;; b) echo b ;; esac")
        guard case .compound(let list, _) = node.kind,
              case .caseCommand = list.first?.kind
        else {
            Issue.record("expected compound(case)")
            return
        }
    }

    // MARK: Function definitions

    @Test func functionBareName() {
        let node = parse("hello() { echo world; }")
        guard case .function(let name, _, _) = node.kind else {
            Issue.record("expected function, got \(node.kindName)")
            return
        }
        if case .word(let w, _) = name.kind { #expect(w == "hello") }
    }

    @Test func functionKeyword() {
        let node = parse("function hello { echo world; }")
        guard case .function(let name, _, _) = node.kind else {
            Issue.record("expected function, got \(node.kindName)")
            return
        }
        if case .word(let w, _) = name.kind { #expect(w == "hello") }
    }

    // MARK: Substitutions inside words

    @Test func commandSubstitutionExpands() {
        let node = parse("echo $(date +%s)")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        if case .word(_, let wordParts) = parts[1].kind {
            #expect(wordParts.count == 1)
            #expect(wordParts.first?.kindName == "commandsubstitution")
        } else {
            Issue.record("expected word with substitution child")
        }
    }

    @Test func processSubstitutionExpands() {
        let node = parse("diff <(a) <(b)")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        if case .word(_, let wordParts) = parts[1].kind {
            #expect(wordParts.first?.kindName == "processsubstitution")
        } else {
            Issue.record("expected word with process substitution child")
        }
    }

    @Test func variableReference() {
        let node = parse("echo $HOME")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        if case .word(_, let wordParts) = parts[1].kind {
            #expect(wordParts.first?.kindName == "parameter")
            if case .parameter(let v) = wordParts.first?.kind {
                #expect(v == "HOME")
            }
        } else {
            Issue.record("expected word with parameter child")
        }
    }

    @Test func parameterExpansion() {
        let node = parse("echo ${foo:-bar}")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        if case .word(_, let wordParts) = parts[1].kind {
            if case .parameter(let v) = wordParts.first?.kind {
                #expect(v == "foo:-bar")
            }
        } else {
            Issue.record("expected word with parameter child")
        }
    }

    @Test func tildeExpansion() {
        let node = parse("ls ~/bin")
        guard case .command(let parts) = node.kind else {
            Issue.record("expected command")
            return
        }
        if case .word(_, let wordParts) = parts[1].kind {
            #expect(wordParts.first?.kindName == "tilde")
            if case .tilde(let v) = wordParts.first?.kind {
                #expect(v == "~")
            }
        } else {
            Issue.record("expected word with tilde child")
        }
    }

    @Test func nestedSubstitutions() {
        let node = parse("echo $(echo $(echo inner))")
        guard case .command(let parts) = node.kind,
              case .word(_, let wordParts) = parts[1].kind,
              case .commandSubstitution(let inner) = wordParts.first?.kind
        else {
            Issue.record("expected nested commandSubstitution")
            return
        }
        if case .command(let innerParts) = inner.kind,
           case .word(_, let innerWordParts) = innerParts[1].kind
        {
            #expect(innerWordParts.first?.kindName == "commandsubstitution")
        } else {
            Issue.record("expected nested command substitution")
        }
    }

    // MARK: Parse returns multiple top-level parts

    @Test func multipleTopLevel() throws {
        let parts = try BashSyntax.parse("a\nb\nc")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.kindName == "command" })
    }

    // MARK: Position tracking

    @Test func rangesAreAccurate() throws {
        let src = "echo hello"
        let node = try BashSyntax.parseSingle(src)
        #expect(node.range == 0..<10)
        #expect(node.source(from: src) == "echo hello")
        if case .command(let parts) = node.kind {
            #expect(parts[0].range == 0..<4)
            #expect(parts[1].range == 5..<10)
        }
    }

    @Test func substitutionRangeMappedToOriginalSource() throws {
        let src = "echo $(date)"
        let node = try BashSyntax.parseSingle(src)
        guard case .command(let parts) = node.kind,
              case .word(_, let wordParts) = parts[1].kind,
              case .commandSubstitution(let cmd) = wordParts.first?.kind
        else {
            Issue.record("expected commandSubstitution")
            return
        }
        // Inner body is positioned against the ORIGINAL source.
        #expect(cmd.source(from: src) == "date")
    }

    // MARK: convertPositions dump

    @Test func dumpWithSource() throws {
        let src = "echo hi"
        let node = try BashSyntax.parseSingle(src)
        let out = node.dump(source: src)
        #expect(out.contains("s='echo hi'"))
        #expect(out.contains("s='echo'"))
        #expect(out.contains("s='hi'"))
        #expect(!out.contains("pos="))
    }

    // MARK: Visitor

    @Test func visitorCountsCommands() throws {
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
        #expect(v.commandCount == 4)
    }
}
#endif
