#if ComponentModel
    import ComponentModel
    import WasmTypes

    // MARK: - Component Instance

    /// Internal representation of an instantiated component.
    /// This stores all the runtime state for a component instance.
    struct ComponentInstanceEntity {
        /// Core module instances created during instantiation
        var coreInstances: [InternalInstance]

        /// Exported values accessible by name
        var exports: [String: InternalComponentExternalValue]

        /// Component-level functions (lifted core functions)
        var functions: [InternalComponentFunction]

        /// Nested component instances
        var nestedComponents: [InternalComponentInstance]

        /// The instance's handle table, or `nil` for an instance of inline exports or a host's.
        var state: ComponentInstanceState? = nil
    }

    /// Type-safe handle to a component instance entity.
    typealias InternalComponentInstance = EntityHandle<ComponentInstanceEntity>

    extension InternalComponentInstance {
        var exports: [String: InternalComponentExternalValue] { withValue { $0.exports } }
    }

    /// A stateful instance of a WebAssembly component.
    /// Created by instantiating a component with resolved imports.
    public struct ComponentInstance {
        let handle: InternalComponentInstance
        let store: Store

        init(handle: InternalComponentInstance, store: Store) {
            self.handle = handle
            self.store = store
        }

        /// Returns the exported value with the given name.
        public func export(_ name: String) -> ComponentExternalValue? {
            guard let entity = handle.exports[name] else { return nil }
            return ComponentExternalValue(handle: entity, store: store)
        }

        /// Returns the exported component function with the given name.
        public func exportedFunction(_ name: String) -> ComponentFunction? {
            guard case .function(let function) = export(name) else { return nil }
            return function
        }

        /// A dictionary of exported values by name.
        public var exports: ComponentExports {
            ComponentExports(store: store, items: handle.exports)
        }

        /// Creates an instance a host implements, of the given exports, to import into
        /// components.
        public init(store: Store, exports: [String: ComponentExternalValue]) {
            let entity = ComponentInstanceEntity(
                coreInstances: [],
                exports: exports.mapValues { $0.internalize() },
                functions: [],
                nestedComponents: []
            )
            self.init(handle: store.allocator.allocate(componentInstance: entity), store: store)
        }
    }

    /// A map of exported component values by name.
    public struct ComponentExports: Sequence {
        let store: Store
        let items: [String: InternalComponentExternalValue]

        /// Returns the exported value with the given name.
        public subscript(_ name: String) -> ComponentExternalValue? {
            guard let entity = items[name] else { return nil }
            return ComponentExternalValue(handle: entity, store: store)
        }

        /// Returns the exported function with the given name.
        public subscript(function name: String) -> ComponentFunction? {
            guard case .function(let function) = self[name] else { return nil }
            return function
        }

        public struct Iterator: IteratorProtocol {
            private let store: Store
            private var iterator: Dictionary<String, InternalComponentExternalValue>.Iterator

            init(parent: ComponentExports) {
                self.store = parent.store
                self.iterator = parent.items.makeIterator()
            }

            public mutating func next() -> (name: String, value: ComponentExternalValue)? {
                guard let (name, entity) = iterator.next() else { return nil }
                return (name, ComponentExternalValue(handle: entity, store: store))
            }
        }

        public func makeIterator() -> Iterator {
            Iterator(parent: self)
        }
    }

    // MARK: - Component External Values

    /// A type as an instance exports it: what it names, and the space its indices resolve in.
    struct ComponentRuntimeType {
        let entry: ComponentTypeSpace.Entry
        let space: ComponentTypeSpace
        /// The type's index where it was exported, which ``ComponentExternalValue/type(_:)``
        /// shows for a type that is not a resource.
        let index: ComponentTypeIndex

        var resource: ComponentResourceType? {
            guard case .resource(let type) = entry else { return nil }
            return type
        }
    }

    /// Internal representation of component-level external values (import/export).
    enum InternalComponentExternalValue {
        case function(InternalComponentFunction)
        case value(ComponentValue)
        case type(ComponentRuntimeType)
        case instance(InternalComponentInstance)
        /// A core module definition (from modules index space)
        case coreModule(Module)
        /// A core module instance (from core instances index space)
        case coreInstance(InternalInstance)
        /// A component definition (from components index space)
        case component(ComponentDefinition)

        /// The value's sort as the component model text format names it, for error messages.
        var sortDescription: String {
            switch self {
            case .function: return "func"
            case .value: return "value"
            case .type(let type): return type.resource == nil ? "type" : "resource"
            case .instance: return "instance"
            case .coreModule: return "module"
            case .coreInstance: return "core instance"
            case .component: return "component"
            }
        }

        /// Describe an internal external value for error messages.
        var tagDescription: String {
            switch self {
            case .function: return "function"
            case .value: return "value"
            case .type(let type): return type.resource == nil ? "type" : "resource"
            case .instance: return "instance"
            case .coreModule: return "coreModule"
            case .coreInstance: return "coreInstance"
            case .component: return "component"
            }
        }
    }

    /// Public representation of component-level external values.
    public enum ComponentExternalValue {
        case function(ComponentFunction)
        case value(ComponentValue)
        /// A type other than a resource type, by its index in the component that exported it.
        case type(ComponentTypeIndex)
        /// A resource type.
        case resourceType(ComponentResourceType)
        case instance(ComponentInstance)
        /// A core module definition (from modules index space)
        case coreModule(Module)
        /// A core module instance (from core instances index space)
        case coreInstance(Instance)
        /// A component definition (from components index space)
        case component(ParsedComponent)

        init(handle: InternalComponentExternalValue, store: Store) {
            switch handle {
            case .function(let function):
                self = .function(ComponentFunction(handle: function, store: store))
            case .value(let value):
                self = .value(value)
            case .type(let type):
                if let resource = type.resource {
                    self = .resourceType(resource)
                } else {
                    self = .type(type.index)
                }
            case .instance(let instance):
                self = .instance(ComponentInstance(handle: instance, store: store))
            case .coreModule(let module):
                self = .coreModule(module)
            case .coreInstance(let moduleInstance):
                self = .coreInstance(Instance(handle: moduleInstance, store: store))
            case .component(let definition):
                self = .component(definition.component)
            }
        }
    }

    // MARK: - Component Function

    /// Internal storage for a component function: a core function lifted with the canonical
    /// ABI, or one a host implements.
    struct ComponentFunctionEntity {
        /// The lifted function type (component-level signature)
        let type: ComponentFuncType

        /// What the type indices in `type` name
        let types: ComponentTypeSpace

        let implementation: Implementation

        enum Implementation {
            /// A core function lifted by a `canon lift` in the instance `instance`.
            case lifted(coreFunction: InternalFunction, canonOptions: CanonOptions, instance: ComponentInstanceState)
            /// A host function, given and returning component values.
            case host(([ComponentValue]) throws -> [ComponentValue])
        }
    }

    /// Type-safe handle to a component function entity.
    typealias InternalComponentFunction = EntityHandle<ComponentFunctionEntity>

    extension InternalComponentFunction {
        var type: ComponentFuncType { withValue { $0.type } }
        var types: ComponentTypeSpace { withValue { $0.types } }
        var implementation: ComponentFunctionEntity.Implementation { withValue { $0.implementation } }
    }

    /// A type a host function's type refers to, by its position in the list it is given in.
    public enum ComponentHostTypeDefinition {
        case value(ComponentDefValType)
        case resource(ComponentResourceType)
    }

    /// A component function that can be invoked with component-level values.
    /// Component functions lift core Wasm values to component values on return
    /// and lower component values to core Wasm values on call.
    public struct ComponentFunction {
        let handle: InternalComponentFunction
        let store: Store

        init(handle: InternalComponentFunction, store: Store) {
            self.handle = handle
            self.store = store
        }

        /// Creates a component function a host implements, to import into components.
        ///
        /// Resources come to `implementation` as ``ComponentValue/own(_:)`` and
        /// ``ComponentValue/borrow(_:)``. A borrow is valid only until it returns; an owned
        /// resource is the host's to keep or pass on.
        ///
        /// - Parameters:
        ///   - store: The store to allocate the function in.
        ///   - type: The function's type.
        ///   - types: The types that the type indices in `type` name, in index order.
        ///   - implementation: The function's body.
        public init(
            store: Store,
            type: ComponentFuncType,
            types: [ComponentHostTypeDefinition] = [],
            implementation: @escaping ([ComponentValue]) throws -> [ComponentValue]
        ) {
            let space = ComponentTypeSpace()
            for definition in types {
                switch definition {
                case .value(let type): space.append(.value(type))
                case .resource(let type): space.append(.resource(type))
                }
            }
            let entity = ComponentFunctionEntity(type: type, types: space, implementation: .host(implementation))
            self.init(handle: store.allocator.allocate(componentFunction: entity), store: store)
        }

        /// The component-level function type.
        public var type: ComponentFuncType {
            handle.type
        }

        /// Resolves a type index to its component value type.
        /// Used for parsing nested types in WAVE arguments.
        public func resolveType(_ index: ComponentTypeIndex) throws -> ComponentDefValType {
            try handle.types.valueType(index)
        }

        /// Invokes the component function with the given arguments.
        ///
        /// - Parameter arguments: The component-level arguments to pass to the function.
        /// - Returns: The component-level results.
        /// - Throws: A trap if the function invocation fails.
        @discardableResult
        public func invoke(_ arguments: [ComponentValue] = []) throws -> [ComponentValue] {
            switch handle.implementation {
            case .host(let implementation):
                return try implementation(arguments)
            case .lifted(let coreFunction, let canonOptions, let instance):
                return try instance.enterCall { scope in
                    try invokeLifted(
                        arguments, coreFunction: coreFunction, canonOptions: canonOptions, instance: instance, scope: scope)
                }
            }
        }

        /// The spec's `canon_lift`, for a call made in `scope`.
        private func invokeLifted(
            _ arguments: [ComponentValue], coreFunction: InternalFunction, canonOptions: CanonOptions,
            instance: ComponentInstanceState, scope: CallScope
        ) throws -> [ComponentValue] {
            var context = CanonicalABIContext(
                types: CanonicalABITypes(space: handle.types), options: canonOptions, store: store,
                instance: instance, scope: scope)
            let type = handle.type

            // 1. Lower the arguments into core values, or into memory if there are too many.
            let coreArguments = try instance.withoutLeaving { try context.lowerArguments(arguments, of: type) }

            // 2. Call the core function.
            var stack = ExecutionStack(pool: store.executionStacks)
            let coreResults = try coreFunction.invoke(coreArguments, store: store, stack: &stack)

            // 3. Lift the results, from core values or through the pointer the callee returned.
            let results = try context.liftResults(coreResults, of: type)

            // 4. Let the callee free what the results pointed to.
            if let postReturn = canonOptions.postReturn {
                _ = try instance.withoutLeaving { try postReturn.invoke(coreResults, store: store, stack: &stack) }
            }

            return results
        }

        /// Invokes the component function with the given arguments.
        @discardableResult
        public func callAsFunction(_ arguments: [ComponentValue] = []) throws -> [ComponentValue] {
            try invoke(arguments)
        }
    }

    // MARK: - Canon Options

    /// Options for canonical lifting/lowering operations.
    struct CanonOptions {
        /// The memory to use for string and list operations
        var memory: InternalMemory?

        /// The realloc function to use for allocating memory
        var realloc: InternalFunction?

        /// The post-return function to call after returning
        var postReturn: InternalFunction?

        /// The string encoding to use
        var stringEncoding: ComponentStringEncoding

        init(
            memory: InternalMemory? = nil,
            realloc: InternalFunction? = nil,
            postReturn: InternalFunction? = nil,
            stringEncoding: ComponentStringEncoding = .utf8
        ) {
            self.memory = memory
            self.realloc = realloc
            self.postReturn = postReturn
            self.stringEncoding = stringEncoding
        }
    }

#endif
