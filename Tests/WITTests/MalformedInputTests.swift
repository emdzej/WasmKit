import Testing

@testable import WIT

/// Malformed WIT gets a diagnostic, and well-formed WIT is not cut short.
@Suite struct MalformedInputTests {
    @Test func textAfterABlockCommentIsParsed() throws {
        var lexer = Lexer(cursor: .init(input: "/* hello /* nested */ */ interface i {}\nworld w {}"))
        let ast = try SourceFileSyntax.parse(lexer: &lexer)
        #expect(ast.items.count == 2)
    }

    @Test func anUnterminatedBlockCommentIsAnError() throws {
        var lexer = Lexer(cursor: .init(input: "interface i {} /* never closed"))
        #expect(throws: (any Error).self) { try SourceFileSyntax.parse(lexer: &lexer) }
    }

    @Test func aVersionTooLargeForIntIsAnError() throws {
        var lexer = Lexer(cursor: .init(input: "99999999999999999999.0.0"))
        #expect(throws: (any Error).self) { try Version.parse(lexer: &lexer) }
    }

    @Test func discriminantsFollowTheCaseCount() {
        #expect(CanonicalABI.discriminantType(numberOfCases: 0) == .u8)
        #expect(CanonicalABI.discriminantType(numberOfCases: 256) == .u8)
        #expect(CanonicalABI.discriminantType(numberOfCases: 257) == .u16)
        #expect(CanonicalABI.discriminantType(numberOfCases: 65_536) == .u16)
        #expect(CanonicalABI.discriminantType(numberOfCases: 65_537) == .u32)
    }
}
