#if ComponentModel
    import ComponentModel
    import Foundation
    import Testing
    import WasmKit
    import WasmTools

    /// Imports must have the function and value types their declarations give, as wasm-tools'
    /// validator requires of instantiation arguments, apart from parameter names unless checking
    /// is strict.
    @Suite(.enabled(if: FileManager.default.fileExists(atPath: defaultWasmToolsPath)))
    struct ComponentImportTypeTests {
        /// Host functions and instances belong to the store they are instantiated in.
        let store = Store(engine: Engine())

        /// Instantiates `wat` with `imports`, expecting it to fail with an error containing
        /// `message`, or to succeed if `message` is `nil`.
        func instantiate(
            _ wat: String, imports: ComponentImports = ComponentImports(),
            checking: ComponentLoader.ImportTypeChecking = .lenient, failsWith message: String?,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let component = try parseComponent(bytes: try wat2wasm(watContent: Array(wat.utf8)))
            do {
                _ = try ComponentLoader(store: store, importTypeChecking: checking).instantiate(component: component, imports: imports)
                #expect(message == nil, "instantiated, expected \(message ?? "")", sourceLocation: sourceLocation)
            } catch {
                guard let message else {
                    Issue.record("failed: \(error)", sourceLocation: sourceLocation)
                    return
                }
                #expect("\(error)".contains(message), "\(error)", sourceLocation: sourceLocation)
            }
        }

        func hostFunction(
            _ type: ComponentFuncType, types: [ComponentHostTypeDefinition] = []
        ) -> ComponentExternalValue {
            .function(ComponentFunction(store: store, type: type, types: types) { _ in [] })
        }

        func imports(_ definitions: [String: ComponentExternalValue]) -> ComponentImports {
            var imports = ComponentImports()
            for (name, value) in definitions {
                imports.define(name: name, value)
            }
            return imports
        }

        @Test
        func hostFunctionSignatures() throws {
            let wat = #"(component (import "f" (func (param "x" u32) (result u32))))"#
            let cases: [(ComponentFuncType, String?)] = [
                (ComponentFuncType(params: [.init(name: "x", type: .primitive(.u32))], result: .primitive(.u32)), nil),
                (ComponentFuncType(params: [], result: .primitive(.u32)), "expected 1 parameters, found 0"),
                (
                    ComponentFuncType(params: [.init(name: "x", type: .primitive(.s32))], result: .primitive(.u32)),
                    "type mismatch in function parameter `x`: expected u32, found s32"
                ),
                (ComponentFuncType(params: [.init(name: "x", type: .primitive(.u32))], result: nil), "expected a result, found none"),
                (
                    ComponentFuncType(params: [.init(name: "x", type: .primitive(.u32))], result: .primitive(.string)),
                    "type mismatch with result type: expected u32, found string"
                ),
            ]
            for (type, message) in cases {
                for checking in [ComponentLoader.ImportTypeChecking.lenient, .strict] {
                    try instantiate(wat, imports: imports(["f": hostFunction(type)]), checking: checking, failsWith: message)
                }
            }
        }

        /// Only strict checking compares parameter names, as wasmtime's linker does not.
        @Test
        func parameterNames() throws {
            let wat = #"(component (import "f" (func (param "x" u32))))"#
            let renamed = hostFunction(ComponentFuncType(params: [.init(name: "y", type: .primitive(.u32))], result: nil))
            try instantiate(wat, imports: imports(["f": renamed]), checking: .lenient, failsWith: nil)
            try instantiate(
                wat, imports: imports(["f": renamed]), checking: .strict,
                failsWith: "type mismatch for import `f`: expected parameter named `x`, found `y`")

            // The mode applies to one component instantiating another too.
            let nested = #"""
                (component
                  (import "f" (func $f (param "x" u32)))
                  (component $c (import "x" (func (param "y" u32))))
                  (instance (instantiate $c (with "x" (func $f))))
                )
                """#
            let original = hostFunction(ComponentFuncType(params: [.init(name: "x", type: .primitive(.u32))], result: nil))
            try instantiate(nested, imports: imports(["f": original]), checking: .lenient, failsWith: nil)
            try instantiate(
                nested, imports: imports(["f": original]), checking: .strict,
                failsWith: "expected parameter named `y`, found `x`")
        }

        @Test
        func definedValueTypes() throws {
            let wat = #"""
                (component
                  (type $o (option u8))
                  (type $r (record (field "a" u32) (field "b" $o)))
                  (import "f" (func (param "r" $r)))
                )
                """#
            func record(_ fields: [ComponentRecordField]) -> ComponentExternalValue {
                hostFunction(
                    ComponentFuncType(params: [.init(name: "r", type: .indexed(ComponentTypeIndex(rawValue: 1)))], result: nil),
                    types: [.value(.option(.primitive(.u8))), .value(.record(fields))])
            }
            let option = ComponentValType.index(ComponentTypeIndex(rawValue: 0))
            try instantiate(
                wat, imports: imports(["f": record([.init(name: "a", type: .primitive(.u32)), .init(name: "b", type: option)])]),
                failsWith: nil)
            try instantiate(
                wat, imports: imports(["f": record([.init(name: "a", type: .primitive(.u32))])]),
                failsWith: "expected 2 fields, found 1")
            try instantiate(
                wat,
                imports: imports(["f": record([.init(name: "a", type: .primitive(.u32)), .init(name: "c", type: option)])]),
                failsWith: "expected field name `b`, found `c`")
            try instantiate(
                wat,
                imports: imports([
                    "f": record([.init(name: "a", type: .primitive(.u32)), .init(name: "b", type: .primitive(.u8))])
                ]),
                failsWith: "type mismatch in record field `b`: expected option, found u8")
        }

        @Test
        func handleTypes() throws {
            let wat = #"""
                (component
                  (import "r" (type $r (sub resource)))
                  (import "f" (func (param "h" (own $r))))
                )
                """#
            let resource = ComponentResourceType()
            func function(_ type: ComponentResourceType, borrow: Bool = false) -> ComponentExternalValue {
                let index = ComponentTypeIndex(rawValue: 0)
                return hostFunction(
                    ComponentFuncType(params: [.init(name: "h", type: borrow ? .borrow(index) : .own(index))], result: nil),
                    types: [.resource(type)])
            }
            try instantiate(wat, imports: imports(["r": .resourceType(resource), "f": function(resource)]), failsWith: nil)
            try instantiate(
                wat, imports: imports(["r": .resourceType(resource), "f": function(ComponentResourceType())]),
                failsWith: "resource types are not the same")
            try instantiate(
                wat, imports: imports(["r": .resourceType(resource), "f": function(resource, borrow: true)]),
                failsWith: "expected own, found borrow")
        }

        @Test
        func instanceExports() throws {
            let wat = #"""
                (component
                  (type $t (tuple u32 string))
                  (import "i" (instance
                    (alias outer 1 $t (type $t))
                    (type $l (list $t))
                    (export "f" (func (param "l" $l)))
                  ))
                )
                """#
            func instance(_ element: [ComponentValType]) -> ComponentExternalValue {
                let list = ComponentFuncType(
                    params: [.init(name: "l", type: .indexed(ComponentTypeIndex(rawValue: 1)))], result: nil)
                let function = ComponentFunction(
                    store: store, type: list,
                    types: [.value(.tuple(element)), .value(.list(.index(ComponentTypeIndex(rawValue: 0))))]
                ) { _ in [] }
                return .instance(ComponentInstance(store: store, exports: ["f": .function(function)]))
            }
            try instantiate(wat, imports: imports(["i": instance([.primitive(.u32), .primitive(.string)])]), failsWith: nil)
            try instantiate(
                wat, imports: imports(["i": instance([.primitive(.u32), .primitive(.char)])]),
                failsWith:
                    "type mismatch for import `i.f`: type mismatch in function parameter `l`: type mismatch in list element: type mismatch in tuple field 1: expected string, found char"
            )
        }

        /// A component instantiating another checks its arguments the same way.
        @Test
        func instantiationArguments() throws {
            try instantiate(
                #"""
                (component
                  (import "f" (func $f (param "x" u32)))
                  (component $c (import "x" (func (param "x" u32))))
                  (component $d (import "x" (func (param "x" s32))))
                  (instance (instantiate $c (with "x" (func $f))))
                  (instance (instantiate $d (with "x" (func $f))))
                )
                """#,
                imports: imports([
                    "f": hostFunction(ComponentFuncType(params: [.init(name: "x", type: .primitive(.u32))], result: nil))
                ]),
                failsWith: "type mismatch for import `x`: type mismatch in function parameter `x`: expected s32, found u32")

            let types = #"""
                (component
                  (component $c
                    (type $t (variant (case "a" u32) (case "b")))
                    (import "x" (type (eq $t)))
                  )
                  (type $ok (variant (case "a" u32) (case "b")))
                  (type $bad (variant (case "a") (case "b")))
                  (instance (instantiate $c (with "x" (type $ok))))
                  (instance (instantiate $c (with "x" (type %TYPE))))
                )
                """#
            try instantiate(types.replacingOccurrences(of: "%TYPE", with: "$ok"), failsWith: nil)
            try instantiate(
                types.replacingOccurrences(of: "%TYPE", with: "$bad"),
                failsWith: "expected case `a` to have a type, found none")
        }
    }
#endif
