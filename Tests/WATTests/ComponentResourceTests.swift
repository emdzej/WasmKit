#if ComponentModel
    import ComponentModel
    import Foundation
    import Testing
    import WasmKit
    import WasmTools

    /// Runs the component model test suite's resource tests against the binaries wasm-tools
    /// encodes from them, as `ComponentTests` cannot: the text format encoder here has no
    /// syntax for resources yet.
    @Suite
    struct ComponentResourceTests {
        static let testPath = ComponentTests.vendorPath.appendingPathComponent("component-model/test")

        static var available: Bool {
            FileManager.default.fileExists(atPath: testPath.path)
                && FileManager.default.fileExists(atPath: defaultWasmToolsPath)
        }

        /// wasmtime's tests, which run against the `host` instance its test harness provides.
        @Test(.enabled(if: available))
        func wasmtimeResources() throws {
            try run("wasmtime/resources.wast", instantiate: .all)
        }

        /// wasm-tools' tests, which it only validates: every component here must parse, and
        /// those without imports instantiate.
        @Test(.enabled(if: available))
        func wasmToolsResources() throws {
            try run("wasm-tools/resources.wast", instantiate: .withoutImports)
        }

        /// wasmtime's tests of linking, including module types: the text format encoder here
        /// cannot encode their instance and module types.
        @Test(
            .enabled(if: available),
            arguments: ["wasmtime/modules.wast", "wasmtime/linking.wast", "wasmtime/import.wast", "wasmtime/instance.wast"])
        func wasmtimeLinking(_ path: String) throws {
            try run(path, instantiate: .all)
        }

        /// A host passes and receives handles to a component's resources and its own.
        @Test(.enabled(if: FileManager.default.fileExists(atPath: defaultWasmToolsPath)))
        func hostPassesHandles() throws {
            let bytes = try wat2wasm(
                watContent: Array(
                    """
                    (component
                      (import "h" (type $h (sub resource)))
                      (core module $dtor
                        (global $drops (mut i32) (i32.const 0))
                        (func (export "dtor") (param i32) (global.set $drops (i32.add (global.get $drops) (i32.const 1))))
                        (func (export "drops") (result i32) (global.get $drops))
                      )
                      (core instance $d (instantiate $dtor))
                      (type $r (resource (rep i32) (dtor (func $d "dtor"))))
                      (core func $new (canon resource.new $r))
                      (core func $rep (canon resource.rep $r))
                      (core func $drop (canon resource.drop $r))
                      (core func $drop-h (canon resource.drop $h))
                      (core module $m
                        (import "" "rep" (func $rep (param i32) (result i32)))
                        (import "" "drop" (func $drop (param i32)))
                        (import "" "drop-h" (func $drop-h (param i32)))
                        (func (export "rep-of") (param i32) (result i32) (local.get 0))
                        (func (export "consume") (param i32) (result i32)
                          (local $rep i32)
                          (local.set $rep (call $rep (local.get 0)))
                          (call $drop (local.get 0))
                          (local.get $rep))
                        (func (export "keep-borrow") (param i32))
                        (func (export "drop-borrow") (param i32) (call $drop-h (local.get 0)))
                      )
                      (core instance $i (instantiate $m
                        (with "" (instance
                          (export "rep" (func $rep))
                          (export "drop" (func $drop))
                          (export "drop-h" (func $drop-h))
                        ))
                      ))
                      (export $r' "r" (type $r))
                      (func (export "[constructor]r") (param "rep" u32) (result (own $r')) (canon lift (core func $new)))
                      (func (export "rep-of") (param "r" (borrow $r')) (result u32) (canon lift (core func $i "rep-of")))
                      (func (export "consume") (param "r" (own $r')) (result u32) (canon lift (core func $i "consume")))
                      (func (export "drops") (result u32) (canon lift (core func $d "drops")))
                      (func (export "keep-borrow") (param "h" (borrow $h)) (canon lift (core func $i "keep-borrow")))
                      (func (export "drop-borrow") (param "h" (borrow $h)) (canon lift (core func $i "drop-borrow")))
                    )
                    """.utf8))
            let store = Store(engine: Engine())
            let hostType = ComponentResourceType()
            var imports = ComponentImports()
            imports.define(name: "h", .resourceType(hostType))
            let instance = try ComponentLoader(store: store).instantiate(component: try parseComponent(bytes: bytes), imports: imports)
            guard case .resourceType(let type) = instance.export("r") else {
                Issue.record("no resource type export")
                return
            }
            #expect(!type.isHostDefined)
            func call(_ name: String, _ arguments: [ComponentValue]) throws -> [ComponentValue] {
                guard let function = instance.exportedFunction(name) else { throw TestError("no export \(name)") }
                return try function.invoke(arguments)
            }
            func u32(_ results: [ComponentValue]) -> UInt32? {
                guard results.count == 1, case .u32(let value) = results[0] else { return nil }
                return value
            }

            // An owned handle comes out of the component's table as the resource itself.
            guard case .own(let resource) = try call("[constructor]r", [.u32(42)]).first else {
                Issue.record("the constructor returned no owned resource")
                return
            }
            #expect(resource.type === type)
            #expect(resource.rep == 42)

            // Lent back to its implementation, a borrow is its representation.
            #expect(u32(try call("rep-of", [.borrow(resource)])) == 42)

            // Given back, it is dropped there, running the destructor.
            #expect(u32(try call("drops", [])) == 0)
            #expect(u32(try call("consume", [.own(resource)])) == 42)
            #expect(u32(try call("drops", [])) == 1)

            // A resource of another type is rejected.
            #expect(throws: (any Error).self) {
                try call("consume", [.own(ComponentResource(type: hostType, rep: 1))])
            }

            // A borrow lent to a call must be dropped before it returns.
            let hostResource = ComponentResource(type: hostType, rep: 7)
            #expect(try call("drop-borrow", [.borrow(hostResource)]).isEmpty)
            do {
                _ = try call("keep-borrow", [.borrow(hostResource)])
                Issue.record("a call that kept a borrow returned")
            } catch {
                #expect(String(describing: error).contains("borrow handles still remain at the end of the call"))
            }
        }

        enum Instantiation {
            case all
            case withoutImports
        }

        private func run(_ path: String, instantiate: Instantiation) throws {
            let url = Self.testPath.appendingPathComponent(path)
            let (json, files) = try wast2json(
                wastContent: Array(try String(contentsOf: url, encoding: .utf8).utf8),
                wastFileName: url.lastPathComponent)

            let store = Store(engine: Engine())
            let loader = ComponentLoader(store: store)
            let host = try SpectestHost(store: store)
            var imports = ComponentImports()
            imports.define(name: "host", instance: host.instance)
            imports.define(name: "host-return-two", host.returnTwo)

            var current: ComponentInstance?
            var definitions: [String: ParsedComponent] = [:]
            var counts: [String: Int] = [:]

            func component(_ command: WAST2JSONCommand) throws -> ParsedComponent {
                guard let filename = command.filename, let bytes = files[filename] else {
                    throw TestError("\(path):\(command.line): no binary for the component")
                }
                return try parseComponent(bytes: bytes)
            }
            func invoke(_ command: WAST2JSONCommand) throws -> [ComponentValue] {
                guard let action = command.action, action.type == "invoke", let field = action.field else {
                    throw TestError("\(path):\(command.line): unsupported action")
                }
                guard (action.args ?? []).isEmpty else {
                    throw TestError("\(path):\(command.line): arguments are not supported yet")
                }
                guard let function = current?.exportedFunction(field) else {
                    throw TestError("\(path):\(command.line): no current instance exports \"\(field)\"")
                }
                return try function.invoke([])
            }
            func expectFailure(_ command: WAST2JSONCommand, _ body: () throws -> Void) {
                do {
                    try body()
                    Issue.record("\(path):\(command.line): expected a failure with \"\(command.text ?? "")\"")
                } catch {
                    let message = String(describing: error)
                    if let text = command.text, !message.contains(text) {
                        Issue.record("\(path):\(command.line): expected \"\(text)\", got \"\(message)\"")
                    }
                }
            }

            for command in json.commands {
                counts[command.type, default: 0] += 1
                do {
                    switch command.type {
                    case "module":
                        let parsed = try component(command)
                        if instantiate == .all || parsed.imports.isEmpty {
                            current = try loader.instantiate(component: parsed, imports: imports)
                            // As in wasmtime's harness, a named component's instance can be
                            // imported by that name from then on.
                            if let name = command.name, let current {
                                imports.define(name: name.hasPrefix("$") ? String(name.dropFirst()) : name, instance: current)
                            }
                        }
                    case "module_definition":
                        let parsed = try component(command)
                        if let name = command.name {
                            definitions[name] = parsed
                        }
                    case "module_instance":
                        guard let name = command.module, let definition = definitions[name] else {
                            throw TestError("\(path):\(command.line): no component definition \(command.module ?? "")")
                        }
                        current = try loader.instantiate(component: definition, imports: imports)
                        if let name = command.instance, let current {
                            imports.define(name: name.hasPrefix("$") ? String(name.dropFirst()) : name, instance: current)
                        }
                    case "assert_return":
                        let results = try invoke(command)
                        guard (command.expected ?? []).isEmpty else {
                            throw TestError("\(path):\(command.line): expected results are not supported yet")
                        }
                        #expect(results.isEmpty, "\(path):\(command.line): unexpected results \(results)")
                    case "assert_trap":
                        expectFailure(command) { _ = try invoke(command) }
                    case "assert_unlinkable", "assert_uninstantiable":
                        expectFailure(command) {
                            _ = try loader.instantiate(component: try component(command), imports: imports)
                        }
                    case "assert_invalid", "assert_malformed":
                        // The loader does not validate components.
                        break
                    default:
                        Issue.record("\(path):\(command.line): unsupported command \(command.type)")
                    }
                } catch {
                    Issue.record("\(path):\(command.line): \(command.type) failed: \(error)")
                }
            }
            #expect(counts["module", default: 0] > 0, "\(path): no components ran")
        }

        struct TestError: Error, CustomStringConvertible {
            let description: String
            init(_ description: String) { self.description = description }
        }
    }

    /// The `host` instance wasmtime's test harness gives components, from
    /// `link_component_spectest` in `crates/wast/src/component.rs`.
    final class SpectestHost {
        /// How many `resource1` resources components have dropped, and the last one's
        /// representation.
        final class Drops {
            var count: UInt32 = 0
            var last: UInt32 = .max
        }

        let drops = Drops()
        let resource1: ComponentResourceType
        let resource2 = ComponentResourceType()
        let instance: ComponentInstance
        /// A function the harness defines outside the `host` instance.
        let returnTwo: ComponentExternalValue

        init(store: Store) throws {
            let drops = self.drops
            let resource1 = ComponentResourceType { rep in
                drops.count += 1
                drops.last = rep
            }
            self.resource1 = resource1
            let types: [ComponentHostTypeDefinition] = [.resource(resource1)]
            let own = ComponentDefValType.own(ComponentTypeIndex(rawValue: 0))
            let borrow = ComponentDefValType.borrow(ComponentTypeIndex(rawValue: 0))
            func param(_ name: String, _ type: ComponentDefValType) -> ComponentFuncType.Param {
                ComponentFuncType.Param(name: name, type: type)
            }
            func function(
                _ params: [ComponentFuncType.Param], _ result: ComponentDefValType? = nil,
                _ body: @escaping ([ComponentValue]) throws -> [ComponentValue]
            ) -> ComponentExternalValue {
                .function(
                    ComponentFunction(
                        store: store, type: ComponentFuncType(params: params, result: result), types: types,
                        implementation: body))
            }
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw ComponentResourceTests.TestError("host assertion failed: \(message)") }
            }

            returnTwo = function([], .primitive(.u32)) { _ in [.u32(2)] }
            let nested = ComponentInstance(
                store: store, exports: ["return-four": function([], .primitive(.u32)) { _ in [.u32(4)] }])
            let simpleModule = try parseWasm(
                bytes: try wat2wasm(
                    watContent: Array(
                        #"(module (global (export "g") i32 i32.const 100) (func (export "f") (result i32) i32.const 101))"#.utf8)))
            instance = ComponentInstance(
                store: store,
                exports: [
                    "return-three": function([], .primitive(.u32)) { _ in [.u32(3)] },
                    "nested": .instance(nested),
                    "simple-module": .coreModule(simpleModule),
                    "resource1": .resourceType(resource1),
                    "resource2": .resourceType(resource2),
                    // The same type under another name.
                    "resource1-again": .resourceType(resource1),
                    "[constructor]resource1": function([param("r", .primitive(.u32))], own) { arguments in
                        guard case .u32(let rep) = arguments[0] else { throw ComponentResourceTests.TestError("rep") }
                        return [.own(ComponentResource(type: resource1, rep: rep))]
                    },
                    "[static]resource1.assert": function([param("r", own), param("rep", .primitive(.u32))]) { arguments in
                        guard case .own(let resource) = arguments[0], case .u32(let rep) = arguments[1] else {
                            throw ComponentResourceTests.TestError("expected an owned resource and a u32")
                        }
                        try check(resource.rep == rep, "rep \(resource.rep) is not \(rep)")
                        return []
                    },
                    "[static]resource1.last-drop": function([], .primitive(.u32)) { _ in [.u32(drops.last)] },
                    "[static]resource1.drops": function([], .primitive(.u32)) { _ in [.u32(drops.count)] },
                    "[method]resource1.simple": function([param("self", borrow), param("rep", .primitive(.u32))]) { arguments in
                        guard case .borrow(let resource) = arguments[0], case .u32(let rep) = arguments[1] else {
                            throw ComponentResourceTests.TestError("expected a borrowed resource and a u32")
                        }
                        try check(resource.rep == rep, "rep \(resource.rep) is not \(rep)")
                        return []
                    },
                    "[method]resource1.take-borrow": function([param("self", borrow), param("b", borrow)]) { arguments in
                        guard case .borrow = arguments[0], case .borrow = arguments[1] else {
                            throw ComponentResourceTests.TestError("expected two borrowed resources")
                        }
                        return []
                    },
                    "[method]resource1.take-own": function([param("self", borrow), param("b", own)]) { arguments in
                        guard case .borrow = arguments[0], case .own = arguments[1] else {
                            throw ComponentResourceTests.TestError("expected a borrowed and an owned resource")
                        }
                        return []
                    },
                ])
        }
    }
#endif
