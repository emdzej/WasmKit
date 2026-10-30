import Testing
import WAT

@testable import WasmKit

@Suite
struct ExecutionTests {

    @Test
    func dropWithRelinkingOptimization() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (func (export "_start") (result i32) (local $x i32)
                        (i32.const 42)
                        (i32.const 0)
                        (i32.eqz)
                        (drop)
                        (local.set $x)
                        (local.get $x)
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try #require(instance.exports[function: "_start"])
        let results = try _start()
        #expect(results == [.i32(42)])
    }

    @Test
    func updateCurrentMemoryCacheOnGrow() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (memory 0)
                    (func (export "_start") (result i32)
                        (drop (memory.grow (i32.const 1)))
                        (i32.store (i32.const 1) (i32.const 42))
                        (i32.load (i32.const 1))
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try #require(instance.exports[function: "_start"])
        let results = try _start()
        #expect(results == [.i32(42)])
    }

    /// Calls the host makes reuse the stacks their store keeps, and a call made while another
    /// runs, from a host function, gets a stack of its own.
    @Test
    func callsReuseTheStoresStacks() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (import "host" "callback" (func $callback (param i32) (result i32)))
                    (func (export "f") (param i32) (result i32) (call $callback (local.get 0)))
                    (func (export "g") (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
                )
                """
            )
        )
        let store = Store(engine: Engine())
        var g: Function?
        let callback = Function(store: store, parameters: [.i32], results: [.i32]) { _, arguments in
            try g!(arguments)
        }
        let instance = try module.instantiate(store: store, imports: ["host": ["callback": callback]])
        g = instance.exports[function: "g"]
        let f = try #require(instance.exports[function: "f"])

        #expect(try f([.i32(1)]) == [.i32(2)])
        let first = try #require(store.executionStacks.take())
        let second = try #require(store.executionStacks.take())
        #expect(first != second)
        #expect(store.executionStacks.take() == nil)
        #expect(store.executionStacks.give(first))
        #expect(store.executionStacks.give(second))

        #expect(try f([.i32(41)]) == [.i32(42)])
        #expect(try g!([.i32(0)]) == [.i32(1)])
    }

    /// A raw host function that leaves a result unwritten, or writes one of another type, traps
    /// when called from Wasm as when called from the host, rather than crashing or storing
    /// placeholder bits as a reference.
    @Test(arguments: [ValueType.v128, .ref(.funcRef), .i64])
    func rawHostFunctionLeavingAResultUnwritten(_ type: ValueType) throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (import "host" "f" (func $f (result \(type))))
                    (func (export "call") (drop (call $f)))
                )
                """,
                features: [.simd, .referenceTypes]
            ),
            features: [.simd, .referenceTypes]
        )
        let store = Store(engine: Engine())
        // Writes nothing, except `.i32(1)` for an `i64` result.
        let host = Function(store: store, parameters: [], results: [type]) { _, _, results in
            if type == .i64 { results[0] = .i32(1) }
        }
        let instance = try module.instantiate(store: store, imports: ["host": ["f": host]])
        for call in [{ try instance.exports[function: "call"]!() }, { try host() }] {
            do {
                _ = try call()
                Issue.record("expected a trap")
            } catch let trap as Trap {
                #expect("\(trap.reason)".contains("result"), "\(trap.reason)")
            }
        }
    }

    /// Import and export names compare by code points, not by Unicode canonical equivalence:
    /// "\u{C5}" and "A\u{30A}" are both "Å", but different names.
    @Test
    func namesCompareByCodePoints() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (import "m" "\u{C5}" (func $a (result i32)))
                    (import "m" "A\u{30A}" (func $b (result i32)))
                    (func (export "\u{C5}") (result i32) (call $a))
                    (func (export "A\u{30A}") (result i32) (call $b))
                )
                """
            )
        )
        let store = Store(engine: Engine())
        func constant(_ value: Int32) -> Function {
            Function(store: store, parameters: [], results: [.i32]) { _, _ in [.i32(UInt32(bitPattern: value))] }
        }
        var imports = Imports()
        imports.define(module: "m", name: "\u{C5}", constant(1))
        imports.define(module: "m", name: "A\u{30A}", constant(2))
        let instance = try module.instantiate(store: store, imports: imports)
        #expect(try instance.exports[function: "\u{C5}"]?() == [.i32(1)])
        #expect(try instance.exports[function: "A\u{30A}"]?() == [.i32(2)])
        #expect(Array(instance.exports).count == 2)
    }

    /// A tail call to a host function moves the arguments over the caller's
    /// saved slots, and the host function's results have to reach the caller's
    /// caller.
    @Test
    func tailCallHostFunction() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (import "env" "sum5" (func $sum5 (param i64 i64 i64 i64 i64) (result i64)))
                    (func $tail (result i64)
                        (return_call $sum5
                            (i64.const 1) (i64.const 20) (i64.const 300) (i64.const 4000) (i64.const 50000)))
                    (func (export "_start") (param i64) (result i64)
                        (i64.add (call $tail) (local.get 0)))
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        imports.define(
            module: "env", name: "sum5",
            Function(store: store, parameters: Array(repeating: .i64, count: 5), results: [.i64]) { _, args in
                [.i64(args.reduce(0) { $0 + $1.i64 })]
            })
        let instance = try module.instantiate(store: store, imports: imports)
        let _start = try #require(instance.exports[function: "_start"])
        #expect(try _start([.i64(600000)]) == [.i64(654321)])
    }

    func expectTrap(_ wat: String, assertTrap: (Trap) throws -> Void) throws {
        let module = try parseWasm(
            bytes: wat2wasm(wat, options: EncodeOptions(nameSection: true))
        )

        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        for importEntry in module.imports {
            guard case .function(let type) = importEntry.descriptor else { continue }
            let function = try Function(
                store: store,
                type: module.resolveFunctionType(type),
                body: { _, _ in
                    return []
                }
            )
            imports.define(importEntry, .function(function))
        }
        let instance = try module.instantiate(store: store, imports: imports)
        let _start = try #require(instance.exports[function: "_start"])

        let trap: Trap
        do {
            let _ = try _start()
            #expect((false), "Expected trap")
            return
        } catch let _trap as Trap {
            trap = _trap
        } catch {
            #expect((false), "Expected trap: \(error)")
            return
        }
        try assertTrap(trap)
    }

    @Test
    func backtraceBasic() throws {
        try expectTrap(
            """
            (module
                (func $foo
                    unreachable
                )
                (func $bar
                    (call $foo)
                )
                (func (export "_start")
                    (call $bar)
                )
            )
            """
        ) { trap in
            #expect(
                trap.backtrace?.symbols.compactMap(\.name) == [
                    "foo",
                    "bar",
                    "_start",
                ])
        }
    }

    @Test
    func backtraceWithImports() throws {
        try expectTrap(
            """
            (module
                (func (import "env" "bar"))
                (func
                    unreachable
                )
                (func $bar
                    (call 1)
                )
                (func (export "_start")
                    (call $bar)
                )
            )
            """
        ) { trap in
            #expect(
                trap.backtrace?.symbols.compactMap(\.name) == [
                    "wasm function[1]",
                    "bar",
                    "_start",
                ])
        }
    }

    /// A function body whose final `end` is followed by more operators is
    /// malformed. The expression parser only stops at an `end` that exhausts the
    /// code entry, so the translator has to reject the trailing operators itself
    /// instead of translating them against the finished root frame.
    @Test
    func rejectsOperatorsAfterEndOfFunctionBody() throws {
        let bytes: [UInt8] = [
            0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,  // magic and version
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,  // type: [0] = () -> ()
            0x03, 0x02, 0x01, 0x00,  // function: [0] : type 0
            // code: [0] = no locals, `end`, then a trailing `nop` and `end`
            0x0A, 0x06, 0x01, 0x04, 0x00, 0x0B, 0x01, 0x0B,
        ]
        let module = try parseWasm(bytes: bytes)
        let engine = Engine(configuration: EngineConfiguration(compilationMode: .eager))
        let store = Store(engine: engine)
        let error = #expect(throws: WasmKitError.self) {
            try module.instantiate(store: store)
        }
        #expect(
            error?.description.contains(#"Instruction cannot be appeared after "end" of function"#) == true,
            "expected a validation error, got \(error.map(String.init(describing:)) ?? "no error")"
        )
    }

    /// An `if` block can only have one `else`. A second one used to reach
    /// `pinLabelHere` for a label the first `else` had already pinned.
    @Test
    func rejectsASecondElseInTheSameIfBlock() throws {
        let bytes: [UInt8] = [
            0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,  // magic and version
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,  // type: [0] = () -> ()
            0x03, 0x02, 0x01, 0x00,  // function: [0] : type 0
            // code: [0] = no locals, `i32.const 0`, `if`, `else`, `else`, `end`, `end`
            0x0A, 0x0B, 0x01, 0x09, 0x00, 0x41, 0x00, 0x04, 0x40, 0x05, 0x05, 0x0B, 0x0B,
        ]
        let module = try parseWasm(bytes: bytes)
        let engine = Engine(configuration: EngineConfiguration(compilationMode: .eager))
        let store = Store(engine: engine)
        let error = #expect(throws: WasmKitError.self) {
            try module.instantiate(store: store)
        }
        #expect(
            error?.description.contains("expected `if` control frame on top of the stack for `else`") == true,
            "expected a validation error, got \(error.map(String.init(describing:)) ?? "no error")"
        )
    }
}
