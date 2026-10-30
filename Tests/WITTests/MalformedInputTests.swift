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

    /// The explainer's examples of valid labels, and an escaped keyword.
    @Test(arguments: ["a", "a-b-c", "a1-2-3", "A", "A-B-C", "A1-2-3", "a11-w0rds", "A11-4CR0NYMS", "m1x3d-4CR0NYMS", "%static"])
    func kebabCaseIdentifiersParse(_ name: String) throws {
        var lexer = Lexer(cursor: .init(input: name))
        _ = try Identifier.parse(lexer: &lexer)
    }

    /// Names that would give an empty or invalid Swift identifier, among others.
    @Test(arguments: ["%--", "a--b", "a-", "-a", "1-2-3", "aB", "Ab", "a-bC", "a_b", "%é"])
    func identifiersNotInKebabCaseAreErrors(_ name: String) throws {
        var lexer = Lexer(cursor: .init(input: name))
        #expect(throws: (any Error).self) { try Identifier.parse(lexer: &lexer) }
    }

    @Test func discriminantsFollowTheCaseCount() {
        #expect(CanonicalABI.discriminantType(numberOfCases: 0) == .u8)
        #expect(CanonicalABI.discriminantType(numberOfCases: 256) == .u8)
        #expect(CanonicalABI.discriminantType(numberOfCases: 257) == .u16)
        #expect(CanonicalABI.discriminantType(numberOfCases: 65_536) == .u16)
        #expect(CanonicalABI.discriminantType(numberOfCases: 65_537) == .u32)
    }
}
