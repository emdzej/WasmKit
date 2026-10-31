#if ComponentModel
    import ComponentModel
    import WasmParser

    // MARK: - Component Imports

    /// A set of entities used to import values when instantiating a component.
    ///
    /// A `ComponentImports` instance is used to define values that are imported by a
    /// WebAssembly component. The values can be functions, values, types, instances, or modules.
    public struct ComponentImports {
        fileprivate var definitions: [String: InternalComponentExternalValue] = [:]

        /// Initializes a new empty instance of `ComponentImports`.
        public init() {}

        /// Define a value to be imported by the given name.
        public mutating func define(name: String, _ value: ComponentExternalValue) {
            definitions[name] = value.internalize()
        }

        /// Define a function to be imported by the given name.
        public mutating func define(name: String, function: ComponentFunction) {
            definitions[name] = .function(function.handle)
        }

        /// Define an instance to be imported by the given name.
        public mutating func define(name: String, instance: ComponentInstance) {
            definitions[name] = .instance(instance.handle)
        }

        /// Define a core module instance to be imported by the given name.
        public mutating func define(name: String, coreInstance: Instance) {
            definitions[name] = .coreInstance(coreInstance.handle)
        }

        /// Define a core module definition to be imported by the given name.
        public mutating func define(name: String, coreModule: Module) {
            definitions[name] = .coreModule(coreModule)
        }

        /// Define a component definition to be imported by the given name.
        public mutating func define(name: String, component: ParsedComponent) {
            definitions[name] = .component(ComponentDefinition(component: component, outer: []))
        }

        /// Lookup a value to be imported by the given name.
        func lookup(name: String) -> InternalComponentExternalValue? {
            definitions[name]
        }
    }

    // MARK: - Component Linker

    /// Resolves component imports and performs instantiation.
    ///
    /// The `ComponentLoader` is responsible for taking a parsed component definition
    /// and creating a runtime `ComponentInstance` by:
    /// 1. Resolving imports from the provided `ComponentImports`
    /// 2. Instantiating nested core modules
    /// 3. Creating lifted component functions via canonical definitions
    /// 4. Building the exports map
    public struct ComponentLoader {
        /// How strictly imports' types must match the types a component declares for them.
        public enum ImportTypeChecking: Sendable {
            /// Function parameter names may differ, as wasmtime's linker allows.
            case lenient
            /// Function parameter names must match too, as wasm-tools' validator requires of
            /// one component instantiating another.
            case strict
        }

        let store: Store
        let importTypeChecking: ImportTypeChecking

        /// Creates a new component linker for the given store.
        ///
        /// - Parameters:
        ///   - store: The store components are instantiated in.
        ///   - importTypeChecking: How strictly imports' types are checked. Either way, their
        ///     parameter, result and value types must match the declared ones.
        public init(store: Store, importTypeChecking: ImportTypeChecking = .lenient) {
            self.store = store
            self.importTypeChecking = importTypeChecking
        }

        /// Instantiate a component with the given imports.
        ///
        /// - Parameters:
        ///   - component: The parsed component definition to instantiate.
        ///   - imports: The imports to satisfy the component's import requirements.
        /// - Returns: A new `ComponentInstance`.
        /// - Throws: A `ComponentLoaderError` if instantiation fails.
        public func instantiate(
            component: ParsedComponent,
            imports: ComponentImports = ComponentImports()
        ) throws -> ComponentInstance {
            try instantiate(ComponentDefinition(component: component, outer: []), imports: imports)
        }

        /// How deeply instantiations may nest: one component's definitions instantiating another,
        /// and so on. Each level recurses, and nesting alone does not bound it, as a component
        /// can instantiate one defined before it in an enclosing component: in a debug build a
        /// chain of 50 to 70 overflowed a test thread's stack. As for nesting, which also limits
        /// the parser, real components go a handful deep.
        static let maxInstantiationDepth = 32

        /// Instantiates a component definition, whose outer aliases resolve against the
        /// components it was defined in, inside `depth` other instantiations.
        func instantiate(
            _ definition: ComponentDefinition,
            imports: ComponentImports,
            depth: Int = 0
        ) throws -> ComponentInstance {
            guard depth <= Self.maxInstantiationDepth else {
                throw ComponentLoaderError.instantiationFailed(
                    "components instantiate each other more than \(Self.maxInstantiationDepth) deep")
            }
            let component = definition.component
            // Step 0: Validate imports
            try validateImports(component.imports, against: imports)

            var context = InstantiationContext(
                store: store,
                imports: imports,
                outer: definition.outer,
                depth: depth
            )

            // Step 1: Process definitions in the order they appear in the binary. Each kind of
            // definition appends to its index space, and those spaces interleave: a core
            // function alias before a `canon lower` takes the lower index, so processing kinds in
            // fixed phases would bind references to the wrong definitions.
            for definition in Self.definitionOrder(of: component) {
                switch definition {
                case .component(let index):
                    guard component.nestedComponents.indices.contains(index) else {
                        throw ComponentLoaderError.invalidComponentIndex(index)
                    }
                    context.components.append(.local(component.nestedComponents[index]))
                case .coreModule(let index):
                    guard component.coreModules.indices.contains(index) else {
                        throw ComponentLoaderError.invalidCoreModuleIndex(index)
                    }
                    context.coreModules.append(component.coreModules[index].module)
                case .type(let index):
                    try processTypeDef(component.componentTypes[index], context: &context)
                case .import(let index):
                    try processImport(component.imports[index], context: &context)
                case .export(let index):
                    try processExport(component.exports[index], context: &context)
                case .coreInstance(let index):
                    try processCoreInstanceDef(component.coreInstanceDefs[index], context: &context)
                case .componentInstance(let index):
                    try processComponentInstanceDef(component.componentInstances[index], context: &context)
                case .alias(let index):
                    try processAlias(component.aliases[index], context: &context)
                case .canon(let index):
                    let canonDef = component.canonicalDefinitions[index]
                    switch canonDef.kind {
                    case .lift, .liftCoreFunction:
                        context.componentFunctions.append(try processCanonLift(canonDef, context: &context))
                    case .lower:
                        context.coreFunctions.append(try processCanonLower(canonDef, context: &context))
                    }
                case .resourceIntrinsic(let intrinsic):
                    context.coreFunctions.append(try processResourceIntrinsic(intrinsic, context: &context))
                }
            }

            // Step 2: Allocate the component instance
            var entity = ComponentInstanceEntity(
                coreInstances: context.coreInstances,
                exports: context.exports,
                functions: context.componentFunctions,
                nestedComponents: context.nestedComponents
            )
            entity.state = context.state

            let handle = store.allocator.allocate(componentInstance: entity)
            return ComponentInstance(handle: handle, store: store)
        }
    }

    extension ComponentLoader {
        /// The order to process `component`'s definitions in: the binary's, as the parser
        /// records it. A component built by hand without one gets the phases this loader used
        /// before it followed the binary, which suits definitions listed by kind.
        static func definitionOrder(of component: ParsedComponent) -> [ParsedOrderedDefinition] {
            if !component.orderedDefinitions.isEmpty {
                return component.orderedDefinitions
            }
            var order: [ParsedOrderedDefinition] = []
            order += component.nestedComponents.indices.map { .component(index: $0) }
            order += component.coreModules.indices.map { .coreModule(index: $0) }
            order += component.componentTypes.indices.map { .type(index: $0) }
            order += component.imports.indices.map { .import(index: $0) }
            order += component.componentInstances.indices.map { .componentInstance(index: $0) }
            func isFunctionAlias(_ index: Int) -> Bool {
                if case .func = component.aliases[index].sort { return true } else { return false }
            }
            order += component.aliases.indices.filter(isFunctionAlias).map { .alias(index: $0) }
            order += component.canonicalDefinitions.indices.filter {
                if case .lower = component.canonicalDefinitions[$0].kind { return true } else { return false }
            }.map { .canon(index: $0) }
            order += component.coreInstanceDefs.indices.map { .coreInstance(index: $0) }
            order += component.aliases.indices.filter { !isFunctionAlias($0) }.map { .alias(index: $0) }
            order += component.canonicalDefinitions.indices.filter {
                if case .lower = component.canonicalDefinitions[$0].kind { return false } else { return true }
            }.map { .canon(index: $0) }
            order += component.exports.indices.map { .export(index: $0) }
            return order
        }
    }

    // MARK: - Instantiation Context

    /// Internal context used during component instantiation.
    struct InstantiationContext {
        let store: Store
        let imports: ComponentImports

        /// The instance's handle table, which every `canon` definition in it uses
        let state = ComponentInstanceState()

        /// The type index space
        let types = ComponentTypeSpace()

        /// The enclosing components, innermost first
        let outer: [OuterScope]

        /// Core module definitions (from modules index space)
        var coreModules: [Module] = []

        /// Core module instances created during instantiation (from core instances index space)
        var coreInstances: [InternalInstance] = []

        /// Core functions created from canonical lower definitions (from core functions index space)
        var coreFunctions: [InternalFunction] = []

        /// The core table, memory and global index spaces, which aliases of core instance
        /// exports add to
        var coreTables: [Table] = []
        var coreMemories: [Memory] = []
        var coreGlobals: [Global] = []
        var coreTags: [Tag] = []

        /// The component instance index space: imported and nested instances, in the order they
        /// were defined. Every instance index resolves against this.
        var componentInstances: [InternalComponentInstance] = []

        /// Component functions from imports, aliases, and canonical lift definitions
        var componentFunctions: [InternalComponentFunction] = []

        /// The component index space: nested and imported component definitions
        var components: [ComponentEntry] = []

        /// Nested component instances (from component instances index space)
        var nestedComponents: [InternalComponentInstance] = []

        /// The component's exports so far
        var exports: [String: InternalComponentExternalValue] = [:]

        /// How many instantiations this one is inside.
        let depth: Int

        init(store: Store, imports: ComponentImports, outer: [OuterScope], depth: Int) {
            self.store = store
            self.imports = imports
            self.outer = outer
            self.depth = depth
        }

        /// The component `count` out from this one: 0 for this one.
        func outerScope(count: Int) throws -> OuterScope {
            if count == 0 { return OuterScope(types: types, components: components, coreModules: coreModules) }
            guard outer.indices.contains(count - 1) else {
                throw ComponentLoaderError.instantiationFailed("outer alias count \(count) leaves the outermost component")
            }
            return outer[count - 1]
        }

        /// The component at `index` in the component `count` out from this one: 0 for this one.
        func component(_ index: Int, outerCount count: Int = 0) throws -> ComponentDefinition {
            let scope = try outerScope(count: count)
            guard scope.components.indices.contains(index) else {
                throw ComponentLoaderError.invalidComponentIndex(index)
            }
            switch scope.components[index] {
            case .definition(let definition):
                return definition
            case .local(let component):
                // What it sees of the component it is defined in is what was defined before it,
                // as an outer alias can only refer to those.
                let definedIn = OuterScope(
                    types: scope.types, components: Array(scope.components.prefix(index)), coreModules: scope.coreModules)
                return ComponentDefinition(component: component, outer: [definedIn] + outer.dropFirst(count))
            }
        }

        /// The type space `count` components out from this one: 0 for this one.
        func typeSpace(outerCount count: Int) throws -> ComponentTypeSpace {
            try outerScope(count: count).types
        }

        /// The type at `index`, as an export or import argument carries it.
        func runtimeType(_ index: ComponentTypeIndex) throws -> ComponentRuntimeType {
            ComponentRuntimeType(entry: try types.entry(index), space: types, index: index)
        }
    }

    /// What an outer alias can refer to in an enclosing component.
    struct OuterScope {
        let types: ComponentTypeSpace
        let components: [ComponentEntry]
        let coreModules: [Module]
    }

    /// An entry in a component's component index space.
    ///
    /// One defined there is kept as parsed, and given the scopes it sees when it is used: were
    /// each to keep a copy of the definitions before it, each with its own copy, a list of
    /// sibling components would be a chain as long as the list, freed recursively, which for
    /// a thousand of them overflowed the stack, and as large as the square of its length.
    enum ComponentEntry {
        case local(ParsedComponent)
        /// An imported or aliased one, which carries its scopes.
        case definition(ComponentDefinition)
    }

    /// A component definition, with the enclosing components its outer aliases refer to.
    struct ComponentDefinition {
        let component: ParsedComponent
        let outer: [OuterScope]
    }

    // MARK: - Parsed Component Representation

    /// A parsed component ready for instantiation.
    /// This represents the output of parsing a component WAT/binary file.
    public struct ParsedComponent {
        /// Core modules embedded in this component
        public var coreModules: [ParsedCoreModule] = []

        /// Core instance definitions (from core instances index space)
        /// This includes both inline exports and module instantiations in binary order.
        public var coreInstanceDefs: [ParsedCoreInstanceDef] = []

        /// Nested components embedded in this component (recursively parsed)
        public var nestedComponents: [ParsedComponent] = []

        /// Component instance definitions (instantiate or inline exports)
        public var componentInstances: [ParsedComponentInstanceDef] = []

        /// Canonical definitions (lift/lower)
        public var canonicalDefinitions: [ParsedCanonicalDefinition] = []

        /// Aliases that populate index spaces
        public var aliases: [ParsedAlias] = []

        /// Interleaved definitions that must be processed in binary order.
        /// This preserves the semantic ordering of definitions that have dependencies.
        public var orderedDefinitions: [ParsedOrderedDefinition] = []

        /// Component exports
        public var exports: [ParsedComponentExport] = []

        /// Component imports
        public var imports: [ParsedComponentImport] = []

        /// The type section entries, in order
        public var componentTypes: [ComponentTypeDef] = []

        public init() {}

        /// Resolve an index into `componentTypes` to the value type defined there.
        ///
        /// The index is a position in the type sections, which is a type index only while no
        /// import, alias or export has added one: the loader resolves the type index space of
        /// each instance as it instantiates it.
        public func resolveType(_ index: ComponentTypeIndex) throws -> ComponentDefValType {
            let idx = Int(index.rawValue)
            guard idx < componentTypes.count else {
                throw CanonicalABIError(description: "Type index \(idx) out of bounds (have \(componentTypes.count) types)")
            }
            let typeDef = componentTypes[idx]
            guard case .definedValue(let valueType) = typeDef else {
                throw CanonicalABIError(description: "Type index \(idx) is not a defined value type")
            }
            return valueType
        }
    }

    /// A definition that must be processed in binary order.
    /// Used to preserve semantic ordering for definitions with dependencies.
    public enum ParsedOrderedDefinition {
        /// A nested component, by its index in `nestedComponents`
        case component(index: Int)
        /// A core module, by its index in `coreModules`
        case coreModule(index: Int)
        /// A type definition, by its index in `componentTypes`
        case type(index: Int)
        /// An import, by its index in `imports`
        case `import`(index: Int)
        /// An export, by its index in `exports`
        case export(index: Int)
        /// A core instance definition
        case coreInstance(index: Int)
        /// A component instance definition
        case componentInstance(index: Int)
        /// An alias definition
        case alias(index: Int)
        /// A canonical definition (lift or lower)
        case canon(index: Int)
        /// A `resource.new`, `resource.drop` or `resource.rep`, which defines a core function
        case resourceIntrinsic(ParsedResourceIntrinsic)
    }

    /// A canonical built-in on resources of the type at an index.
    public enum ParsedResourceIntrinsic {
        case new(typeIndex: ComponentTypeIndex)
        case drop(typeIndex: ComponentTypeIndex)
        case rep(typeIndex: ComponentTypeIndex)
    }

    /// A core instance definition.
    public enum ParsedCoreInstanceDef {
        /// Instantiate a core module with arguments
        case instantiate(moduleIndex: Int, args: [ParsedCoreInstantiateArg])
        /// Inline exports forming an instance
        case exports([ParsedCoreInlineExport])
    }

    /// An argument for core module instantiation.
    public struct ParsedCoreInstantiateArg {
        /// The import name to satisfy
        public let name: String
        /// The core instance index providing the exports
        public let instanceIndex: Int

        public init(name: String, instanceIndex: Int) {
            self.name = name
            self.instanceIndex = instanceIndex
        }
    }

    /// An inline export in a core instance.
    public struct ParsedCoreInlineExport {
        /// The export name
        public let name: String
        /// The sort of the export
        public let sort: CoreDefSort
        /// The index in the corresponding core index space
        public let index: Int

        public init(name: String, sort: CoreDefSort, index: Int) {
            self.name = name
            self.sort = sort
            self.index = index
        }
    }

    /// A component instance definition.
    public enum ParsedComponentInstanceDef {
        /// Instantiate a nested component with arguments
        case instantiate(componentIndex: Int, args: [ParsedComponentInstantiateArg])
        /// Inline exports forming an instance
        case exports([ParsedComponentInlineExport])
    }

    /// An argument for component instantiation.
    public struct ParsedComponentInstantiateArg {
        /// The import name to satisfy
        public let name: String
        /// The sort of the argument
        public let sort: ComponentDefSort
        /// The index in the corresponding index space
        public let index: Int

        public init(name: String, sort: ComponentDefSort, index: Int) {
            self.name = name
            self.sort = sort
            self.index = index
        }
    }

    /// An inline export in a component instance.
    public struct ParsedComponentInlineExport {
        /// The export name
        public let name: String
        /// The sort of the export
        public let sort: ComponentDefSort
        /// The index in the corresponding index space
        public let index: Int

        public init(name: String, sort: ComponentDefSort, index: Int) {
            self.name = name
            self.sort = sort
            self.index = index
        }
    }

    /// A core module embedded within a component.
    public struct ParsedCoreModule {
        /// The parsed core module
        public let module: Module

        /// Optional name for this module
        public let name: String?

        /// Import arguments for instantiation
        public var instantiateArgs: [ParsedInstantiateArg] = []

        public init(module: Module, name: String? = nil) {
            self.module = module
            self.name = name
        }
    }

    /// An argument for core module instantiation.
    public struct ParsedInstantiateArg {
        /// The import name to satisfy
        public let importName: String

        /// The source of the import value
        public let source: ParsedInstantiateArgSource

        public init(importName: String, source: ParsedInstantiateArgSource) {
            self.importName = importName
            self.source = source
        }
    }

    /// The source of an instantiate argument.
    public enum ParsedInstantiateArgSource {
        /// From another core instance's exports
        case coreInstance(index: Int)

        /// From a component import
        case componentImport(name: String)
    }

    /// A canonical definition (lift or lower).
    public struct ParsedCanonicalDefinition {
        /// The kind of canonical definition
        public let kind: ParsedCanonicalKind

        /// Canon options
        public var options: ParsedCanonOptions

        public init(kind: ParsedCanonicalKind, options: ParsedCanonOptions = ParsedCanonOptions()) {
            self.kind = kind
            self.options = options
        }
    }

    /// The kind of canonical definition.
    public enum ParsedCanonicalKind {
        /// Lift a core function to a component function
        case lift(coreInstanceIndex: Int, functionName: String, type: ComponentFuncType)

        /// Lift the core function at an index in the core function index space, such as a
        /// `resource.new`, to a component function
        case liftCoreFunction(coreFunctionIndex: Int, type: ComponentFuncType)

        /// Lower a component function to a core function
        case lower(componentFunctionIndex: Int)
    }

    /// Parsed canonical options.
    public struct ParsedCanonOptions {
        /// Memory to use for string/list operations
        public var memory: ParsedCanonMemory?

        /// Realloc function for allocation
        public var realloc: ParsedCanonFunc?

        /// Post-return cleanup function
        public var postReturn: ParsedCanonFunc?

        /// String encoding
        public var stringEncoding: ComponentStringEncoding = .utf8

        public init() {}
    }

    /// Reference to a memory for canonical options.
    public struct ParsedCanonMemory {
        public let coreInstanceIndex: Int
        public let memoryName: String

        public init(coreInstanceIndex: Int, memoryName: String) {
            self.coreInstanceIndex = coreInstanceIndex
            self.memoryName = memoryName
        }
    }

    /// Reference to a function for canonical options.
    public struct ParsedCanonFunc {
        public let coreInstanceIndex: Int
        public let functionName: String

        public init(coreInstanceIndex: Int, functionName: String) {
            self.coreInstanceIndex = coreInstanceIndex
            self.functionName = functionName
        }
    }

    /// A component export definition.
    public struct ParsedComponentExport {
        /// The export name
        public let name: String

        /// The kind of export
        public let kind: ParsedComponentExportKind

        public init(name: String, kind: ParsedComponentExportKind) {
            self.name = name
            self.kind = kind
        }
    }

    /// The kind of component export.
    public enum ParsedComponentExportKind {
        /// Export a component function
        case function(index: Int)

        /// Export a value
        case value(ComponentValue)

        /// Export a type
        case type(ComponentTypeIndex)

        /// Export a nested component instance
        case instance(index: Int)

        /// Export a core module definition (from modules index space)
        case coreModule(moduleIndex: Int)

        /// Export a core module instance (from core instances index space)
        case coreInstance(instanceIndex: Int)

        /// Export a component definition (from components index space)
        case component(index: Int)
    }

    /// A component import definition.
    public struct ParsedComponentImport {
        /// The import name
        public let name: String

        /// The expected type of the import
        public let kind: ParsedComponentImportKind

        /// The index of the instance or component type an instance or component import
        /// declares, which the provided instance or component is checked against
        public let declaredType: ComponentTypeIndex?

        /// The type a core module import declares, which the provided module is checked against
        public let declaredModuleType: CoreModuleType?

        public init(
            name: String, kind: ParsedComponentImportKind, declaredType: ComponentTypeIndex? = nil,
            declaredModuleType: CoreModuleType? = nil
        ) {
            self.name = name
            self.kind = kind
            self.declaredType = declaredType
            self.declaredModuleType = declaredModuleType
        }
    }

    /// The kind of component import.
    public enum ParsedComponentImportKind {
        /// Import a function of the type at this index, which is resolved when the component is
        /// instantiated, as it can be one an alias brings in
        case function(ComponentTypeIndex)

        /// Import a value
        case value(ComponentDefValType)

        /// Import an instance
        case instance

        /// Import a module
        case module

        /// Import a type, such as a resource type
        case type(ComponentTypeBound)

        /// Import a component definition
        case component
    }

    /// An alias definition that populates an index space.
    public struct ParsedAlias {
        /// The sort of the alias (what kind of thing it creates)
        public let sort: ComponentDefSort

        /// The source of the alias
        public let source: ParsedAliasSource

        public init(sort: ComponentDefSort, source: ParsedAliasSource) {
            self.sort = sort
            self.source = source
        }
    }

    /// The source of an alias.
    public enum ParsedAliasSource {
        /// Alias from a component instance export
        case componentInstanceExport(instanceIndex: Int, name: String)
        /// Alias from a core instance export
        case coreInstanceExport(instanceIndex: Int, name: String)
        /// Alias from outer scope
        case outer(count: Int, index: Int)
    }

    // MARK: - Component Link Error

    /// Errors that can occur during component linking.
    public enum ComponentLoaderError: Error {
        /// A required import was not provided
        case missingImport(name: String)

        /// An import has an incompatible type
        case incompatibleImport(name: String, expected: String, got: String)

        /// A core module index is out of bounds (modules index space)
        case invalidCoreModuleIndex(Int)

        /// A core instance index is out of bounds (core instances index space)
        case invalidCoreInstanceIndex(Int)

        /// A core function index is out of bounds (core functions index space)
        case invalidCoreFunctionIndex(Int)

        /// A component index is out of bounds (components index space)
        case invalidComponentIndex(Int)

        /// A component function index is out of bounds
        case invalidComponentFunctionIndex(Int)

        /// Failed to resolve a core function export
        case coreExportNotFound(instanceIndex: Int, name: String)

        /// Failed to resolve a core memory export
        case coreMemoryNotFound(instanceIndex: Int, name: String)

        /// Canon lift requires a memory but none was provided
        case missingCanonMemory

        /// An instance import lacks an export its type declares
        case instanceExportNotFound(importName: String, exportName: String)

        /// A resource type import, or an instance's resource type export, is not the resource
        /// type an equality bound requires
        case mismatchedResourceTypes(name: String)

        /// An import, or an instance import's export, has a function or value type other than
        /// the one declared for it
        case mismatchedImportType(name: String, reason: String)

        /// General instantiation failure
        case instantiationFailed(String)
    }

    extension ComponentLoaderError: CustomStringConvertible {
        public var description: String {
            switch self {
            case .missingImport(let name): return "import \"\(name)\" was not found"
            case .incompatibleImport(let name, let expected, let got):
                return "import \"\(name)\": expected \(expected) found \(got)"
            case .invalidCoreModuleIndex(let index): return "core module index \(index) out of bounds"
            case .invalidCoreInstanceIndex(let index): return "core instance index \(index) out of bounds"
            case .invalidCoreFunctionIndex(let index): return "core function index \(index) out of bounds"
            case .invalidComponentIndex(let index): return "component index \(index) out of bounds"
            case .invalidComponentFunctionIndex(let index): return "component function index \(index) out of bounds"
            case .coreExportNotFound(let instanceIndex, let name):
                return "core instance \(instanceIndex) has no function export \"\(name)\""
            case .coreMemoryNotFound(let instanceIndex, let name):
                return "core instance \(instanceIndex) has no memory export \"\(name)\""
            case .missingCanonMemory: return "canon lift requires a memory but none was provided"
            case .instanceExportNotFound(let importName, let exportName):
                return "import \"\(importName)\": instance export \"\(exportName)\" was not found"
            case .mismatchedResourceTypes(let name): return "\"\(name)\": mismatched resource types"
            case .mismatchedImportType(let name, let reason): return "type mismatch for import `\(name)`: \(reason)"
            case .instantiationFailed(let message): return message
            }
        }
    }

    // MARK: - Private Implementation

    extension ComponentLoader {
        /// Process an import definition to populate the appropriate index space.
        private func processImport(
            _ importDef: ParsedComponentImport,
            context: inout InstantiationContext
        ) throws {
            var declaration: ComponentTypeSpace.Entry?
            if let typeIndex = importDef.declaredType {
                declaration = try context.types.entry(typeIndex)
            }
            let value: InternalComponentExternalValue
            if let provided = context.imports.lookup(name: importDef.name) {
                value = provided
            } else if case .instance(let declaration) = declaration, Self.isEmpty(declaration) {
                // As in wasmtime, an instance with nothing to export need not be provided.
                value = .instance(
                    store.allocator.allocate(
                        componentInstance: ComponentInstanceEntity(coreInstances: [], exports: [:], functions: [], nestedComponents: [])))
            } else {
                throw ComponentLoaderError.missingImport(name: importDef.name)
            }

            switch (importDef.kind, value) {
            case (.instance, .instance(let instance)):
                if case .instance(let declaration) = declaration {
                    try checkInstance(instance, against: declaration, name: importDef.name) {
                        try context.typeSpace(outerCount: $0 - 1)
                    }
                }
                context.componentInstances.append(instance)
            case (.function(let typeIndex), .function(let function)):
                try checkFunction(function, against: try context.types.functionType(typeIndex), in: context.types, name: importDef.name)
                context.componentFunctions.append(function)
            case (.value(let type), .value(let value)):
                try checkValue(value, against: type, in: context.types, name: importDef.name)
            case (.module, .coreModule(let module)):
                if let declared = importDef.declaredModuleType {
                    try checkModule(module, against: declared, name: importDef.name)
                }
                context.coreModules.append(module)
            case (.component, .component(let definition)):
                if case .component(let declaration) = declaration {
                    try checkComponent(definition, against: declaration, name: importDef.name)
                }
                context.components.append(.definition(definition))
            case (.type(let bound), let value):
                context.types.append(try importedType(value, bound: bound, name: importDef.name, scope: context.types.entry))
            default:
                // Other imports validated in validateImports, nothing to track here
                break
            }
        }

        /// The type entry a type import, or an instance's type export, of `value` gives, where
        /// the bound's type indices resolve in `scope`.
        private func importedType(
            _ value: InternalComponentExternalValue?, bound: ComponentTypeBound, name: String,
            scope: (ComponentTypeIndex) throws -> ComponentTypeSpace.Entry
        ) throws -> ComponentTypeSpace.Entry {
            switch bound {
            case .subResource:
                guard let value else {
                    throw ComponentLoaderError.missingImport(name: name)
                }
                guard case .type(let type) = value, let resource = type.resource else {
                    throw ComponentLoaderError.incompatibleImport(name: name, expected: "resource", got: value.sortDescription)
                }
                return .resource(resource)
            case .eq(let typeIndex):
                // The bound decides the type: one need not be provided, but one that is must match.
                let expected = try scope(ComponentTypeIndex(rawValue: Int(typeIndex)))
                if case .resource(let expectedResource) = expected, let value {
                    guard case .type(let type) = value, let resource = type.resource else {
                        throw ComponentLoaderError.incompatibleImport(name: name, expected: "resource", got: value.sortDescription)
                    }
                    guard resource === expectedResource else {
                        throw ComponentLoaderError.mismatchedResourceTypes(name: name)
                    }
                }
                if case .value(let expectedType) = expected, case .type(let type) = value, case .value(let providedType) = type.entry {
                    do {
                        try withoutActuallyEscaping(scope) { scope in
                            try ComponentTypeMatcher(
                                expected: scope, provided: type.space.entry,
                                comparesParameterNames: importTypeChecking == .strict
                            ).match(expectedType, providedType)
                        }
                    } catch let mismatch as ComponentTypeMismatch {
                        throw ComponentLoaderError.mismatchedImportType(name: name, reason: mismatch.description)
                    }
                }
                return expected
            }
        }

        /// Checks that `module` has the module type `declared`.
        private func checkModule(_ module: Module, against declared: CoreModuleType, name: String) throws {
            do {
                try CoreModuleTypeMatcher(module: module).match(declared)
            } catch let mismatch as ComponentTypeMismatch {
                throw ComponentLoaderError.mismatchedImportType(name: name, reason: mismatch.description)
            }
        }

        /// Checks that `function` has `type`, whose type indices resolve in `space`.
        private func checkFunction(
            _ function: InternalComponentFunction, against type: ComponentFuncType, in space: ComponentTypeSpace, name: String
        ) throws {
            let matcher = ComponentTypeMatcher(
                expected: space.entry, provided: function.types.entry,
                comparesParameterNames: importTypeChecking == .strict)
            do {
                try matcher.match(type, function.type)
            } catch let mismatch as ComponentTypeMismatch {
                throw ComponentLoaderError.mismatchedImportType(name: name, reason: mismatch.description)
            }
        }

        /// Checks that `value` is a value of `type`, whose type indices resolve in `space`.
        private func checkValue(
            _ value: ComponentValue, against type: ComponentDefValType, in space: ComponentTypeSpace, name: String
        ) throws {
            do {
                try ComponentValueChecker(resolve: space.entry).check(value, type)
            } catch let mismatch as ComponentTypeMismatch {
                throw ComponentLoaderError.mismatchedImportType(name: name, reason: mismatch.description)
            }
        }

        /// Checks that `definition` imports nothing `declaration` does not and exports all it
        /// does, each of the same sort.
        ///
        /// Their types are not compared: the component's are only known once it is
        /// instantiated, as they can refer to what it imports.
        private func checkComponent(_ definition: ComponentDefinition, against declaration: ComponentTypeDecl, name: String) throws {
            var declaredImports: [String: String] = [:]
            var declaredExports: [(name: String, sort: String)] = []
            for decl in declaration.declarations {
                switch decl {
                case .importDecl(let entry): declaredImports[entry.name] = Self.sort(of: entry.externDesc)
                case .instanceDecl(.exportDecl(let entry)): declaredExports.append((entry.name, Self.sort(of: entry.externDesc)))
                case .instanceDecl: break
                }
            }
            func mismatch(_ reason: String) -> ComponentLoaderError {
                .mismatchedImportType(name: name, reason: reason)
            }
            let component = definition.component
            for entry in component.imports {
                guard let declared = declaredImports[entry.name] else {
                    throw mismatch("missing expected import `\(entry.name)`")
                }
                let sort = Self.sort(of: entry.kind)
                guard sort == declared else {
                    throw mismatch("type mismatch in import `\(entry.name)`: expected \(sort) found \(declared)")
                }
            }
            for export in declaredExports {
                guard let entry = component.exports.first(where: { $0.name == export.name }) else {
                    throw mismatch("missing expected export `\(export.name)`")
                }
                let sort = Self.sort(of: entry.kind)
                guard sort == export.sort else {
                    throw mismatch("type mismatch in export `\(export.name)`: expected \(export.sort) found \(sort)")
                }
            }
        }

        private static func sort(of desc: ComponentExternDesc) -> String {
            switch desc {
            case .coreModule: return "module"
            case .function: return "func"
            case .value: return "value"
            case .type: return "type"
            case .component: return "component"
            case .instance: return "instance"
            }
        }

        private static func sort(of kind: ParsedComponentImportKind) -> String {
            switch kind {
            case .function: return "func"
            case .value: return "value"
            case .instance: return "instance"
            case .module: return "module"
            case .type: return "type"
            case .component: return "component"
            }
        }

        private static func sort(of kind: ParsedComponentExportKind) -> String {
            switch kind {
            case .function: return "func"
            case .value: return "value"
            case .type: return "type"
            case .instance: return "instance"
            case .coreModule: return "module"
            case .coreInstance: return "core instance"
            case .component: return "component"
            }
        }

        /// Whether an instance of `declaration` exports nothing, but perhaps instances that
        /// themselves export nothing.
        private static func isEmpty(_ declaration: InstanceTypeDecl) -> Bool {
            // The instance types the declaration defines, at their type indices.
            var types: [InstanceTypeDecl?] = []
            for decl in declaration.declarations {
                switch decl {
                case .coreType: break
                case .type(.instance(let type)): types.append(type)
                case .type: types.append(nil)
                case .alias(let alias):
                    if case .type = alias.sort { types.append(nil) }
                case .exportDecl(let export):
                    guard case .instance(let index) = export.externDesc, types.indices.contains(Int(index)),
                        let type = types[Int(index)], isEmpty(type)
                    else { return false }
                }
            }
            return true
        }

        /// Checks that `instance` has the exports `declaration` lists, of the right sorts, with
        /// the function, value, instance, component and module types it declares and the types
        /// its bounds require. `outer` gives the type index space an outer alias with a count
        /// refers to.
        private func checkInstance(
            _ instance: InternalComponentInstance, against declaration: InstanceTypeDecl, name: String,
            outer: (Int) throws -> ComponentTypeSpace
        ) throws {
            let exports = instance.exports
            // The instance type's own type index spaces.
            let local = ComponentTypeSpace()
            var localCoreTypes: [CoreTypeDef] = []
            for decl in declaration.declarations {
                switch decl {
                case .coreType(let type):
                    localCoreTypes.append(type)
                case .type(let type):
                    switch type {
                    case .definedValue(let type): local.append(.value(type))
                    case .function(let type): local.append(.function(type))
                    case .instance(let type): local.append(.instance(type))
                    case .component(let type): local.append(.component(type))
                    // An instance type cannot define a resource type.
                    case .resource: local.append(.opaque)
                    }
                case .alias(let alias):
                    if case .type = alias.sort, case .outer(let count, let index) = alias.target {
                        // Outer count 1 is the scope the instance type is declared in.
                        let space = try outer(Int(count))
                        try local.append(space.entry(ComponentTypeIndex(rawValue: Int(index))), from: space)
                    } else if case .type = alias.sort {
                        local.append(.opaque)
                    }
                case .exportDecl(let export):
                    let provided = exports[export.name]
                    switch export.externDesc {
                    case .type(let bound):
                        local.append(
                            try importedType(provided, bound: bound, name: "\(name).\(export.name)", scope: local.entry))
                        continue
                    default:
                        break
                    }
                    let exportName = "\(name).\(export.name)"
                    guard let provided else {
                        if case .instance(let typeIndex) = export.externDesc,
                            case .instance(let type) = try local.entry(ComponentTypeIndex(rawValue: Int(typeIndex))), Self.isEmpty(type)
                        {
                            continue
                        }
                        throw ComponentLoaderError.instanceExportNotFound(importName: name, exportName: export.name)
                    }
                    let expected: String
                    switch export.externDesc {
                    case .function: expected = "func"
                    case .instance: expected = "instance"
                    case .coreModule: expected = "module"
                    case .value: expected = "value"
                    case .component: expected = "component"
                    case .type: expected = "type"
                    }
                    guard provided.sortDescription == expected else {
                        throw ComponentLoaderError.incompatibleImport(name: exportName, expected: expected, got: provided.sortDescription)
                    }
                    func localType(_ index: UInt32) throws -> ComponentTypeSpace.Entry {
                        try local.entry(ComponentTypeIndex(rawValue: Int(index)))
                    }
                    switch (export.externDesc, provided) {
                    case (.coreModule(let typeIndex), .coreModule(let module)):
                        if localCoreTypes.indices.contains(Int(typeIndex)), case .module(let type) = localCoreTypes[Int(typeIndex)] {
                            try checkModule(module, against: type, name: exportName)
                        }
                    case (.function(let typeIndex), .function(let function)):
                        if case .function(let type) = try localType(typeIndex) {
                            try checkFunction(function, against: type, in: local, name: exportName)
                        }
                    case (.value(.type(let type)), .value(let value)):
                        try checkValue(value, against: type, in: local, name: exportName)
                    case (.instance(let typeIndex), .instance(let nested)):
                        if case .instance(let type) = try localType(typeIndex) {
                            // Outer count 1 in the nested type is this one.
                            try checkInstance(nested, against: type, name: exportName) { count in
                                count == 1 ? local : try outer(count - 1)
                            }
                        }
                    case (.component(let typeIndex), .component(let component)):
                        if case .component(let type) = try localType(typeIndex) {
                            try checkComponent(component, against: type, name: exportName)
                        }
                    default:
                        break
                    }
                }
            }
        }

        /// Process a type definition, creating a new resource type for a resource definition.
        private func processTypeDef(_ typeDef: ComponentTypeDef, context: inout InstantiationContext) throws {
            switch typeDef {
            case .definedValue(let type): context.types.append(.value(type))
            case .function(let type): context.types.append(.function(type))
            case .instance(let type): context.types.append(.instance(type))
            case .component(let type): context.types.append(.component(type))
            case .resource(let destructorIndex):
                var destructor: ((UInt32) throws -> Void)?
                if let destructorIndex {
                    let index = Int(destructorIndex)
                    guard context.coreFunctions.indices.contains(index) else {
                        throw ComponentLoaderError.invalidCoreFunctionIndex(index)
                    }
                    let function = Function(handle: context.coreFunctions[index], store: store)
                    guard function.type == FunctionType(parameters: [.i32], results: []) else {
                        throw ComponentLoaderError.instantiationFailed("a resource destructor must take one i32, not \(function.type)")
                    }
                    destructor = { rep in _ = try function.invoke([.i32(rep)]) }
                }
                context.types.append(.resource(ComponentResourceType(implementation: context.state, destructor: destructor)))
            }
        }

        /// Process an export: it joins the exports, and is a new index for what it exports.
        private func processExport(_ export: ParsedComponentExport, context: inout InstantiationContext) throws {
            let value: InternalComponentExternalValue
            switch export.kind {
            case .function(let index):
                guard index < context.componentFunctions.count else {
                    throw ComponentLoaderError.invalidComponentFunctionIndex(index)
                }
                value = .function(context.componentFunctions[index])
                context.componentFunctions.append(context.componentFunctions[index])

            case .value(let runtimeValue):
                value = .value(runtimeValue)

            case .type(let typeIndex):
                let type = try context.runtimeType(typeIndex)
                value = .type(type)
                context.types.append(type.entry)

            case .instance(let index):
                guard index < context.componentInstances.count else {
                    throw ComponentLoaderError.instantiationFailed(
                        "Invalid nested component index: \(index)"
                    )
                }
                value = .instance(context.componentInstances[index])
                context.componentInstances.append(context.componentInstances[index])

            case .coreModule(let moduleIndex):
                guard moduleIndex < context.coreModules.count else {
                    throw ComponentLoaderError.invalidCoreModuleIndex(moduleIndex)
                }
                value = .coreModule(context.coreModules[moduleIndex])
                context.coreModules.append(context.coreModules[moduleIndex])

            case .coreInstance(let instanceIndex):
                guard instanceIndex < context.coreInstances.count else {
                    throw ComponentLoaderError.invalidCoreInstanceIndex(instanceIndex)
                }
                value = .coreInstance(context.coreInstances[instanceIndex])

            case .component(let index):
                let definition = try context.component(index)
                value = .component(definition)
                context.components.append(.definition(definition))
            }
            context.exports[export.name] = value
        }

        /// Process a `resource.new`, `resource.drop` or `resource.rep`: a core function acting
        /// on this instance's handle table.
        private func processResourceIntrinsic(
            _ intrinsic: ParsedResourceIntrinsic, context: inout InstantiationContext
        ) throws -> InternalFunction {
            let state = context.state
            func resourceType(_ index: ComponentTypeIndex, definedHere: Bool) throws -> ComponentResourceType {
                let type = try context.types.resourceType(index)
                // Only the implementation sees a resource's representation.
                if definedHere, type.implementation !== state {
                    throw ComponentLoaderError.instantiationFailed(
                        "resource.new and resource.rep need a resource type this component defines")
                }
                return type
            }
            func handleIndex(_ arguments: [Value]) -> UInt32 {
                guard case .i32(let index) = arguments.first else { preconditionFailure("typed as taking an i32") }
                return index
            }
            let function: Function
            switch intrinsic {
            case .new(let typeIndex):
                let type = try resourceType(typeIndex, definedHere: true)
                function = Function(store: store, parameters: [.i32], results: [.i32]) { _, arguments in
                    [.i32(try state.resourceNew(type, rep: handleIndex(arguments)))]
                }
            case .drop(let typeIndex):
                let type = try resourceType(typeIndex, definedHere: false)
                function = Function(store: store, parameters: [.i32], results: []) { _, arguments in
                    try state.resourceDrop(type, index: handleIndex(arguments))
                    return []
                }
            case .rep(let typeIndex):
                let type = try resourceType(typeIndex, definedHere: true)
                function = Function(store: store, parameters: [.i32], results: [.i32]) { _, arguments in
                    [.i32(try state.resourceRep(type, index: handleIndex(arguments)))]
                }
            }
            return function.handle
        }

        /// Process an alias to populate the appropriate index space.
        private func processAlias(
            _ alias: ParsedAlias,
            context: inout InstantiationContext
        ) throws {
            switch alias.sort {
            case .func:
                // Function alias - extract function from instance export
                let componentFunc = try resolveComponentFunctionAlias(alias, context: &context)
                context.componentFunctions.append(componentFunc)
            case .instance:
                guard case .componentInstanceExport(let instanceIndex, let name) = alias.source else {
                    throw ComponentLoaderError.instantiationFailed("Outer alias for component instance not yet supported")
                }
                guard case .instance(let instance) = try componentInstanceExport(instanceIndex, name, context: context) else {
                    throw ComponentLoaderError.instantiationFailed("Export '\(name)' of instance \(instanceIndex) is not an instance")
                }
                context.componentInstances.append(instance)
            case .type:
                switch alias.source {
                case .componentInstanceExport(let instanceIndex, let name):
                    guard case .type(let type) = try componentInstanceExport(instanceIndex, name, context: context) else {
                        throw ComponentLoaderError.instantiationFailed("Export '\(name)' of instance \(instanceIndex) is not a type")
                    }
                    try context.types.append(type.entry, from: type.space)
                case .outer(let count, let index):
                    let space = try context.typeSpace(outerCount: count)
                    try context.types.append(try space.entry(ComponentTypeIndex(rawValue: index)), from: space)
                case .coreInstanceExport:
                    throw ComponentLoaderError.instantiationFailed("A core instance export cannot be a component type")
                }
            case .core(let coreSort):
                // Core aliases from core instance exports
                switch coreSort {
                case .func:
                    // Core function alias from core instance export
                    let coreFunc = try resolveCoreFunctionAlias(alias, context: &context)
                    context.coreFunctions.append(coreFunc)
                case .memory, .table, .global, .tag:
                    // Canon options name their memory by its instance export, so these are only
                    // for inline core instances.
                    guard case .coreInstanceExport(let instanceIndex, let name) = alias.source else {
                        throw ComponentLoaderError.instantiationFailed("A core \(coreSort) alias must be of a core instance export")
                    }
                    guard context.coreInstances.indices.contains(instanceIndex) else {
                        throw ComponentLoaderError.invalidCoreInstanceIndex(instanceIndex)
                    }
                    let exports = Instance(handle: context.coreInstances[instanceIndex], store: store).exports
                    let notFound = ComponentLoaderError.instantiationFailed(
                        "core instance \(instanceIndex) has no \(coreSort) export \"\(name)\"")
                    switch coreSort {
                    case .memory:
                        guard let memory = exports[memory: name] else { throw notFound }
                        context.coreMemories.append(memory)
                    case .table:
                        guard let table = exports[table: name] else { throw notFound }
                        context.coreTables.append(table)
                    case .tag:
                        guard case .tag(let tag) = exports[name] else { throw notFound }
                        context.coreTags.append(tag)
                    default:
                        guard let global = exports[global: name] else { throw notFound }
                        context.coreGlobals.append(global)
                    }
                case .module:
                    switch alias.source {
                    case .componentInstanceExport(let instanceIndex, let name):
                        guard case .coreModule(let module) = try componentInstanceExport(instanceIndex, name, context: context) else {
                            throw ComponentLoaderError.instantiationFailed("Export '\(name)' of instance \(instanceIndex) is not a core module")
                        }
                        context.coreModules.append(module)
                    case .outer(let count, let index):
                        let scope = try context.outerScope(count: count)
                        guard scope.coreModules.indices.contains(index) else {
                            throw ComponentLoaderError.invalidCoreModuleIndex(index)
                        }
                        context.coreModules.append(scope.coreModules[index])
                    case .coreInstanceExport:
                        throw ComponentLoaderError.instantiationFailed("A core instance export cannot be a core module")
                    }
                default:
                    break
                }
            case .component:
                switch alias.source {
                case .componentInstanceExport(let instanceIndex, let name):
                    guard case .component(let definition) = try componentInstanceExport(instanceIndex, name, context: context) else {
                        throw ComponentLoaderError.instantiationFailed("Export '\(name)' of instance \(instanceIndex) is not a component")
                    }
                    context.components.append(.definition(definition))
                case .outer(let count, let index):
                    context.components.append(.definition(try context.component(index, outerCount: count)))
                case .coreInstanceExport:
                    throw ComponentLoaderError.instantiationFailed("A core instance export cannot be a component")
                }
            case .value:
                // Value aliases don't add to runtime context
                break
            }
        }

        /// The export `name` of the component instance at `instanceIndex`.
        private func componentInstanceExport(
            _ instanceIndex: Int, _ name: String, context: InstantiationContext
        ) throws -> InternalComponentExternalValue {
            guard instanceIndex < context.componentInstances.count else {
                throw ComponentLoaderError.instantiationFailed(
                    "Component instance index \(instanceIndex) out of bounds for alias (\(context.componentInstances.count) instances)"
                )
            }
            guard let value = context.componentInstances[instanceIndex].exports[name] else {
                throw ComponentLoaderError.instantiationFailed("Export '\(name)' not found in instance \(instanceIndex)")
            }
            return value
        }

        /// Resolve a core function alias from a core instance export.
        private func resolveCoreFunctionAlias(
            _ alias: ParsedAlias,
            context: inout InstantiationContext
        ) throws -> InternalFunction {
            switch alias.source {
            case .coreInstanceExport(let instanceIndex, let name):
                // Get the core instance
                guard instanceIndex < context.coreInstances.count else {
                    throw ComponentLoaderError.invalidCoreInstanceIndex(instanceIndex)
                }
                let coreInstance = Instance(handle: context.coreInstances[instanceIndex], store: store)

                // Get the function export from the core instance
                guard let function = coreInstance.exports[function: name] else {
                    throw ComponentLoaderError.coreExportNotFound(instanceIndex: instanceIndex, name: name)
                }
                return function.handle

            case .componentInstanceExport:
                throw ComponentLoaderError.instantiationFailed(
                    "Component instance export alias for core function not supported"
                )

            case .outer:
                throw ComponentLoaderError.instantiationFailed(
                    "Outer alias for core function not yet supported"
                )
            }
        }

        /// Resolve a component function alias from an instance export.
        private func resolveComponentFunctionAlias(
            _ alias: ParsedAlias,
            context: inout InstantiationContext
        ) throws -> InternalComponentFunction {
            switch alias.source {
            case .componentInstanceExport(let instanceIndex, let name):
                // Get the instance from the component instance index space
                guard instanceIndex < context.componentInstances.count else {
                    throw ComponentLoaderError.instantiationFailed(
                        "Component instance index \(instanceIndex) out of bounds for alias (\(context.componentInstances.count) instances)"
                    )
                }
                let instanceHandle = context.componentInstances[instanceIndex]
                let instance = ComponentInstance(handle: instanceHandle, store: store)

                // Get the function export from the instance
                guard let function = instance.exports[function: name] else {
                    throw ComponentLoaderError.instantiationFailed(
                        "Function '\(name)' not found in instance \(instanceIndex)"
                    )
                }
                return function.handle

            case .coreInstanceExport:
                throw ComponentLoaderError.instantiationFailed(
                    "Core instance export alias for component function not supported"
                )

            case .outer:
                throw ComponentLoaderError.instantiationFailed(
                    "Outer alias for component function not yet supported"
                )
            }
        }

        /// Process a core instance definition (inline exports or module instantiation).
        private func processCoreInstanceDef(
            _ instanceDef: ParsedCoreInstanceDef,
            context: inout InstantiationContext
        ) throws {
            switch instanceDef {
            case .instantiate(let moduleIndex, let args):
                guard moduleIndex < context.coreModules.count else {
                    throw ComponentLoaderError.invalidCoreModuleIndex(moduleIndex)
                }

                let module = context.coreModules[moduleIndex]

                // Build imports from the args
                var imports = Imports()
                for arg in args {
                    guard arg.instanceIndex < context.coreInstances.count else {
                        throw ComponentLoaderError.invalidCoreInstanceIndex(arg.instanceIndex)
                    }
                    let sourceInstance = Instance(handle: context.coreInstances[arg.instanceIndex], store: store)
                    imports.define(module: arg.name, sourceInstance.exports)
                }

                let instance = try module.instantiate(store: store, imports: imports)
                context.coreInstances.append(instance.handle)

            case .exports(let exports):
                // Create a synthetic instance from inline exports
                // This builds an instance by collecting exports from different sources
                var instanceExports: [String: ExternalValue] = [:]
                for export in exports {
                    let value = try resolveCoreInlineExport(export, context: &context)
                    instanceExports[export.name] = value
                }

                // Create a synthetic core instance with these exports
                // We need to create a pseudo-instance that holds these exports
                let syntheticInstance = try createSyntheticCoreInstance(exports: instanceExports, context: &context)
                context.coreInstances.append(syntheticInstance)
            }
        }

        /// Resolve a core inline export to its external value.
        private func resolveCoreInlineExport(
            _ export: ParsedCoreInlineExport,
            context: inout InstantiationContext
        ) throws -> ExternalValue {
            switch export.sort {
            case .func:
                // Function from core functions index space
                guard export.index < context.coreFunctions.count else {
                    throw ComponentLoaderError.invalidCoreFunctionIndex(export.index)
                }
                return .function(Function(handle: context.coreFunctions[export.index], store: store))

            case .memory:
                guard context.coreMemories.indices.contains(export.index) else {
                    throw ComponentLoaderError.instantiationFailed("core memory index \(export.index) out of bounds")
                }
                return .memory(context.coreMemories[export.index])

            case .table:
                guard context.coreTables.indices.contains(export.index) else {
                    throw ComponentLoaderError.instantiationFailed("core table index \(export.index) out of bounds")
                }
                return .table(context.coreTables[export.index])

            case .global:
                guard context.coreGlobals.indices.contains(export.index) else {
                    throw ComponentLoaderError.instantiationFailed("core global index \(export.index) out of bounds")
                }
                return .global(context.coreGlobals[export.index])

            case .tag:
                guard context.coreTags.indices.contains(export.index) else {
                    throw ComponentLoaderError.instantiationFailed("core tag index \(export.index) out of bounds")
                }
                return .tag(context.coreTags[export.index])

            case .type:
                throw ComponentLoaderError.instantiationFailed("Inline type exports not yet supported")

            case .module:
                throw ComponentLoaderError.instantiationFailed("Inline module exports not yet supported")

            case .instance:
                throw ComponentLoaderError.instantiationFailed("Inline instance exports not yet supported")
            }
        }

        /// Create a synthetic core instance from inline exports.
        private func createSyntheticCoreInstance(
            exports: [String: ExternalValue],
            context: inout InstantiationContext
        ) throws -> InternalInstance {
            // Convert ExternalValue to InternalExternalValue
            var internalExports: [ExternalName: InternalExternalValue] = [:]
            for (name, value) in exports {
                let name = ExternalName(name)
                switch value {
                case .function(let func_):
                    internalExports[name] = .function(func_.handle)
                case .table(let table):
                    internalExports[name] = .table(table.handle)
                case .memory(let memory):
                    internalExports[name] = .memory(memory.handle)
                case .global(let global):
                    internalExports[name] = .global(global.handle)
                case .tag(let tag):
                    internalExports[name] = .tag(tag.handle)
                }
            }

            return store.allocator.allocateSyntheticCoreInstance(exports: internalExports)
        }

        /// Build core imports for a core module from the instantiation context.
        private func buildCoreImports(
            for coreModule: ParsedCoreModule,
            context: inout InstantiationContext
        ) throws -> Imports {
            var imports = Imports()

            for arg in coreModule.instantiateArgs {
                switch arg.source {
                case .coreInstance(let index):
                    guard index < context.coreInstances.count else {
                        throw ComponentLoaderError.invalidCoreInstanceIndex(index)
                    }
                    let sourceInstance = Instance(handle: context.coreInstances[index], store: store)
                    // Copy all exports from the source instance to satisfy the import
                    imports.define(module: arg.importName, sourceInstance.exports)

                case .componentImport(let name):
                    guard let importValue = context.imports.lookup(name: name) else {
                        throw ComponentLoaderError.missingImport(name: name)
                    }
                    // Component imports need to be converted to core imports
                    if case .coreInstance(let moduleHandle) = importValue {
                        let moduleInstance = Instance(handle: moduleHandle, store: store)
                        imports.define(module: arg.importName, moduleInstance.exports)
                    } else {
                        throw ComponentLoaderError.incompatibleImport(
                            name: name,
                            expected: "coreInstance",
                            got: String(describing: importValue)
                        )
                    }
                }
            }

            return imports
        }

        /// Process a component instance definition.
        private func processComponentInstanceDef(
            _ instanceDef: ParsedComponentInstanceDef,
            context: inout InstantiationContext
        ) throws {
            switch instanceDef {
            case .instantiate(let componentIndex, let args):
                let nestedComponent = try context.component(componentIndex)

                // Build imports for the nested component from the args
                var nestedImports = ComponentImports()
                for arg in args {
                    nestedImports.definitions[arg.name] = try resolveComponentInstantiateArg(arg, context: &context)
                }

                // Recursively instantiate the nested component
                let nestedInstance = try instantiate(nestedComponent, imports: nestedImports, depth: context.depth + 1)
                context.nestedComponents.append(nestedInstance.handle)
                context.componentInstances.append(nestedInstance.handle)

            case .exports(let exports):
                // Create an instance from inline exports
                var exportMap: [String: InternalComponentExternalValue] = [:]
                for export in exports {
                    let value = try resolveInlineExport(export, context: &context)
                    exportMap[export.name] = value
                }

                let entity = ComponentInstanceEntity(
                    coreInstances: [],
                    exports: exportMap,
                    functions: [],
                    nestedComponents: []
                )
                let handle = store.allocator.allocate(componentInstance: entity)
                context.nestedComponents.append(handle)
                context.componentInstances.append(handle)
            }
        }

        /// Resolve a component instantiate argument to an external value.
        private func resolveComponentInstantiateArg(
            _ arg: ParsedComponentInstantiateArg,
            context: inout InstantiationContext
        ) throws -> InternalComponentExternalValue {
            switch arg.sort {
            case .core(let coreSort):
                switch coreSort {
                case .instance:
                    guard arg.index < context.coreInstances.count else {
                        throw ComponentLoaderError.invalidCoreInstanceIndex(arg.index)
                    }
                    return .coreInstance(context.coreInstances[arg.index])

                case .module:
                    guard arg.index < context.coreModules.count else {
                        throw ComponentLoaderError.invalidCoreModuleIndex(arg.index)
                    }
                    return .coreModule(context.coreModules[arg.index])

                default:
                    throw ComponentLoaderError.instantiationFailed(
                        "Unsupported core sort in component instantiate arg: \(coreSort)"
                    )
                }

            case .func:
                guard arg.index < context.componentFunctions.count else {
                    throw ComponentLoaderError.invalidComponentFunctionIndex(arg.index)
                }
                return .function(context.componentFunctions[arg.index])

            case .instance:
                guard arg.index < context.componentInstances.count else {
                    throw ComponentLoaderError.instantiationFailed(
                        "Invalid component instance index: \(arg.index)"
                    )
                }
                return .instance(context.componentInstances[arg.index])

            case .type:
                return .type(try context.runtimeType(ComponentTypeIndex(rawValue: arg.index)))

            case .component:
                return .component(try context.component(arg.index))

            case .value:
                throw ComponentLoaderError.instantiationFailed(
                    "Unsupported sort in component instantiate arg: \(arg.sort)"
                )
            }
        }

        /// Resolve an inline export to an internal external value.
        private func resolveInlineExport(
            _ export: ParsedComponentInlineExport,
            context: inout InstantiationContext
        ) throws -> InternalComponentExternalValue {
            switch export.sort {
            case .core(let coreSort):
                switch coreSort {
                case .instance:
                    guard export.index < context.coreInstances.count else {
                        throw ComponentLoaderError.invalidCoreInstanceIndex(export.index)
                    }
                    return .coreInstance(context.coreInstances[export.index])

                case .module:
                    guard export.index < context.coreModules.count else {
                        throw ComponentLoaderError.invalidCoreModuleIndex(export.index)
                    }
                    return .coreModule(context.coreModules[export.index])

                case .func:
                    guard export.index < context.coreFunctions.count else {
                        throw ComponentLoaderError.instantiationFailed(
                            "Invalid core function index: \(export.index)"
                        )
                    }
                    // Core functions from canon.lower need to be wrapped for export
                    // Create a temporary coreInstance to hold the function
                    // This is a workaround - ideally we'd have a proper core function external value
                    throw ComponentLoaderError.instantiationFailed(
                        "Core function inline export not yet fully supported"
                    )

                default:
                    throw ComponentLoaderError.instantiationFailed(
                        "Unsupported core sort in inline export: \(coreSort)"
                    )
                }

            case .func:
                guard export.index < context.componentFunctions.count else {
                    throw ComponentLoaderError.invalidComponentFunctionIndex(export.index)
                }
                return .function(context.componentFunctions[export.index])

            case .instance:
                guard export.index < context.componentInstances.count else {
                    throw ComponentLoaderError.instantiationFailed(
                        "Invalid component instance index: \(export.index)"
                    )
                }
                return .instance(context.componentInstances[export.index])

            case .type:
                return .type(try context.runtimeType(ComponentTypeIndex(rawValue: export.index)))

            case .component:
                return .component(try context.component(export.index))

            case .value:
                throw ComponentLoaderError.instantiationFailed(
                    "Unsupported sort in inline export: \(export.sort)"
                )
            }
        }

        /// Process a canon.lift definition to create a component function.
        private func processCanonLift(
            _ canonDef: ParsedCanonicalDefinition,
            context: inout InstantiationContext
        ) throws -> InternalComponentFunction {
            let coreFunction: Function
            let type: ComponentFuncType
            let name: String
            switch canonDef.kind {
            case .lift(let coreInstanceIndex, let functionName, let liftType):
                guard coreInstanceIndex < context.coreInstances.count else {
                    throw ComponentLoaderError.invalidCoreInstanceIndex(coreInstanceIndex)
                }
                let coreInstance = Instance(handle: context.coreInstances[coreInstanceIndex], store: store)
                guard let function = coreInstance.exports[function: functionName] else {
                    throw ComponentLoaderError.coreExportNotFound(
                        instanceIndex: coreInstanceIndex,
                        name: functionName
                    )
                }
                (coreFunction, type, name) = (function, liftType, "\"\(functionName)\"")
            case .liftCoreFunction(let coreFunctionIndex, let liftType):
                guard context.coreFunctions.indices.contains(coreFunctionIndex) else {
                    throw ComponentLoaderError.invalidCoreFunctionIndex(coreFunctionIndex)
                }
                let function = Function(handle: context.coreFunctions[coreFunctionIndex], store: store)
                (coreFunction, type, name) = (function, liftType, "core function \(coreFunctionIndex)")
            case .lower:
                throw ComponentLoaderError.instantiationFailed("Expected canon.lift definition")
            }

            // Resolve canon options
            let canonOptions = try resolveCanonOptions(canonDef.options, context: &context)

            // The core function must have the type the component function flattens to; otherwise
            // lifting would read its results as the wrong values.
            let expectedCoreType = try CanonicalABITypes(space: context.types).flattenFunctionType(type, lifting: true)
            guard coreFunction.type == expectedCoreType else {
                throw ComponentLoaderError.instantiationFailed(
                    "canon lift of \(name): core type \(coreFunction.type) does not match \(expectedCoreType)")
            }

            let entity = ComponentFunctionEntity(
                type: type,
                types: context.types,
                implementation: .lifted(coreFunction: coreFunction.handle, canonOptions: canonOptions, instance: context.state)
            )

            return store.allocator.allocate(componentFunction: entity)
        }

        /// Process a canon.lower definition to create a core function.
        /// This wraps a component function so it can be called from core wasm modules.
        private func processCanonLower(
            _ canonDef: ParsedCanonicalDefinition,
            context: inout InstantiationContext
        ) throws -> InternalFunction {
            guard case .lower(let componentFunctionIndex) = canonDef.kind else {
                throw ComponentLoaderError.instantiationFailed("Expected canon.lower definition")
            }

            guard componentFunctionIndex < context.componentFunctions.count else {
                throw ComponentLoaderError.invalidComponentFunctionIndex(componentFunctionIndex)
            }

            let componentFunction = ComponentFunction(
                handle: context.componentFunctions[componentFunctionIndex],
                store: store
            )
            let funcType = componentFunction.type
            // The lowering side's own options: the arguments and results live in the memory of the
            // core instance calling the function, not in that of the component implementing it.
            let options = try resolveCanonOptions(canonDef.options, context: &context)
            // The callee's type, whose indices resolve in its own space; its resource types are
            // the caller's too, as linking passed them along.
            let types = CanonicalABITypes(space: componentFunction.handle.types)
            let coreFuncType = try types.flattenFunctionType(funcType, lifting: false)

            // A host function that lifts the core arguments, calls the component function, and
            // lowers its results back for the core caller. Handles move through the caller's table.
            let store = self.store
            let instance = context.state
            let callsComponent: Bool
            if case .lifted = componentFunction.handle.implementation { callsComponent = true } else { callsComponent = false }
            let wrappedFunction = Function(store: store, type: coreFuncType) { [componentFunction] _, coreArgs in
                try instance.checkMayLeave()
                var abi = CanonicalABIContext(types: types, options: options, store: store, instance: instance)
                abi.callsComponent = callsComponent
                // The borrows lent to the call end with it, however it ends: a trap leaves the
                // instance usable, and its handles must not stay lent.
                defer { abi.releaseLenders() }
                let componentArgs = try abi.liftArguments(coreArgs, of: funcType)
                let results = try componentFunction.invoke(componentArgs)
                // The results go into the caller's memory, with its `realloc`.
                return try instance.withoutLeaving { try abi.lowerResults(results, of: funcType, arguments: coreArgs) }
            }

            return wrappedFunction.handle
        }

        /// Resolve canonical options to runtime references.
        private func resolveCanonOptions(
            _ options: ParsedCanonOptions,
            context: inout InstantiationContext
        ) throws -> CanonOptions {
            var memory: InternalMemory?
            var realloc: InternalFunction?
            var postReturn: InternalFunction?

            if let memoryRef = options.memory {
                guard memoryRef.coreInstanceIndex < context.coreInstances.count else {
                    throw ComponentLoaderError.invalidCoreInstanceIndex(memoryRef.coreInstanceIndex)
                }
                let coreInstance = Instance(handle: context.coreInstances[memoryRef.coreInstanceIndex], store: store)
                guard let mem = coreInstance.exports[memory: memoryRef.memoryName] else {
                    throw ComponentLoaderError.coreMemoryNotFound(
                        instanceIndex: memoryRef.coreInstanceIndex,
                        name: memoryRef.memoryName
                    )
                }
                memory = mem.handle
            }

            if let reallocRef = options.realloc {
                guard reallocRef.coreInstanceIndex < context.coreInstances.count else {
                    throw ComponentLoaderError.invalidCoreInstanceIndex(reallocRef.coreInstanceIndex)
                }
                let coreInstance = Instance(handle: context.coreInstances[reallocRef.coreInstanceIndex], store: store)
                guard let func_ = coreInstance.exports[function: reallocRef.functionName] else {
                    throw ComponentLoaderError.coreExportNotFound(
                        instanceIndex: reallocRef.coreInstanceIndex,
                        name: reallocRef.functionName
                    )
                }
                realloc = func_.handle
            }

            if let postReturnRef = options.postReturn {
                guard postReturnRef.coreInstanceIndex < context.coreInstances.count else {
                    throw ComponentLoaderError.invalidCoreInstanceIndex(postReturnRef.coreInstanceIndex)
                }
                let coreInstance = Instance(handle: context.coreInstances[postReturnRef.coreInstanceIndex], store: store)
                guard let func_ = coreInstance.exports[function: postReturnRef.functionName] else {
                    throw ComponentLoaderError.coreExportNotFound(
                        instanceIndex: postReturnRef.coreInstanceIndex,
                        name: postReturnRef.functionName
                    )
                }
                postReturn = func_.handle
            }

            return CanonOptions(
                memory: memory,
                realloc: realloc,
                postReturn: postReturn,
                stringEncoding: options.stringEncoding
            )
        }

        /// Validate that the provided imports satisfy the component's import requirements.
        private func validateImports(
            _ requiredImports: [ParsedComponentImport],
            against providedImports: ComponentImports
        ) throws {
            for required in requiredImports {
                guard let provided = providedImports.lookup(name: required.name) else {
                    // An instance with nothing to export need not be provided: whether it has
                    // is known once its type is.
                    if case .instance = required.kind { continue }
                    throw ComponentLoaderError.missingImport(name: required.name)
                }

                // Validate the kind matches
                switch (required.kind, provided) {
                case (.function, .function):
                    // Its type is checked when it is processed, as its type indices resolve
                    // against the types defined before it.
                    break

                case (.value, .value), (.instance, .instance), (.module, .coreModule):
                    // Checked against the declared type when it is processed
                    break

                case (.type, _):
                    // Checked against its bound when it is processed
                    break

                case (.component, .component):
                    // Checked against the declared type when it is processed
                    break

                case (.component, _):
                    throw ComponentLoaderError.incompatibleImport(
                        name: required.name,
                        expected: "component",
                        got: provided.tagDescription
                    )

                case (.function, _):
                    throw ComponentLoaderError.incompatibleImport(
                        name: required.name,
                        expected: "function",
                        got: provided.tagDescription
                    )

                case (.value, _):
                    throw ComponentLoaderError.incompatibleImport(
                        name: required.name,
                        expected: "value",
                        got: provided.tagDescription
                    )

                case (.instance, _):
                    throw ComponentLoaderError.incompatibleImport(
                        name: required.name,
                        expected: "instance",
                        got: provided.tagDescription
                    )

                case (.module, _):
                    throw ComponentLoaderError.incompatibleImport(
                        name: required.name,
                        expected: "module",
                        got: provided.tagDescription
                    )
                }
            }
        }
    }

    // MARK: - ComponentExternalValue Internalization

    extension ComponentExternalValue {
        /// Convert a public external value to its internal representation.
        func internalize() -> InternalComponentExternalValue {
            switch self {
            case .function(let function):
                return .function(function.handle)
            case .value(let value):
                return .value(value)
            case .type(let typeIndex):
                // Only its index is known: it is not a resource type, and nothing can be read of it.
                return .type(ComponentRuntimeType(entry: .opaque, space: ComponentTypeSpace(), index: typeIndex))
            case .resourceType(let type):
                return .type(ComponentRuntimeType(entry: .resource(type), space: ComponentTypeSpace(), index: ComponentTypeIndex(rawValue: 0)))
            case .instance(let instance):
                return .instance(instance.handle)
            case .coreModule(let module):
                return .coreModule(module)
            case .coreInstance(let moduleInstance):
                return .coreInstance(moduleInstance.handle)
            case .component(let component):
                return .component(ComponentDefinition(component: component, outer: []))
            }
        }
    }

#endif
