import Testing
@testable import BashSyntax

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct SplitTests {

    @Test func basicSplit() throws {
        #expect(try BashSyntax.split("a b c") == ["a", "b", "c"])
    }

    @Test func operatorsAreEmittedLiterally() throws {
        #expect(try BashSyntax.split("ls | grep foo && echo")
                == ["ls", "|", "grep", "foo", "&&", "echo"])
    }

    @Test func singleQuotesRemoved() throws {
        #expect(try BashSyntax.split("echo 'hello world'")
                == ["echo", "hello world"])
    }

    @Test func doubleQuotesRemoved() throws {
        #expect(try BashSyntax.split(#"echo "hello world""#)
                == ["echo", "hello world"])
    }

    @Test func adjacentQuotedAndUnquotedConcatenate() throws {
        #expect(try BashSyntax.split(#"foo"bar"'baz'"#) == [#"foobarbaz"#])
    }

    @Test func commandSubstitutionPreserved() throws {
        #expect(try BashSyntax.split(#"echo $(date +%s)"#)
                == ["echo", "$(date +%s)"])
    }

    @Test func backticksPreserved() throws {
        #expect(try BashSyntax.split("echo `date +%s`")
                == ["echo", "`date +%s`"])
    }

    @Test func processSubstitutionPreserved() throws {
        #expect(try BashSyntax.split("diff <(a) <(b)")
                == ["diff", "<(a)", "<(b)"])
    }

    @Test func nestedCommandSubstitution() throws {
        #expect(try BashSyntax.split("echo $(echo $(echo deep))")
                == ["echo", "$(echo $(echo deep))"])
    }

    @Test func substitutionInsideDoubleQuotes() throws {
        #expect(try BashSyntax.split(#"echo "a $(b) c""#)
                == ["echo", "a $(b) c"])
    }

    @Test func substitutionInsideSingleQuotesIsLiteral() throws {
        #expect(try BashSyntax.split(#"echo 'a $(b) c'"#)
                == ["echo", "a $(b) c"])
    }

    @Test func redirectOperators() throws {
        #expect(try BashSyntax.split("cat > out 2>&1")
                == ["cat", ">", "out", "2", ">&", "1"])
    }

    @Test func ampersandBackgroundedCommand() throws {
        #expect(try BashSyntax.split("sleep 10 &") == ["sleep", "10", "&"])
    }
}
#endif
