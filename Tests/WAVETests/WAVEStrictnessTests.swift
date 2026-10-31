#if ComponentModel
    import ComponentModel
    import Testing
    import WAVE

    /// Text that names no value of the type is rejected, and printed floats read back exactly.
    @Suite
    struct WAVEStrictnessTests {
        private func parse(_ text: String, as type: ComponentDefValType) throws -> ComponentValue {
            var parser = WAVEParser(text)
            // Every type here is written inline, so nothing needs resolving.
            return try parser.parse(type: type) { index throws(WAVEParserError) in
                throw WAVEParserError("unexpected type index \(index)", span: SourceSpan(start: 0, end: 0))
            }
        }

        @Test func aRepeatedRecordFieldIsRejected() throws {
            let type = ComponentDefValType.record([ComponentRecordField(name: "a", type: .primitive(.u32))])
            _ = try parse("{a: 1}", as: type)
            #expect(throws: WAVEParserError.self) { _ = try parse("{a: 1, a: 2}", as: type) }
        }

        @Test func aResultCaseWithAPayloadTypeNeedsThePayload() throws {
            let type = ComponentDefValType.result(ok: .primitive(.u32), error: .primitive(.string))
            #expect(throws: WAVEParserError.self) { _ = try parse("ok", as: type) }
            #expect(throws: WAVEParserError.self) { _ = try parse("err", as: type) }
            _ = try parse("ok(1)", as: type)
            _ = try parse(#"err("x")"#, as: type)
        }

        @Test func mismatchedBracketsAreRejected() {
            var lexer = WAVELexer("(]")
            _ = try? lexer.next()
            #expect(throws: (any Error).self) { _ = try lexer.scanToCloseParen() }
        }

        @Test(arguments: [0.30000000000000004, 0.1, 1.0 / 3.0, 123456.789])
        func aFloat64ReadsBackAsItself(value: Double) throws {
            let text = WAVEFormatter.format(.float64(value))
            guard case .float64(let parsed) = try parse(text, as: .primitive(.float64)) else {
                Issue.record("expected a float64 from \(text)")
                return
            }
            #expect(parsed == value)
        }

        @Test(arguments: [Float(0.1), 16_777_216, Float(1) / 3])
        func aFloat32ReadsBackAsItself(value: Float) throws {
            let text = WAVEFormatter.format(.float32(value))
            guard case .float32(let parsed) = try parse(text, as: .primitive(.float32)) else {
                Issue.record("expected a float32 from \(text)")
                return
            }
            #expect(parsed == value)
        }
    }
#endif
