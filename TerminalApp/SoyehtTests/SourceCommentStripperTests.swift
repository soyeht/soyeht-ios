import Testing

/// Fixtures for the source-slice comment stripper. A forbidden token must be
/// SEEN in real code and NOT seen when it lives only inside a comment.
@Suite struct SourceCommentStripperTests {

    private let token = "FORBIDDEN"

    private func strip(_ s: String) -> String { SourceCommentStripper.strip(s) }

    @Test("token in a code line is seen")
    func codeLineSeen() {
        #expect(strip("let x = FORBIDDEN").contains(token))
    }

    @Test("token in a trailing // comment is not seen, but the code stays")
    func trailingLineCommentHidden() {
        let out = strip("let x = realCode // FORBIDDEN here")
        #expect(!out.contains(token))
        #expect(out.contains("realCode"))
    }

    @Test("token in a full // line is not seen")
    func fullLineCommentHidden() {
        #expect(!strip("    // FORBIDDEN note").contains(token))
    }

    @Test("token in an inline block comment is not seen, code around it stays")
    func inlineBlockCommentHidden() {
        let out = strip("let x = 1 /* FORBIDDEN */ + keepMe")
        #expect(!out.contains(token))
        #expect(out.contains("let x = 1"))
        #expect(out.contains("+ keepMe"))
    }

    @Test("token in a multi-line block comment is not seen")
    func multiLineBlockCommentHidden() {
        let src = """
        let a = 1
        /*
        FORBIDDEN
        still inside
        */
        let b = 2
        """
        let out = strip(src)
        #expect(!out.contains(token))
        #expect(out.contains("let a = 1"))
        #expect(out.contains("let b = 2"))
    }

    @Test("code after a block comment terminator is seen again")
    func codeAfterBlockSeen() {
        #expect(strip("/* note */ let y = FORBIDDEN").contains(token))
    }

    @Test("nested block comments are fully stripped")
    func nestedBlockHidden() {
        let out = strip("/* outer /* inner FORBIDDEN */ still outer */ let z = keepMe")
        #expect(!out.contains(token))
        #expect(out.contains("let z = keepMe"))
    }

    @Test("a block-open sequence inside a line comment does not start a block")
    func blockOpenInsideLineComment() {
        // The `/*` here is part of the line comment, so the next real line is code.
        let src = """
        // a /* not a real block FORBIDDEN
        let real = keepMe
        """
        let out = strip(src)
        #expect(!out.contains(token))
        #expect(out.contains("let real = keepMe"))
    }

    @Test("a line-comment sequence inside a block comment stays inside the block")
    func lineCommentInsideBlock() {
        #expect(!strip("/* // FORBIDDEN */").contains(token))
    }

    @Test("division and multiplication operators are not treated as comments")
    func operatorsArePreserved() {
        let out = strip("let r = a / b\nlet m = a * b")
        #expect(out.contains("a / b"))
        #expect(out.contains("a * b"))
    }
}
