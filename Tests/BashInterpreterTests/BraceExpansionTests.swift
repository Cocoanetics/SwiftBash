import Testing
@testable import BashInterpreter

@Suite struct BraceExpansionTests {

    @Test func listForm() {
        #expect(BraceExpansion.expand("{a,b,c}") == ["a", "b", "c"])
    }

    @Test func listFormWithPrefixAndSuffix() {
        #expect(BraceExpansion.expand("pre{x,y,z}post")
                == ["prexpost", "preypost", "prezpost"])
    }

    @Test func twoListsCartesianProduct() {
        #expect(BraceExpansion.expand("{1,2}{a,b}")
                == ["1a", "1b", "2a", "2b"])
    }

    @Test func numericRange() {
        #expect(BraceExpansion.expand("{1..5}")
                == ["1", "2", "3", "4", "5"])
    }

    @Test func numericRangeReverse() {
        #expect(BraceExpansion.expand("{5..1}")
                == ["5", "4", "3", "2", "1"])
    }

    @Test func numericRangeWithStep() {
        #expect(BraceExpansion.expand("{1..9..2}")
                == ["1", "3", "5", "7", "9"])
    }

    @Test func numericRangePadded() {
        #expect(BraceExpansion.expand("{01..05}")
                == ["01", "02", "03", "04", "05"])
    }

    @Test func charRange() {
        #expect(BraceExpansion.expand("{a..e}")
                == ["a", "b", "c", "d", "e"])
    }

    @Test func emptyBracesArePassThrough() {
        // No comma → not a real brace expansion. Bash leaves it alone.
        #expect(BraceExpansion.expand("a{b}c") == ["a{b}c"])
        #expect(BraceExpansion.expand("a{}b") == ["a{}b"])
    }

    @Test func unterminatedBraceIsLiteral() {
        #expect(BraceExpansion.expand("{abc") == ["{abc"])
    }

    @Test func nestedBraces() {
        // Outer expansion fires first; each result is then expanded.
        #expect(BraceExpansion.expand("{a,{b,c}}")
                == ["a", "b", "c"])
    }

    @Test func skipsLiteralBraceAndExpandsLater() {
        // First `{NoComma}` is a literal — must not infinite-loop;
        // second `{a,b}` still expands.
        #expect(BraceExpansion.expand("{x}.{a,b}")
                == ["{x}.a", "{x}.b"])
    }
}
