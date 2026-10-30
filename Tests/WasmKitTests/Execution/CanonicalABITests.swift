#if ComponentModel
    import Testing
    import WAT
    import ComponentModel
    import WasmParser

    @testable import WasmKit

    /// Layout and flattening against the canonical ABI's `elem_size`, `alignment` and
    /// `flatten_type`, and lifting and lowering through components that exercise them.
    @Suite
    struct CanonicalABITests {
        private let types = CanonicalABITypes(resolveType: { index in
            throw CanonicalABIError(description: "no type \(index)")
        })

        private func record(_ fields: ComponentPrimValType...) -> ComponentDefValType {
            .record(fields.enumerated().map { ComponentRecordField(name: "f\($0)", type: .primitive($1)) })
        }

        @Test func recordsArePaddedToTheirFields() throws {
            #expect(try types.size(record(.u8, .u32)) == 8)
            #expect(try types.alignment(record(.u8, .u32)) == 4)
            #expect(try types.size(record(.u32, .u8)) == 8)
            #expect(try types.size(record(.u8, .u16, .u8)) == 6)
            #expect(try types.size(.tuple([.primitive(.u64), .primitive(.u8)])) == 16)
        }

        @Test func variantsUseTheSmallestDiscriminant() throws {
            #expect(try types.size(.option(.primitive(.u8))) == 2)
            #expect(try types.alignment(.option(.primitive(.u8))) == 1)
            #expect(try types.size(.option(.primitive(.u64))) == 16)
            #expect(try types.size(.result(ok: .primitive(.u32), error: nil)) == 8)
            #expect(try types.size(.enum(["a", "b"])) == 1)
            #expect(try types.size(.enum((0..<257).map { "c\($0)" })) == 2)
            let variant = ComponentDefValType.variant([
                ComponentCaseField(name: "a", type: .primitive(.u32)),
                ComponentCaseField(name: "b", type: nil),
            ])
            // A list of these has a stride of 8, with the payload at +4.
            #expect(try types.size(variant) == 8)
        }

        @Test func flagsTakeTheFewestBytes() throws {
            #expect(try types.size(.flags((0..<8).map { "f\($0)" })) == 1)
            #expect(try types.size(.flags((0..<9).map { "f\($0)" })) == 2)
            #expect(try types.size(.flags((0..<17).map { "f\($0)" })) == 4)
            #expect(try types.size(.flags((0..<40).map { "f\($0)" })) == 8)
            #expect(try types.flatten(.flags((0..<40).map { "f\($0)" })) == [.i32, .i32])
        }

        @Test func variantPayloadsJoin() throws {
            let variant = ComponentDefValType.variant([
                ComponentCaseField(name: "a", type: .primitive(.float32)),
                ComponentCaseField(name: "b", type: .primitive(.u64)),
                ComponentCaseField(name: "c", type: .primitive(.u32)),
            ])
            #expect(try types.flatten(variant) == [.i32, .i64])
            let floatOrInt = ComponentDefValType.variant([
                ComponentCaseField(name: "a", type: .primitive(.float32)),
                ComponentCaseField(name: "b", type: .primitive(.u32)),
            ])
            #expect(try types.flatten(floatOrInt) == [.i32, .i32])
            #expect(try types.flatten(.option(.primitive(.string))) == [.i32, .i32, .i32])
            #expect(try types.flatten(.result(ok: nil, error: nil)) == [.i32])
        }

        @Test func flatValuesRoundTripThroughVariants() throws {
            let variant = ComponentDefValType.variant([
                ComponentCaseField(name: "a", type: .primitive(.float32)),
                ComponentCaseField(name: "b", type: .primitive(.u64)),
            ])
            let store = Store(engine: Engine())
            var context = CanonicalABIContext(types: types, options: CanonOptions(), store: store)
            for value in [ComponentValue.variant(caseName: "a", payload: .float32(1.5)), .variant(caseName: "b", payload: .u64(7))] {
                let flat = try context.lowerFlat(value, as: variant)
                #expect(flat.count == 2)
                var values = CanonicalABIContext.FlatValues(values: flat)
                let lifted = try context.liftFlat(variant, from: &values)
                #expect("\(lifted)" == "\(value)")
            }
            // An `err` without a payload and an `ok` without one are different values.
            let result = ComponentDefValType.result(ok: nil, error: nil)
            #expect(try context.lowerFlat(.result(ok: nil, error: nil), as: result) == [.i32(0)])
            #expect(try context.lowerFlat(.result(ok: nil, error: .tuple([])), as: result) == [.i32(1)])
        }

        @Test func liftingRejectsInvalidValues() throws {
            let store = Store(engine: Engine())
            var context = CanonicalABIContext(types: types, options: CanonOptions(), store: store)
            var surrogate = CanonicalABIContext.FlatValues(values: [.i32(0xD800)])
            #expect(throws: CanonicalABIError.self) { _ = try context.liftFlat(.primitive(.char), from: &surrogate) }
            var discriminant = CanonicalABIContext.FlatValues(values: [.i32(2), .i32(0)])
            #expect(throws: CanonicalABIError.self) {
                _ = try context.liftFlat(.option(.primitive(.u32)), from: &discriminant)
            }
        }

        @Test func functionTypesSpillPastTheFlatLimits() throws {
            let many = ComponentFuncType(
                params: (0..<17).map { .init(name: "p\($0)", type: .primitive(.u32)) }, result: .primitive(.string))
            #expect(try types.flattenFunctionType(many, lifting: true) == FunctionType(parameters: [.i32], results: [.i32]))
            #expect(try types.flattenFunctionType(many, lifting: false) == FunctionType(parameters: [.i32, .i32], results: []))
            let few = ComponentFuncType(params: [.init(name: "a", type: .primitive(.u64))], result: .primitive(.float32))
            #expect(try types.flattenFunctionType(few, lifting: true) == FunctionType(parameters: [.i64], results: [.f32]))
        }

        /// Each nested component recurses in the parser, so the depth is bounded.
        @Test func deeplyNestedComponentsAreRejected() throws {
            func nested(_ depth: Int) -> [UInt8] {
                let header: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00]
                var bytes = header
                for _ in 0..<depth {
                    var size = bytes.count
                    var leb: [UInt8] = []
                    repeat {
                        leb.append(UInt8(size & 0x7F) | (size >= 0x80 ? 0x80 : 0))
                        size >>= 7
                    } while size > 0
                    bytes = header + [0x04] + leb + bytes
                }
                return bytes
            }
            _ = try parseComponent(bytes: nested(32))
            #expect(throws: (any Error).self) { _ = try parseComponent(bytes: nested(33)) }
            #expect(throws: (any Error).self) { _ = try parseComponent(bytes: nested(500)) }
        }

        // MARK: - Through components

        private func instantiate(_ wat: String) throws -> ComponentInstance {
            let store = Store(engine: Engine())
            var wast = try parseComponentWAST(wat)
            guard let (directive, _) = try wast.nextDirective(), case .component(let comp) = directive,
                case .text(let componentDef) = comp.source
            else {
                throw CanonicalABIError(description: "expected a component")
            }
            var encoder = ComponentEncoder()
            let parsed = try parseComponent(bytes: try encoder.encode(componentDef, options: .init()))
            return try ComponentLoader(store: store).instantiate(component: parsed)
        }

        private func function(_ instance: ComponentInstance, _ name: String) throws -> ComponentFunction {
            guard case .function(let function) = instance.export(name) else {
                throw CanonicalABIError(description: "no function \(name)")
            }
            return function
        }

        /// A core module with a bump allocator, returning through a pointer it fills in.
        private static let allocator = """
            (memory (export "memory") 1)
            (global $next (mut i32) (i32.const 1024))
            (func $realloc (export "realloc") (param i32 i32 i32 i32) (result i32)
              (local $p i32)
              (local.set $p (i32.and (i32.add (global.get $next) (i32.sub (local.get 2) (i32.const 1)))
                                     (i32.sub (i32.const 0) (local.get 2))))
              (global.set $next (i32.add (local.get $p) (local.get 3)))
              (local.get $p))
            """

        /// An `option<u32>` result flattens to two values, so it comes back through a pointer.
        @Test func anOptionResultIsLoadedThroughThePointer() throws {
            let instance = try instantiate(
                """
                (component
                  (core module $m
                    \(Self.allocator)
                    (func (export "get") (param i32) (result i32)
                      (i32.store8 (i32.const 64) (i32.ne (local.get 0) (i32.const 0)))
                      (i32.store (i32.const 68) (local.get 0))
                      (i32.const 64)))
                  (core instance $i (instantiate $m))
                  (func (export "get") (param "x" u32) (result (option u32))
                    (canon lift (core func $i "get") (memory $i "memory"))))
                """)
            let get = try function(instance, "get")
            #expect("\(try get.invoke([.u32(7)]))" == "\([ComponentValue.option(.u32(7))])")
            #expect("\(try get.invoke([.u32(0)]))" == "\([ComponentValue.option(nil)])")
        }

        /// A list argument is copied in with the guest's `realloc`, and a tuple comes back.
        @Test func aListArgumentIsLowered() throws {
            let instance = try instantiate(
                """
                (component
                  (core module $m
                    \(Self.allocator)
                    (func (export "sum") (param $p i32) (param $n i32) (result i32)
                      (local $i i32) (local $s i32)
                      (block $done (loop $l
                        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
                        (local.set $s (i32.add (local.get $s) (i32.load8_u (i32.add (local.get $p) (local.get $i)))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $l)))
                      (i32.store (i32.const 64) (local.get $s))
                      (i32.store (i32.const 68) (local.get $n))
                      (i32.const 64)))
                  (core instance $i (instantiate $m))
                  (func (export "sum") (param "xs" (list u8)) (result (tuple u32 u32))
                    (canon lift (core func $i "sum") (memory $i "memory") (realloc (func $i "realloc")))))
                """)
            let sum = try function(instance, "sum")
            let result = try sum.invoke([.list([.u8(1), .u8(2), .u8(250)])])
            #expect("\(result)" == "\([ComponentValue.tuple([.u32(253), .u32(3)])])")
        }

        /// The string a guest returns must be valid UTF-8.
        @Test func anInvalidStringTraps() throws {
            let instance = try instantiate(
                """
                (component
                  (core module $m
                    (memory (export "memory") 1)
                    (data (i32.const 16) "a\\ffb")
                    (func (export "get") (result i32)
                      (i32.store (i32.const 64) (i32.const 16))
                      (i32.store (i32.const 68) (i32.const 3))
                      (i32.const 64)))
                  (core instance $i (instantiate $m))
                  (func (export "get") (result string)
                    (canon lift (core func $i "get") (memory $i "memory"))))
                """)
            #expect(throws: CanonicalABIError.self) { _ = try function(instance, "get").invoke([]) }
        }

        /// A `canon lift` whose core function has another type is rejected when instantiating.
        @Test func aLiftOfTheWrongCoreTypeIsRejected() throws {
            #expect(throws: (any Error).self) {
                _ = try instantiate(
                    """
                    (component
                      (core module $m (func (export "f") (param i64) (result i32) (i32.const 0)))
                      (core instance $i (instantiate $m))
                      (func (export "f") (param "x" u32) (result u32) (canon lift (core func $i "f"))))
                    """)
            }
        }

        /// A lowered function with a composite parameter lifts its core arguments by type,
        /// rather than one core value per parameter.
        @Test func aLoweredFunctionLiftsCompositeArguments() throws {
            let instance = try instantiate(
                """
                (component
                  (component $picker
                    (core module $m
                      (func (export "pick") (param i32 i32 i32) (result i32)
                        (if (result i32) (local.get 0) (then (local.get 2)) (else (local.get 1)))))
                    (core instance $i (instantiate $m))
                    (type $e (enum "first" "second"))
                    (func (export "pick") (param "which" $e) (param "a" u32) (param "b" u32) (result u32)
                      (canon lift (core func $i "pick"))))
                  (instance $p (instantiate $picker))
                  (core func $lowered (canon lower (func $p "pick")))
                  (core module $caller
                    (import "host" "pick" (func $pick (param i32 i32 i32) (result i32)))
                    (func (export "run") (param i32) (result i32)
                      (call $pick (local.get 0) (i32.const 10) (i32.const 20))))
                  (core instance $c (instantiate $caller (with "host" (instance (export "pick" (func $lowered))))))
                  (func (export "run") (param "which" u32) (result u32) (canon lift (core func $c "run"))))
                """)
            let run = try function(instance, "run")
            #expect("\(try run.invoke([.u32(0)]))" == "\([ComponentValue.u32(10)])")
            #expect("\(try run.invoke([.u32(1)]))" == "\([ComponentValue.u32(20)])")
        }
    }
#endif
