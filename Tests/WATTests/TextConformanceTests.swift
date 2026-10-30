import Testing
import WasmParser

@testable import WAT

/// Text the spec accepts is encoded as the reference interpreter does, and text it rejects is
/// an error.
@Suite
struct TextConformanceTests {

    @Test(
        arguments: [
            // A folded `if` must have `(then ...)`; the next sibling used to become its body.
            #"(module (func (if (i32.const 1)) (nop)))"#,
            // A NaN payload takes the whole rest of its token.
            #"(module (func (f32.const nan:0x1zz) drop))"#,
            #"(module (func (f32.const nan:0x1.5) drop))"#,
            // `(;)` opens a nested comment without closing it, so this one never ends.
            #"(module (; (;) ;))"#,
            // An explicit `+` makes a literal signed.
            #"(module (func (i32.const +0xFFFFFFFF) drop))"#,
            #"(module (func (i64.const +0xFFFFFFFFFFFFFFFF) drop))"#,
            // A table use makes an element segment active, which needs an offset.
            #"(module (table 1 funcref) (func $f) (elem (table 0) func $f))"#,
        ]
    )
    func invalidTextIsRejected(source: String) {
        #expect(throws: (any Error).self) { _ = try wat2wasm(source) }
    }

    @Test(
        arguments: [
            #"(module (func (i32.const +0x7FFFFFFF) drop))"#,
            #"(module (func (i32.const 0xFFFFFFFF) drop))"#,
            #"(module (; (; nested ;) ;) (; ;))"#,
            // Named parameters on a function that also refers to its type.
            #"(module (type $t (func (param i32))) (func (type $t) (param $x i32) local.get $x drop))"#,
            // Canonically equivalent but different code points: two identifiers.
            #"(module (func $"\u{c5}") (func $"A\u{30a}"))"#,
        ]
    )
    func validTextIsAccepted(source: String) throws {
        _ = try wat2wasm(source)
    }

    private func names(_ source: String) throws -> [ParsedNames] {
        var parser = WasmParser.Parser(bytes: try wat2wasm(source, options: EncodeOptions(nameSection: true)))
        while let payload = try parser.parseNext() {
            guard case .customSection(let section) = payload, section.name == "name" else { continue }
            var names = NameSectionParser(stream: StaticByteStreamSource(bytes: Array(section.bytes)))
            return try names.parseAll()
        }
        return []
    }

    /// Locals are numbered after the parameters of the type a `$id` names.
    @Test func localNamesFollowTheParametersOfANamedType() throws {
        let parsed = try names(
            #"(module (type $a (func)) (type $b (func (param i32 i32))) (func (type $b) (local $x i32)))"#)
        let locals = parsed.compactMap { if case .locals(let map) = $0 { return map } else { return nil } }.first
        #expect(locals?[0]?[2] == "x")
        #expect(locals?[0]?[0] == nil)
    }

    /// A `try_table` label is numbered with the other block labels.
    @Test func tryTableLabelsAreNamed() throws {
        let parsed = try names(#"(module (func (block $a) (try_table $t) (block $b)))"#)
        let labels = parsed.compactMap { if case .labels(let map) = $0 { return map } else { return nil } }.first
        #expect(labels?[0] == [0: "a", 1: "t", 2: "b"])
    }
}
