import Testing
import WasmTypes

@testable import WasmParser

/// Encodings the spec rejects as malformed, which wasm-tools rejects too.
@Suite struct MalformedBinaryTests {
    private static let header: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

    private static func parseAll(_ sections: [UInt8], features: WasmFeatureSet = .all) throws {
        var parser = Parser(bytes: header + sections, features: features)
        while try parser.parseNext() != nil {}
    }

    @Test func elementSegmentFlagsAboveSevenAreRejected() {
        #expect(throws: WasmParserError.self) {
            try Self.parseAll([0x09, 0x07, 0x01, 0x08, 0x41, 0x00, 0x0B, 0x00, 0x00])
        }
    }

    /// The tag attribute, `try_table` catch kind and elemkind are single bytes, not LEB128.
    @Test func paddedSingleByteFieldsAreRejected() {
        #expect(throws: WasmParserError.self) {
            // A tag section whose attribute is `80 00`.
            try Self.parseAll([0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x0D, 0x04, 0x01, 0x80, 0x00, 0x00])
        }
        #expect(throws: WasmParserError.self) {
            // A passive element segment whose elemkind is `80 00`.
            try Self.parseAll([0x09, 0x05, 0x01, 0x01, 0x80, 0x00, 0x00])
        }
    }

    @Test func sharedTablesAreRejected() {
        #expect(throws: WasmParserError.self) {
            try Self.parseAll([0x04, 0x05, 0x01, 0x70, 0x03, 0x01, 0x01])
        }
    }

    /// A name subsection's content must fill its declared size exactly.
    @Test func trailingBytesInANameSubsectionAreRejected() throws {
        var names = NameSectionParser(stream: StaticByteStreamSource(bytes: [0x00, 0x05, 0x01, 0x61, 0x01, 0x02, 0x00]))
        #expect(throws: WasmParserError.self) { _ = try names.parseAll() }

        var exact = NameSectionParser(stream: StaticByteStreamSource(bytes: [0x00, 0x02, 0x01, 0x61]))
        let parsed = try exact.parseAll()
        guard case .moduleName("a") = parsed.first else {
            Issue.record("expected the module name, got \(parsed)")
            return
        }
    }
}
