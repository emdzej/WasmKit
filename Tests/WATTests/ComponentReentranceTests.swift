#if ComponentModel
    import ComponentModel
    import Foundation
    import Testing
    import WasmKit
    import WasmTools

    /// The spec's checks on entering and leaving a component instance, and dropping a resource
    /// from the host. Built with wasm-tools, as the text format encoder here has no resources.
    @Suite(.enabled(if: FileManager.default.fileExists(atPath: defaultWasmToolsPath)))
    struct ComponentReentranceTests {
        let store = Store(engine: Engine())

        func instantiate(_ wat: String, imports: ComponentImports = ComponentImports()) throws -> ComponentInstance {
            let bytes = try wat2wasm(watContent: Array(wat.utf8))
            return try ComponentLoader(store: store).instantiate(component: try parseComponent(bytes: bytes), imports: imports)
        }

        func expectTrap(
            _ message: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void
        ) {
            do {
                try body()
                Issue.record("expected a trap with \"\(message)\"", sourceLocation: sourceLocation)
            } catch {
                #expect("\(error)".contains(message), "\(error)", sourceLocation: sourceLocation)
            }
        }

        func u32(_ results: [ComponentValue]) -> UInt32? {
            guard results.count == 1, case .u32(let value) = results[0] else { return nil }
            return value
        }

        /// A host function a component calls cannot call back into that component.
        @Test func reenteringAnInstanceTraps() throws {
            var instance: ComponentInstance?
            let callback = ComponentFunction(store: store, type: ComponentFuncType(params: [], result: nil)) { _ in
                _ = try instance?.exportedFunction("other")?.invoke([])
                return []
            }
            var imports = ComponentImports()
            imports.define(name: "callback", .function(callback))
            instance = try instantiate(
                """
                (component
                  (import "callback" (func $callback))
                  (core func $callback' (canon lower (func $callback)))
                  (core module $m
                    (import "" "callback" (func $callback))
                    (func (export "run") (call $callback))
                    (func (export "other"))
                  )
                  (core instance $i (instantiate $m (with "" (instance (export "callback" (func $callback'))))))
                  (func (export "run") (canon lift (core func $i "run")))
                  (func (export "other") (canon lift (core func $i "other")))
                )
                """, imports: imports)
            let other = try #require(instance?.exportedFunction("other"))
            let run = try #require(instance?.exportedFunction("run"))

            _ = try other.invoke([])
            expectTrap("cannot enter component instance") { _ = try run.invoke([]) }
            // The instance is not left entered by the trap.
            _ = try other.invoke([])
        }

        /// A post-return function may not call out of its instance.
        @Test func leavingAnInstanceInPostReturnTraps() throws {
            let host = ComponentFunction(store: store, type: ComponentFuncType(params: [], result: nil)) { _ in [] }
            var imports = ComponentImports()
            imports.define(name: "host", .function(host))
            let instance = try instantiate(
                """
                (component
                  (import "host" (func $host))
                  (core func $host' (canon lower (func $host)))
                  (core module $m
                    (import "" "host" (func $host))
                    (func (export "calls-out") (result i32) (call $host) (i32.const 1))
                    (func (export "post-return") (param i32) (call $host))
                    (func (export "post-return-quietly") (param i32))
                  )
                  (core instance $i (instantiate $m (with "" (instance (export "host" (func $host'))))))
                  (func (export "f") (result u32)
                    (canon lift (core func $i "calls-out") (post-return (func $i "post-return"))))
                  (func (export "g") (result u32)
                    (canon lift (core func $i "calls-out") (post-return (func $i "post-return-quietly"))))
                )
                """, imports: imports)
            #expect(u32(try instance.exportedFunction("g")!.invoke([])) == 1)
            expectTrap("cannot leave component instance") { _ = try instance.exportedFunction("f")!.invoke([]) }
            #expect(u32(try instance.exportedFunction("g")!.invoke([])) == 1)
        }

        /// A `realloc` called to lower arguments into the instance may not call out of it.
        @Test func leavingAnInstanceInReallocTraps() throws {
            let host = ComponentFunction(store: store, type: ComponentFuncType(params: [], result: nil)) { _ in [] }
            var imports = ComponentImports()
            imports.define(name: "host", .function(host))
            let instance = try instantiate(
                """
                (component
                  (import "host" (func $host))
                  (core func $host' (canon lower (func $host)))
                  (core module $m
                    (import "" "host" (func $host))
                    (memory (export "memory") 1)
                    (func (export "realloc") (param i32 i32 i32 i32) (result i32) (call $host) (i32.const 64))
                    (func (export "take") (param i32 i32))
                  )
                  (core instance $i (instantiate $m (with "" (instance (export "host" (func $host'))))))
                  (func (export "take") (param "s" string)
                    (canon lift (core func $i "take") (memory $i "memory") (realloc (func $i "realloc"))))
                )
                """, imports: imports)
            expectTrap("cannot leave component instance") {
                _ = try instance.exportedFunction("take")!.invoke([.string("hello")])
            }
        }

        /// A host that owns a guest-defined resource drops it, and the component's destructor runs.
        @Test func theHostDropsAResource() throws {
            let instance = try instantiate(
                """
                (component
                  (core module $dtor
                    (global $drops (mut i32) (i32.const 0))
                    (global $last (mut i32) (i32.const 0))
                    (func (export "dtor") (param i32)
                      (global.set $drops (i32.add (global.get $drops) (i32.const 1)))
                      (global.set $last (local.get 0)))
                    (func (export "drops") (result i32) (global.get $drops))
                    (func (export "last") (result i32) (global.get $last))
                  )
                  (core instance $d (instantiate $dtor))
                  (type $r (resource (rep i32) (dtor (func $d "dtor"))))
                  (core func $new (canon resource.new $r))
                  (export $r' "r" (type $r))
                  (func (export "[constructor]r") (param "rep" u32) (result (own $r')) (canon lift (core func $new)))
                  (func (export "drops") (result u32) (canon lift (core func $d "drops")))
                  (func (export "last") (result u32) (canon lift (core func $d "last")))
                )
                """)
            guard case .own(let resource) = try instance.exportedFunction("[constructor]r")!.invoke([.u32(9)]).first else {
                Issue.record("the constructor returned no owned resource")
                return
            }
            #expect(u32(try instance.exportedFunction("drops")!.invoke([])) == 0)
            try resource.drop()
            #expect(u32(try instance.exportedFunction("drops")!.invoke([])) == 1)
            #expect(u32(try instance.exportedFunction("last")!.invoke([])) == 9)
        }
    }
#endif
