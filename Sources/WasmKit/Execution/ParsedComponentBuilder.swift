#if ComponentModel
    import ComponentModel
    import WasmParser

    // MARK: - Component Parsing

    /// Parse a component binary into a `ParsedComponent` ready for instantiation.
    ///
    /// This function converts the streaming `ComponentParser` output into a
    /// semantic representation suitable for the `ComponentLoader`.
    ///
    /// - Parameters:
    ///   - bytes: The WebAssembly component binary bytes
    ///   - features: Enabled WebAssembly features for parsing
    /// - Returns: A `ParsedComponent` ready for instantiation
    /// - Throws: `WasmKitError` if parsing fails, `ComponentParseError` for semantic errors
    public func parseComponent(
        bytes: [UInt8],
        features: WasmFeatureSet = .default
    ) throws -> ParsedComponent {
        let stream = StaticByteStreamSource(bytes: bytes)
        return try parseComponent(stream: stream, features: features)
    }

    /// Parse a component binary from an ArraySlice into a `ParsedComponent`.
    ///
    /// This overload avoids copying when parsing nested component bytes.
    ///
    /// - Parameters:
    ///   - bytes: The WebAssembly component binary bytes as an ArraySlice
    ///   - features: Enabled WebAssembly features for parsing
    /// - Returns: A `ParsedComponent` ready for instantiation
    /// - Throws: `WasmKitError` if parsing fails, `ComponentParseError` for semantic errors
    func parseComponent(
        bytes: ArraySlice<UInt8>,
        features: WasmFeatureSet = .default,
        depth: Int = 0
    ) throws -> ParsedComponent {
        let stream = StaticByteStreamSource(bytes: bytes)
        return try parseComponent(stream: stream, features: features, depth: depth)
    }

    /// How deeply components may nest. Each level recurses in the parser, so an untrusted
    /// binary of nested headers could otherwise overflow the host's stack: in a debug build a
    /// 512 KiB thread stack holds about 40 levels. Real components nest a handful deep.
    let maxComponentNestingDepth = 32

    /// Internal implementation that parses from any ByteStream.
    private func parseComponent<Source: ByteStreamSource>(
        stream: Source,
        features: WasmFeatureSet,
        depth: Int = 0
    ) throws -> ParsedComponent {
        guard depth <= maxComponentNestingDepth else {
            throw ComponentParseError.unsupported("components nested more than \(maxComponentNestingDepth) deep")
        }
        var parser = WasmParser.ComponentParser(stream: stream, features: features)
        var builder = ParsedComponentBuilder(features: features, depth: depth)

        while let payload = try parser.parseNext() {
            try builder.process(payload)
        }

        return try builder.build()
    }

    // MARK: - Component Parse Error

    /// Errors that can occur during semantic component parsing.
    public enum ComponentParseError: Error {
        /// A referenced index is out of bounds
        case invalidIndex(String)
        /// An alias target could not be resolved
        case unresolvedAlias(String)
        /// A type reference could not be resolved
        case unresolvedType(UInt32)
        /// Unsupported feature encountered
        case unsupported(String)
    }

    // MARK: - Parsed Component Builder

    /// Internal builder that accumulates parsed sections into a `ParsedComponent`.
    struct ParsedComponentBuilder {
        // Index spaces (populated during parsing)
        private var coreModules: [Module] = []  // modules index space
        private var coreInstances: [CoreInstanceInfo] = []  // core instances index space
        private var coreTypes: [CoreTypeDef] = []  // core types index space
        private var components: [ArraySlice<UInt8>] = []  // nested components index space
        private var componentInstances: [ComponentInstanceInfo] = []  // component instances
        private var aliases: [ResolvedAlias] = []  // resolved aliases
        private var componentTypes: [ComponentTypeDef] = []  // component types index space
        private var componentFunctions: [ComponentFunctionInfo] = []  // component functions from lift
        private var coreFunctionDefs: [CoreFunctionDefInfo] = []  // core functions from canon.lower
        private var values: [ComponentValueDef] = []  // values index space
        private var imports: [ComponentImportDef] = []
        private var exports: [ComponentExportDef] = []
        private var canonicalDefs: [CanonicalDefinition] = []

        /// Tracks the order of definitions for interleaved processing
        private enum OrderedDefKind {
            case component
            case coreModule
            case coreInstance
            case componentInstance
            case alias
            case canonLift
            case canonLower
            case resourceIntrinsic(ParsedResourceIntrinsic)
            case type
            case `import`
            case export
        }
        private var orderedDefs: [OrderedDefKind] = []

        /// The features the enclosing component was parsed with, which its contents share.
        private let features: WasmFeatureSet
        /// How many components enclose this one.
        private let depth: Int

        /// The core function index space, in the binary order its definitions appear in.
        private enum CoreFunctionEntry {
            /// A `canon lower`, by its position among the lowers.
            case lowered
            /// An alias of a core instance export.
            case alias(instanceIndex: Int, name: String)
            /// A resource intrinsic.
            case resourceIntrinsic
            /// A function this loader cannot resolve, such as an outer alias.
            case unresolvable
        }
        private var coreFunctionSpace: [CoreFunctionEntry] = []

        /// The type index space, in binary order: which indices name a type section entry, so
        /// that function types can be read here. The others are only known at instantiation.
        private enum TypeEntry {
            case section(Int)
            case other
        }
        private var typeSpace: [TypeEntry] = []

        init(features: WasmFeatureSet = .default, depth: Int = 0) {
            self.features = features
            self.depth = depth
        }

        /// Process a parsing payload from the streaming parser.
        mutating func process(_ payload: ComponentParsingPayload) throws {
            switch payload {
            case .header:
                // Header is validated by the parser; nothing to store
                break

            case .customSection:
                // Custom sections are ignored for now
                break

            case .coreModule(let moduleBytes):
                let module = try parseWasm(bytes: moduleBytes, features: features)
                coreModules.append(module)
                orderedDefs.append(.coreModule)

            case .coreInstanceSection(let instances):
                for instance in instances {
                    try processCoreInstance(instance)
                }

            case .coreTypeSection(let types):
                coreTypes.append(contentsOf: types)

            case .component(let componentBytes):
                components.append(componentBytes)
                orderedDefs.append(.component)

            case .instanceSection(let instances):
                for instance in instances {
                    try processComponentInstance(instance)
                }

            case .aliasSection(let aliasSection):
                for alias in aliasSection {
                    try processAlias(alias)
                }

            case .typeSection(let types):
                for type in types {
                    typeSpace.append(.section(componentTypes.count))
                    componentTypes.append(type)
                    orderedDefs.append(.type)
                }

            case .canonSection(let canonDefs):
                for canonDef in canonDefs {
                    try processCanonicalDefinition(canonDef)
                }

            case .startSection:
                // Start section support is deferred
                break

            case .importSection(let importDefs):
                for importDef in importDefs {
                    imports.append(importDef)
                    orderedDefs.append(.import)
                    if case .type = importDef.externDesc {
                        typeSpace.append(.other)
                    }
                }

            case .exportSection(let exportDefs):
                for exportDef in exportDefs {
                    exports.append(exportDef)
                    orderedDefs.append(.export)
                    // An export is a new index for what it exports.
                    if case .type = exportDef.sort {
                        let index = Int(exportDef.index)
                        typeSpace.append(typeSpace.indices.contains(index) ? typeSpace[index] : .other)
                    }
                }

            case .valueSection(let valueDefs):
                values.append(contentsOf: valueDefs)
            }
        }

        /// Build the final `ParsedComponent` from accumulated state.
        func build() throws -> ParsedComponent {
            var result = ParsedComponent()

            // Build core modules (without instantiation args - handled by coreInstanceDefs)
            for module in coreModules {
                let parsedModule = ParsedCoreModule(module: module)
                result.coreModules.append(parsedModule)
            }

            // Build core instance definitions (preserving binary order)
            for instanceInfo in coreInstances {
                let parsedDef = buildCoreInstanceDef(instanceInfo.definition)
                result.coreInstanceDefs.append(parsedDef)
            }

            // Build nested components (recursively parse component bytes)
            for componentBytes in components {
                let nestedParsed = try parseComponent(bytes: componentBytes, features: features, depth: depth + 1)
                result.nestedComponents.append(nestedParsed)
            }

            // Build component instances
            for instanceInfo in componentInstances {
                let parsedInstance = try buildComponentInstanceDef(instanceInfo.definition)
                result.componentInstances.append(parsedInstance)
            }

            // Build canonical definitions (lift creates component functions, lower creates core functions)
            for (funcIndex, funcInfo) in componentFunctions.enumerated() {
                let parsedCanon = try buildParsedCanonicalDefinition(funcInfo, funcIndex: funcIndex)
                result.canonicalDefinitions.append(parsedCanon)
            }

            // Build canon.lower definitions (creates core functions from component functions)
            for coreFuncDef in coreFunctionDefs {
                var parsedOptions = ParsedCanonOptions()
                try parseCanonicalOptions(coreFuncDef.options, into: &parsedOptions)
                let parsedCanon = ParsedCanonicalDefinition(
                    kind: .lower(componentFunctionIndex: coreFuncDef.componentFunctionIndex),
                    options: parsedOptions
                )
                result.canonicalDefinitions.append(parsedCanon)
            }

            // Build aliases
            for alias in aliases {
                let parsedAlias = buildParsedAlias(alias)
                result.aliases.append(parsedAlias)
            }

            // Build ordered definitions (preserving binary interleaved order)
            var componentIndex = 0
            var coreModuleIndex = 0
            var coreInstanceIndex = 0
            var componentInstanceIndex = 0
            var aliasIndex = 0
            var canonLiftIndex = 0
            var canonLowerIndex = 0
            var typeIndex = 0
            var importIndex = 0
            var exportIndex = 0
            for orderedDef in orderedDefs {
                switch orderedDef {
                case .component:
                    result.orderedDefinitions.append(.component(index: componentIndex))
                    componentIndex += 1
                case .coreModule:
                    result.orderedDefinitions.append(.coreModule(index: coreModuleIndex))
                    coreModuleIndex += 1
                case .type:
                    result.orderedDefinitions.append(.type(index: typeIndex))
                    typeIndex += 1
                case .import:
                    result.orderedDefinitions.append(.import(index: importIndex))
                    importIndex += 1
                case .export:
                    result.orderedDefinitions.append(.export(index: exportIndex))
                    exportIndex += 1
                case .coreInstance:
                    result.orderedDefinitions.append(.coreInstance(index: coreInstanceIndex))
                    coreInstanceIndex += 1
                case .componentInstance:
                    result.orderedDefinitions.append(.componentInstance(index: componentInstanceIndex))
                    componentInstanceIndex += 1
                case .resourceIntrinsic(let intrinsic):
                    result.orderedDefinitions.append(.resourceIntrinsic(intrinsic))
                case .alias:
                    result.orderedDefinitions.append(.alias(index: aliasIndex))
                    aliasIndex += 1
                case .canonLift:
                    result.orderedDefinitions.append(.canon(index: canonLiftIndex))
                    canonLiftIndex += 1
                case .canonLower:
                    // canon.lower comes after all canon.lift in canonicalDefinitions
                    let actualIndex = componentFunctions.count + canonLowerIndex
                    result.orderedDefinitions.append(.canon(index: actualIndex))
                    canonLowerIndex += 1
                }
            }

            // Build imports
            for importDef in imports {
                let kind = try convertImportKind(importDef.externDesc)
                var declaredType: ComponentTypeIndex?
                if case .instance(let typeIndex) = importDef.externDesc {
                    declaredType = ComponentTypeIndex(rawValue: Int(typeIndex))
                }
                result.imports.append(ParsedComponentImport(name: importDef.name, kind: kind, declaredType: declaredType))
            }

            // Build exports
            for exportDef in exports {
                let kind = try convertExportKind(exportDef)
                result.exports.append(ParsedComponentExport(name: exportDef.name, kind: kind))
            }

            // Store component types for type resolution during lowering/lifting
            result.componentTypes = componentTypes

            return result
        }

        private func buildCoreInstanceDef(_ definition: CoreInstanceDefinition) -> ParsedCoreInstanceDef {
            switch definition {
            case .instantiate(let moduleIndex, let args):
                let parsedArgs = args.map { arg in
                    ParsedCoreInstantiateArg(
                        name: arg.name,
                        instanceIndex: Int(arg.instanceIndex)
                    )
                }
                return .instantiate(moduleIndex: Int(moduleIndex), args: parsedArgs)

            case .exports(let exports):
                let parsedExports = exports.map { export in
                    ParsedCoreInlineExport(
                        name: export.name,
                        sort: export.sort,
                        index: Int(export.index)
                    )
                }
                return .exports(parsedExports)
            }
        }

        private func buildComponentInstanceDef(_ definition: ComponentInstanceDefinition) throws -> ParsedComponentInstanceDef {
            switch definition {
            case .instantiate(let componentIndex, let args):
                let parsedArgs = args.map { arg in
                    ParsedComponentInstantiateArg(
                        name: arg.name,
                        sort: arg.sort,
                        index: Int(arg.index)
                    )
                }
                return .instantiate(componentIndex: Int(componentIndex), args: parsedArgs)

            case .exports(let exports):
                let parsedExports = exports.map { export in
                    ParsedComponentInlineExport(
                        name: export.name,
                        sort: export.sort,
                        index: Int(export.index)
                    )
                }
                return .exports(parsedExports)
            }
        }

        private func buildParsedAlias(_ alias: ResolvedAlias) -> ParsedAlias {
            let source: ParsedAliasSource
            switch alias.source {
            case .componentInstanceExport(let instanceIndex, let name):
                source = .componentInstanceExport(instanceIndex: instanceIndex, name: name)
            case .coreInstanceExport(let instanceIndex, let name):
                source = .coreInstanceExport(instanceIndex: instanceIndex, name: name)
            case .outer(let count, let index):
                source = .outer(count: count, index: index)
            }
            return ParsedAlias(sort: alias.sort, source: source)
        }

        // MARK: - Private Processing Methods

        private mutating func processCoreInstance(_ instance: CoreInstanceDefinition) throws {
            let info = CoreInstanceInfo(definition: instance)
            coreInstances.append(info)
            orderedDefs.append(.coreInstance)
        }

        private mutating func processComponentInstance(_ instance: ComponentInstanceDefinition) throws {
            let info = ComponentInstanceInfo(definition: instance)
            componentInstances.append(info)
            orderedDefs.append(.componentInstance)
        }

        private mutating func processAlias(_ alias: ComponentAlias) throws {
            let resolved = try resolveAlias(alias)
            aliases.append(resolved)
            orderedDefs.append(.alias)
            if case .core(.func) = resolved.sort {
                switch resolved.source {
                case .coreInstanceExport(let instanceIndex, let name):
                    coreFunctionSpace.append(.alias(instanceIndex: instanceIndex, name: name))
                default:
                    coreFunctionSpace.append(.unresolvable)
                }
            }
            if case .type = resolved.sort {
                typeSpace.append(.other)
            }
        }

        private mutating func processCanonicalDefinition(_ canonDef: CanonicalDefinition) throws {
            canonicalDefs.append(canonDef)

            // Track component functions created by lift and core functions created by lower
            switch canonDef {
            case .lift(let coreFuncIndex, let options, let typeIndex):
                let funcInfo = ComponentFunctionInfo(
                    kind: .lift(coreFuncIndex: coreFuncIndex, typeIndex: typeIndex),
                    options: options
                )
                componentFunctions.append(funcInfo)
                orderedDefs.append(.canonLift)

            case .lower(let componentFuncIndex, let options):
                let info = CoreFunctionDefInfo(
                    componentFunctionIndex: Int(componentFuncIndex),
                    options: options
                )
                coreFunctionDefs.append(info)
                orderedDefs.append(.canonLower)
                coreFunctionSpace.append(.lowered)

            case .resourceNew(let typeIndex):
                orderedDefs.append(.resourceIntrinsic(.new(typeIndex: ComponentTypeIndex(rawValue: Int(typeIndex)))))
                coreFunctionSpace.append(.resourceIntrinsic)
            case .resourceDrop(let typeIndex):
                orderedDefs.append(.resourceIntrinsic(.drop(typeIndex: ComponentTypeIndex(rawValue: Int(typeIndex)))))
                coreFunctionSpace.append(.resourceIntrinsic)
            case .resourceRep(let typeIndex):
                orderedDefs.append(.resourceIntrinsic(.rep(typeIndex: ComponentTypeIndex(rawValue: Int(typeIndex)))))
                coreFunctionSpace.append(.resourceIntrinsic)
            }
        }

        private func resolveAlias(_ alias: ComponentAlias) throws -> ResolvedAlias {
            switch alias.target {
            case .export(let instanceIdx, let name):
                return ResolvedAlias(
                    sort: alias.sort,
                    source: .componentInstanceExport(instanceIndex: Int(instanceIdx), name: name)
                )

            case .coreExport(let instanceIdx, let name):
                return ResolvedAlias(
                    sort: alias.sort,
                    source: .coreInstanceExport(instanceIndex: Int(instanceIdx), name: name)
                )

            case .outer(let count, let index):
                return ResolvedAlias(
                    sort: alias.sort,
                    source: .outer(count: Int(count), index: Int(index))
                )
            }
        }

        private func buildParsedCanonicalDefinition(
            _ funcInfo: ComponentFunctionInfo,
            funcIndex: Int
        ) throws -> ParsedCanonicalDefinition {
            switch funcInfo.kind {
            case .lift(let coreFuncIndex, let typeIndex):
                let funcType = try resolveComponentFuncType(typeIndex)

                var parsedOptions = ParsedCanonOptions()
                try parseCanonicalOptions(funcInfo.options, into: &parsedOptions)

                // A core instance export is named as one; any other core function, such as
                // `resource.new`, by its index.
                let kind: ParsedCanonicalKind
                let index = Int(coreFuncIndex)
                if coreFunctionSpace.indices.contains(index), case .alias(let instanceIndex, let name) = coreFunctionSpace[index] {
                    kind = .lift(coreInstanceIndex: instanceIndex, functionName: name, type: funcType)
                } else {
                    guard coreFunctionSpace.indices.contains(index) else {
                        throw ComponentParseError.invalidIndex("Core function index \(index) out of bounds")
                    }
                    kind = .liftCoreFunction(coreFunctionIndex: index, type: funcType)
                }
                return ParsedCanonicalDefinition(kind: kind, options: parsedOptions)
            }
        }

        private func resolveCoreFunctionIndex(_ index: Int) throws -> (coreInstanceIndex: Int, functionName: String) {
            // Canon lowers, core function aliases and resource intrinsics share the index space
            // in the order they appear in the binary, interleaved.
            guard coreFunctionSpace.indices.contains(index) else {
                throw ComponentParseError.invalidIndex("Core function index \(index) out of bounds")
            }
            switch coreFunctionSpace[index] {
            case .alias(let instanceIndex, let name):
                return (instanceIndex, name)
            case .lowered:
                throw ComponentParseError.unsupported("Core function \(index) is a `canon lower`, not a core export")
            case .resourceIntrinsic:
                throw ComponentParseError.unsupported("Core function \(index) is a resource intrinsic")
            case .unresolvable:
                throw ComponentParseError.unsupported("Core function \(index) is not a core instance export")
            }
        }

        private func resolveComponentFuncType(_ typeIndex: UInt32) throws -> ComponentFuncType {
            guard typeSpace.indices.contains(Int(typeIndex)), case .section(let sectionIndex) = typeSpace[Int(typeIndex)] else {
                throw ComponentParseError.unresolvedType(typeIndex)
            }

            let typeDef = componentTypes[sectionIndex]
            guard case .function(let funcType) = typeDef else {
                throw ComponentParseError.unresolvedType(typeIndex)
            }

            return funcType
        }

        private func parseCanonicalOptions(
            _ options: [CanonicalOption],
            into parsedOptions: inout ParsedCanonOptions
        ) throws {
            for option in options {
                switch option {
                case .utf8:
                    parsedOptions.stringEncoding = .utf8
                case .utf16:
                    parsedOptions.stringEncoding = .utf16
                case .latin1UTF16:
                    parsedOptions.stringEncoding = .latin1UTF16
                case .memory(let memoryIndex):
                    // Memory index refers to core memory index space
                    let (instanceIndex, memoryName) = try resolveCoreMemoryIndex(Int(memoryIndex))
                    parsedOptions.memory = ParsedCanonMemory(
                        coreInstanceIndex: instanceIndex,
                        memoryName: memoryName
                    )
                case .realloc(let funcIndex):
                    let (instanceIndex, funcName) = try resolveCoreFunctionIndex(Int(funcIndex))
                    parsedOptions.realloc = ParsedCanonFunc(
                        coreInstanceIndex: instanceIndex,
                        functionName: funcName
                    )
                case .postReturn(let funcIndex):
                    let (instanceIndex, funcName) = try resolveCoreFunctionIndex(Int(funcIndex))
                    parsedOptions.postReturn = ParsedCanonFunc(
                        coreInstanceIndex: instanceIndex,
                        functionName: funcName
                    )
                case .async, .callback:
                    // Async support is deferred
                    break
                }
            }
        }

        private func resolveCoreMemoryIndex(_ index: Int) throws -> (coreInstanceIndex: Int, memoryName: String) {
            // Similar to resolveCoreFunctionIndex but for memories
            var coreMemoryCounter = 0
            for alias in aliases {
                if case .core(.memory) = alias.sort {
                    if coreMemoryCounter == index {
                        switch alias.source {
                        case .coreInstanceExport(let instanceIndex, let name):
                            return (instanceIndex, name)
                        default:
                            throw ComponentParseError.unsupported("Unsupported core memory alias source")
                        }
                    }
                    coreMemoryCounter += 1
                }
            }

            throw ComponentParseError.invalidIndex("Core memory index \(index) out of bounds")
        }

        private func convertImportKind(_ externDesc: ComponentExternDesc) throws -> ParsedComponentImportKind {
            switch externDesc {
            case .function(let typeIndex):
                let funcType = try resolveComponentFuncType(typeIndex)
                return .function(funcType)
            case .value(let bound):
                switch bound {
                case .eq:
                    throw ComponentParseError.unsupported("Value import with eq bound")
                case .type(let valType):
                    return .value(valType)
                }
            case .instance:
                return .instance
            case .coreModule:
                return .module
            case .type(let bound):
                return .type(bound)
            case .component:
                return .component
            }
        }

        private func convertExportKind(_ exportDef: ComponentExportDef) throws -> ParsedComponentExportKind {
            switch exportDef.sort {
            case .func:
                return .function(index: Int(exportDef.index))
            case .value:
                // Value exports need to be resolved from the values index space
                guard Int(exportDef.index) < values.count else {
                    throw ComponentParseError.invalidIndex("Value index \(exportDef.index) out of bounds")
                }
                // For now, return a placeholder - proper value parsing would need type info
                return .value(.u32(0))  // Placeholder
            case .type:
                return .type(ComponentTypeIndex(rawValue: Int(exportDef.index)))
            case .instance:
                return .instance(index: Int(exportDef.index))
            case .component:
                return .component(index: Int(exportDef.index))
            case .core(let coreSort):
                switch coreSort {
                case .module:
                    return .coreModule(moduleIndex: Int(exportDef.index))
                case .instance:
                    return .coreInstance(instanceIndex: Int(exportDef.index))
                default:
                    throw ComponentParseError.unsupported("Core \(coreSort) exports not yet supported")
                }
            }
        }
    }

    // MARK: - Helper Types

    /// Information about a core instance during parsing.
    private struct CoreInstanceInfo {
        let definition: CoreInstanceDefinition
    }

    /// Information about a component instance during parsing.
    private struct ComponentInstanceInfo {
        let definition: ComponentInstanceDefinition
    }

    /// A resolved alias with its source.
    private struct ResolvedAlias {
        let sort: ComponentDefSort
        let source: AliasSource

        enum AliasSource {
            case componentInstanceExport(instanceIndex: Int, name: String)
            case coreInstanceExport(instanceIndex: Int, name: String)
            case outer(count: Int, index: Int)
        }
    }

    /// Information about a component function during parsing.
    private struct ComponentFunctionInfo {
        let kind: ComponentFunctionKind
        let options: [CanonicalOption]

        enum ComponentFunctionKind {
            case lift(coreFuncIndex: UInt32, typeIndex: UInt32)
        }
    }

    /// Information about a core function from canon.lower during parsing.
    private struct CoreFunctionDefInfo {
        let componentFunctionIndex: Int
        let options: [CanonicalOption]
    }

#endif

#if ComponentModel && FileSystem
    /// Parse a component binary from a caller-owned platform file descriptor.
    ///
    /// The descriptor must be opened for reading in binary mode. This function
    /// *borrows* it: ownership stays with the caller, who must close it after
    /// the call returns. Bytes are consumed starting from the descriptor's
    /// current offset.
    public func parseComponent(
        fileHandle: CInt,
        features: WasmFeatureSet = .default
    ) throws -> ParsedComponent {
        let stream = try FileHandleStreamSource(fileHandle: fileHandle)
        return try parseComponent(stream: stream, features: features)
    }

    /// Parse a component binary from a file path.
    ///
    /// The file is opened by the parser and closed when the underlying stream
    /// source is deallocated.
    public func parseComponent(
        filePath: String,
        features: WasmFeatureSet = .default
    ) throws -> ParsedComponent {
        let stream = try FileHandleStreamSource(filePath: filePath)
        return try parseComponent(stream: stream, features: features)
    }
#endif
