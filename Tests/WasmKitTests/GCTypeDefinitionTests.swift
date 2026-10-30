import Testing
import WAT
import WasmParser

@testable import WasmKit

/// Type definitions that GC allows but WasmKit cannot give their meaning yet are rejected, rather
/// than treated as plain function types: see `TypeCanonicalizer`.
@Suite
struct GCTypeDefinitionTests {
    func instantiate(_ wat: String, features: WasmFeatureSet = [.gc]) throws {
        let features = WasmFeatureSet.default.union(features)
        let module = try parseWasm(bytes: wat2wasm(wat, features: features), features: features)
        _ = try module.instantiate(store: Store(engine: Engine()))
    }

    func expectRejected(_ wat: String, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try instantiate(wat)
            Issue.record("instantiated, expected \(message)", sourceLocation: sourceLocation)
        } catch {
            #expect("\(error)".contains(message), "\(error)", sourceLocation: sourceLocation)
        }
    }

    @Test
    func typesWithoutRecursionOrSubtyping() throws {
        try instantiate("(module (rec (type (func))) (type (sub final (func (param i32)))) (type (func)))")
        // Types are still canonical by signature across definitions.
        try instantiate(
            """
            (module
              (type $a (func))
              (rec (type $b (func)))
              (table 1 funcref)
              (elem (i32.const 0) $f)
              (func $f (type $a))
              (func (export "call") (call_indirect (type $b) (i32.const 0)))
            )
            """)
    }

    /// `$a` and `$b` are distinct types, which WasmKit would make one.
    @Test
    func recursionGroupsOfSeveralTypes() {
        expectRejected("(module (rec (type $a (func)) (type $b (func))))", "recursion groups of more than one type")
    }

    /// A type that is not final differs from a final type with its signature.
    @Test
    func subtypeDeclarations() {
        expectRejected("(module (type (sub (func))))", "subtype declarations")
        expectRejected("(module (type $a (sub (func))) (type (sub final $a (func))))", "subtype declarations")
    }

    @Test
    func typesReferringToThemselves() {
        expectRejected("(module (type $t (func (param (ref null $t)))))", "recursive types")
    }
}
