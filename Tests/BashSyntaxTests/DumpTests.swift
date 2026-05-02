import Testing
@testable import BashSyntax

/// Tests that lock down the exact format produced by `dump()`.
@Suite(.timeLimit(.minutes(1))) struct DumpTests {

    @Test func nestedSubstitutionsDumpExactly() throws {
        let node = try BashSyntax.parseSingle("true && cat <(echo $(echo foo))")
        let expected = """
        ListNode(pos=(0, 31), parts=[
          CommandNode(pos=(0, 4), parts=[
            WordNode(pos=(0, 4), word='true'),
          ]),
          OperatorNode(op='&&', pos=(5, 7)),
          CommandNode(pos=(8, 31), parts=[
            WordNode(pos=(8, 11), word='cat'),
            WordNode(pos=(12, 31), word='<(echo $(echo foo))', parts=[
              ProcesssubstitutionNode(command=
                CommandNode(pos=(14, 30), parts=[
                  WordNode(pos=(14, 18), word='echo'),
                  WordNode(pos=(19, 30), word='$(echo foo)', parts=[
                    CommandsubstitutionNode(command=
                      CommandNode(pos=(21, 29), parts=[
                        WordNode(pos=(21, 25), word='echo'),
                        WordNode(pos=(26, 29), word='foo'),
                      ]), pos=(19, 30)),
                  ]),
                ]), pos=(12, 31)),
            ]),
          ]),
        ])
        """
        #expect(node.dump() == expected)
    }

    @Test func simplePipelineDump() throws {
        let node = try BashSyntax.parseSingle("cat | wc")
        let expected = """
        PipelineNode(pos=(0, 8), parts=[
          CommandNode(pos=(0, 3), parts=[
            WordNode(pos=(0, 3), word='cat'),
          ]),
          PipeNode(pipe='|', pos=(4, 5)),
          CommandNode(pos=(6, 8), parts=[
            WordNode(pos=(6, 8), word='wc'),
          ]),
        ])
        """
        #expect(node.dump() == expected)
    }

    @Test func sourceDump() throws {
        let src = "echo hi"
        let node = try BashSyntax.parseSingle(src)
        let expected = """
        CommandNode(s='echo hi', parts=[
          WordNode(s='echo', word='echo'),
          WordNode(s='hi', word='hi'),
        ])
        """
        #expect(node.dump(source: src) == expected)
    }
}
