#if ComponentModel
    import ComponentModel
    import WAT
    import WIT

    /// Serializes WIT world definitions into the component-type custom section
    /// binary format for WasmKit component linking.
    package enum ComponentTypeSerializer {

        package enum Error: Swift.Error, Equatable {
            case worldNotFound(String)
            case unsupportedFeature(String)
        }

        /// Encode a WIT world as a component-type custom section payload.
        ///
        /// The returned bytes form a complete component binary (header + sections)
        /// suitable for embedding as a `"component-type"` custom section in a core
        /// Wasm module.
        package static func encodeComponentType(
            context: SemanticsContext,
            worldName: String,
            encodingVersion: UInt32 = 4
        ) throws -> [UInt8] {
            guard let (world, _) = findWorld(name: worldName, in: context) else {
                throw Error.worldNotFound(worldName)
            }

            let pkgName = context.rootPackage.packageName
            let fqWorldName = "\(pkgName.namespace.text):\(pkgName.name.text)/\(worldName)"

            var encoder = Encoder()

            // Component header (8 bytes)
            encoder.writeComponentHeader()

            // Custom section: wit-component-encoding + version
            encoder.section(id: ComponentSectionID.custom.rawValue) { enc in
                enc.encode("wit-component-encoding")
                enc.writeUnsignedLEB128(encodingVersion)
            }

            // Type section: 1 outer componenttype
            try encoder.section(id: ComponentSectionID.type.rawValue) { enc in
                enc.writeUnsignedLEB128(UInt32(1))
                try encodeOuterComponentType(
                    world: world.syntax,
                    fqWorldName: fqWorldName,
                    context: context,
                    encoder: &enc
                )
            }

            // Export section: world short name → type 0
            encoder.section(id: ComponentSectionID.export.rawValue) { enc in
                enc.writeUnsignedLEB128(UInt32(1))
                encodeImportExportName(worldName, encoder: &enc)
                enc.output.append(ComponentSortOpcode.type.rawValue)
                enc.writeUnsignedLEB128(UInt32(0))
                enc.output.append(0x00)  // externdesc absent (0x00 marker per Binary.md export section)
            }

            return encoder.output
        }

        // MARK: - World lookup

        private static func findWorld(
            name: String,
            in context: SemanticsContext
        ) -> (world: SyntaxNode<WorldSyntax>, sourceFile: SyntaxNode<SourceFileSyntax>)? {
            for sourceFile in context.rootPackage.sourceFiles {
                for case .world(let world) in sourceFile.items {
                    if world.name.text == name {
                        return (world, sourceFile)
                    }
                }
            }
            return nil
        }

        // MARK: - Outer componenttype

        /// Encodes the outer componenttype: [type(inner), export(fq-name → component(0))]
        private static func encodeOuterComponentType(
            world: WorldSyntax,
            fqWorldName: String,
            context: SemanticsContext,
            encoder: inout Encoder
        ) throws {
            encoder.output.append(DefinedTypeOpcode.componentType.rawValue)  // 0x41
            encoder.writeUnsignedLEB128(UInt32(2))  // 2 declarations

            // Decl 0: type(inner componenttype)
            encoder.output.append(TypeDeclTag.type.rawValue)  // 0x01
            try encodeWorldComponentType(world: world, context: context, encoder: &encoder)

            // Decl 1: export(fq-name → component(0))
            encoder.output.append(TypeDeclTag.export.rawValue)  // 0x04
            encodeImportExportName(fqWorldName, encoder: &encoder)
            encoder.output.append(ExternDescKind.component.rawValue)  // 0x04
            encoder.writeUnsignedLEB128(UInt32(0))
        }

        // MARK: - Declaration scopes

        /// The declarations of one component or instance type, which has a type index space of
        /// its own.
        private struct DeclarationScope {
            var encoder = Encoder()
            var count: UInt32 = 0
            var nextTypeIndex: UInt32 = 0
            /// The types declared under a name, by the index their export introduced.
            var namedTypes: [String: UInt32] = [:]
            /// Anonymous composite types declared so far. A valtype names a non-primitive type
            /// only by index, so `list<u8>` in a parameter must first become a declaration.
            var anonymousTypes: [TypeReprSyntax: UInt32] = [:]

            /// Appends a `type` declaration whose body `encodeBody` writes, returning its index.
            mutating func declareType(_ encodeBody: (inout Self, inout Encoder) throws -> Void) rethrows -> UInt32 {
                var body = Encoder()
                try encodeBody(&self, &body)
                encoder.output.append(TypeDeclTag.type.rawValue)
                encoder.output.append(contentsOf: body.output)
                defer {
                    nextTypeIndex += 1
                    count += 1
                }
                return nextTypeIndex
            }

            /// Appends an `export` declaration of a type, `(export name (type (eq index)))`, which
            /// introduces a type index of its own. Returns that index.
            mutating func exportType(_ name: String, index: UInt32) -> UInt32 {
                encoder.output.append(TypeDeclTag.export.rawValue)
                encodeImportExportName(name, encoder: &encoder)
                encoder.output.append(ExternDescKind.type.rawValue)
                encoder.output.append(TypeBoundOpcode.eq.rawValue)
                encoder.writeUnsignedLEB128(index)
                defer {
                    nextTypeIndex += 1
                    count += 1
                }
                return nextTypeIndex
            }

            /// Appends an import or export declaration of an instance or function of type `index`.
            mutating func declareExtern(tag: UInt8, name: String, kind: ExternDescKind, index: UInt32) {
                encoder.output.append(tag)
                encodeImportExportName(name, encoder: &encoder)
                encoder.output.append(kind.rawValue)
                encoder.writeUnsignedLEB128(index)
                count += 1
            }

            /// Declares every anonymous composite type `typeRepr` contains, innermost first,
            /// including `typeRepr` itself unless `includingSelf` is `false`.
            mutating func hoist(_ typeRepr: TypeReprSyntax, includingSelf: Bool = true) throws {
                switch typeRepr {
                case .list(let element), .option(let element):
                    try hoist(element)
                case .tuple(let elements):
                    for element in elements { try hoist(element) }
                case .result(let result):
                    if let ok = result.ok { try hoist(ok) }
                    if let error = result.error { try hoist(error) }
                default:
                    return
                }
                guard includingSelf, anonymousTypes[typeRepr] == nil else { return }
                let index = try declareType { scope, body in
                    try encodeComposite(typeRepr, scope: scope, encoder: &body)
                }
                anonymousTypes[typeRepr] = index
            }
        }

        // MARK: - Inner componenttype (the world)

        private static func encodeWorldComponentType(
            world: WorldSyntax,
            context: SemanticsContext,
            encoder: inout Encoder
        ) throws {
            var scope = DeclarationScope()

            for item in world.items {
                switch item {
                case .import(let importSyntax):
                    try encodeWorldExtern(kind: importSyntax.kind, isImport: true, context: context, scope: &scope)
                case .export(let exportSyntax):
                    try encodeWorldExtern(kind: exportSyntax.kind, isImport: false, context: context, scope: &scope)
                case .type(let typeDefNode):
                    try encodeNamedType(typeDefNode.syntax, scope: &scope)
                case .use:
                    throw Error.unsupportedFeature("use in world")
                case .include:
                    throw Error.unsupportedFeature("include in world")
                }
            }

            encoder.output.append(DefinedTypeOpcode.componentType.rawValue)  // 0x41
            encoder.writeUnsignedLEB128(scope.count)
            encoder.output.append(contentsOf: scope.encoder.output)
        }

        /// Declares a named type and exports it, so later references use the exported index.
        private static func encodeNamedType(_ typeDef: TypeDefSyntax, scope: inout DeclarationScope) throws {
            try hoistTypeDefBody(typeDef.body, scope: &scope)
            let index = try scope.declareType { scope, body in
                try encodeTypeDefBody(typeDef.body, scope: scope, encoder: &body)
            }
            scope.namedTypes[typeDef.name.text] = scope.exportType(typeDef.name.text, index: index)
        }

        // MARK: - World import/export encoding

        private static func encodeWorldExtern(
            kind: ExternKindSyntax,
            isImport: Bool,
            context: SemanticsContext,
            scope: inout DeclarationScope
        ) throws {
            let tag: UInt8 = isImport ? TypeDeclTag.import.rawValue : TypeDeclTag.export.rawValue

            switch kind {
            case .interface(let name, let items):
                let typeIdx = try scope.declareType { _, body in try encodeInstanceType(items: items, encoder: &body) }
                scope.declareExtern(tag: tag, name: name.text, kind: .instance, index: typeIdx)

            case .path(let path):
                let (iface, fqName) = try resolveInterfacePath(path, context: context)
                let typeIdx = try scope.declareType { _, body in try encodeInstanceType(items: iface.items, encoder: &body) }
                scope.declareExtern(tag: tag, name: fqName, kind: .instance, index: typeIdx)

            case .function(let name, let funcSyntax):
                let typeIdx = try encodeFuncTypeDeclaration(funcSyntax, scope: &scope)
                scope.declareExtern(tag: tag, name: name.text, kind: .function, index: typeIdx)
            }
        }

        // MARK: - Interface path resolution

        private static func resolveInterfacePath(
            _ path: UsePathSyntax,
            context: SemanticsContext
        ) throws -> (interface: SyntaxNode<InterfaceSyntax>, fullyQualifiedName: String) {
            switch path {
            case .id(let id):
                let (iface, _) = try context.lookupInterface(
                    name: id.text,
                    contextPackage: context.rootPackage
                )
                let pkg = context.rootPackage.packageName
                let fqName = "\(pkg.namespace.text):\(pkg.name.text)/\(id.text)"
                return (iface, fqName)

            case .package(let pkgName, let id):
                let fqName = "\(pkgName.namespace.text):\(pkgName.name.text)/\(id.text)"
                let rootPkg = context.rootPackage.packageName
                guard
                    rootPkg.namespace.text == pkgName.namespace.text
                        && rootPkg.name.text == pkgName.name.text
                else {
                    throw Error.unsupportedFeature("cross-package interface reference: \(fqName)")
                }
                let (iface, _) = try context.lookupInterface(
                    name: id.text,
                    contextPackage: context.rootPackage
                )
                return (iface, fqName)
            }
        }

        // MARK: - Instance type encoding (for WIT interfaces)

        private static func encodeInstanceType(
            items: [InterfaceItemSyntax],
            encoder: inout Encoder
        ) throws {
            var scope = DeclarationScope()

            for item in items {
                switch item {
                case .typeDef(let typeDefNode):
                    try encodeNamedType(typeDefNode.syntax, scope: &scope)

                case .function(let funcNode):
                    let funcSyntax = funcNode.syntax
                    let typeIdx = try encodeFuncTypeDeclaration(funcSyntax.function, scope: &scope)
                    scope.declareExtern(
                        tag: TypeDeclTag.export.rawValue, name: funcSyntax.name.text, kind: .function, index: typeIdx)

                case .use:
                    throw Error.unsupportedFeature("use in interface")
                }
            }

            encoder.output.append(DefinedTypeOpcode.instanceType.rawValue)  // 0x42
            encoder.writeUnsignedLEB128(scope.count)
            encoder.output.append(contentsOf: scope.encoder.output)
        }

        // MARK: - Function type encoding

        /// Declares the anonymous types `function` uses, then the function type itself.
        private static func encodeFuncTypeDeclaration(
            _ function: FunctionSyntax, scope: inout DeclarationScope
        ) throws -> UInt32 {
            for param in function.parameters { try scope.hoist(param.type) }
            switch function.results {
            case .anon(let type): try scope.hoist(type)
            case .named(let params): for param in params { try scope.hoist(param.type) }
            }
            return try scope.declareType { scope, body in
                try encodeFuncType(function, scope: scope, encoder: &body)
            }
        }

        private static func encodeFuncType(
            _ function: FunctionSyntax,
            scope: DeclarationScope,
            encoder: inout Encoder
        ) throws {
            encoder.output.append(DefinedTypeOpcode.funcSync.rawValue)  // 0x40

            // Parameters
            encoder.writeUnsignedLEB128(UInt32(function.parameters.count))
            for param in function.parameters {
                encoder.encode(param.name.text)
                try encodeValType(param.type, scope: scope, encoder: &encoder)
            }

            // Results
            switch function.results {
            case .anon(let type):
                encoder.output.append(ResultMarker.hasResult.rawValue)  // 0x00
                try encodeValType(type, scope: scope, encoder: &encoder)
            case .named(let params):
                encoder.output.append(ResultMarker.namedResults.rawValue)  // 0x01
                encoder.writeUnsignedLEB128(UInt32(params.count))
                for param in params {
                    encoder.encode(param.name.text)
                    try encodeValType(param.type, scope: scope, encoder: &encoder)
                }
            }
        }

        // MARK: - Value type encoding

        /// Writes a `valtype`: a primitive opcode, or the s33 index of a named or hoisted type.
        private static func encodeValType(
            _ typeRepr: TypeReprSyntax,
            scope: DeclarationScope,
            encoder: inout Encoder
        ) throws {
            switch typeRepr {
            // Primitives
            case .bool: encoder.output.append(PrimitiveValTypeOpcode.bool.rawValue)
            case .s8: encoder.output.append(PrimitiveValTypeOpcode.s8.rawValue)
            case .u8: encoder.output.append(PrimitiveValTypeOpcode.u8.rawValue)
            case .s16: encoder.output.append(PrimitiveValTypeOpcode.s16.rawValue)
            case .u16: encoder.output.append(PrimitiveValTypeOpcode.u16.rawValue)
            case .s32: encoder.output.append(PrimitiveValTypeOpcode.s32.rawValue)
            case .u32: encoder.output.append(PrimitiveValTypeOpcode.u32.rawValue)
            case .s64: encoder.output.append(PrimitiveValTypeOpcode.s64.rawValue)
            case .u64: encoder.output.append(PrimitiveValTypeOpcode.u64.rawValue)
            case .float32: encoder.output.append(PrimitiveValTypeOpcode.float32.rawValue)
            case .float64: encoder.output.append(PrimitiveValTypeOpcode.float64.rawValue)
            case .char: encoder.output.append(PrimitiveValTypeOpcode.char.rawValue)
            case .string: encoder.output.append(PrimitiveValTypeOpcode.string.rawValue)

            // Named type reference
            case .name(let id):
                if let idx = scope.namedTypes[id.text] {
                    // A valtype's type index is an s33; see `ComponentEncoder.encodeValType`.
                    encoder.writeSignedLEB128(Int64(idx))
                } else {
                    switch id.text {
                    case "f32": encoder.output.append(PrimitiveValTypeOpcode.float32.rawValue)
                    case "f64": encoder.output.append(PrimitiveValTypeOpcode.float64.rawValue)
                    default:
                        throw Error.unsupportedFeature("unknown type reference: \(id.text)")
                    }
                }

            // Composite types, declared beforehand by `DeclarationScope.hoist`
            case .list, .option, .result, .tuple:
                guard let index = scope.anonymousTypes[typeRepr] else {
                    throw Error.unsupportedFeature("composite type \(typeRepr) was not declared before use")
                }
                encoder.writeSignedLEB128(Int64(index))

            case .handle, .future, .stream:
                throw Error.unsupportedFeature("handle/future/stream types not yet supported")
            }
        }

        /// Writes the `defvaltype` of a composite type, whose element types are valtypes.
        private static func encodeComposite(
            _ typeRepr: TypeReprSyntax,
            scope: DeclarationScope,
            encoder: inout Encoder
        ) throws {
            switch typeRepr {
            case .list(let elem):
                encoder.output.append(CompositeValTypeOpcode.list.rawValue)
                try encodeValType(elem, scope: scope, encoder: &encoder)

            case .option(let inner):
                encoder.output.append(CompositeValTypeOpcode.option.rawValue)
                try encodeValType(inner, scope: scope, encoder: &encoder)

            case .result(let resultSyntax):
                encoder.output.append(CompositeValTypeOpcode.result.rawValue)
                if let ok = resultSyntax.ok {
                    encoder.output.append(OptionalMarker.present.rawValue)
                    try encodeValType(ok, scope: scope, encoder: &encoder)
                } else {
                    encoder.output.append(OptionalMarker.absent.rawValue)
                }
                if let err = resultSyntax.error {
                    encoder.output.append(OptionalMarker.present.rawValue)
                    try encodeValType(err, scope: scope, encoder: &encoder)
                } else {
                    encoder.output.append(OptionalMarker.absent.rawValue)
                }

            case .tuple(let elems):
                encoder.output.append(CompositeValTypeOpcode.tuple.rawValue)
                encoder.writeUnsignedLEB128(UInt32(elems.count))
                for elem in elems {
                    try encodeValType(elem, scope: scope, encoder: &encoder)
                }

            default:
                // A primitive or a name is a valtype, which a `defvaltype` may hold as well.
                try encodeValType(typeRepr, scope: scope, encoder: &encoder)
            }
        }

        // MARK: - Type definition body encoding

        /// Declares the anonymous types a named type's body uses.
        private static func hoistTypeDefBody(_ body: TypeDefBodySyntax, scope: inout DeclarationScope) throws {
            switch body {
            case .record(let recordSyntax):
                for field in recordSyntax.fields { try scope.hoist(field.type) }
            case .variant(let variantSyntax):
                for variantCase in variantSyntax.cases {
                    if let type = variantCase.type { try scope.hoist(type) }
                }
            case .alias(let aliasSyntax):
                // The alias's own composite is the declaration being made; only what it holds
                // needs declaring first.
                try scope.hoist(aliasSyntax.typeRepr, includingSelf: false)
            case .enum, .flags, .resource, .union:
                break
            }
        }

        private static func encodeTypeDefBody(
            _ body: TypeDefBodySyntax,
            scope: DeclarationScope,
            encoder: inout Encoder
        ) throws {
            switch body {
            case .record(let recordSyntax):
                encoder.output.append(CompositeValTypeOpcode.record.rawValue)
                encoder.writeUnsignedLEB128(UInt32(recordSyntax.fields.count))
                for field in recordSyntax.fields {
                    encoder.encode(field.name.text)
                    try encodeValType(field.type, scope: scope, encoder: &encoder)
                }

            case .enum(let enumSyntax):
                encoder.output.append(CompositeValTypeOpcode.enum.rawValue)
                encoder.writeUnsignedLEB128(UInt32(enumSyntax.cases.count))
                for enumCase in enumSyntax.cases {
                    encoder.encode(enumCase.name.text)
                }

            case .flags(let flagsSyntax):
                encoder.output.append(CompositeValTypeOpcode.flags.rawValue)
                encoder.writeUnsignedLEB128(UInt32(flagsSyntax.flags.count))
                for flag in flagsSyntax.flags {
                    encoder.encode(flag.name.text)
                }

            case .variant(let variantSyntax):
                encoder.output.append(CompositeValTypeOpcode.variant.rawValue)
                encoder.writeUnsignedLEB128(UInt32(variantSyntax.cases.count))
                for variantCase in variantSyntax.cases {
                    encoder.encode(variantCase.name.text)
                    if let type = variantCase.type {
                        encoder.output.append(OptionalMarker.present.rawValue)
                        try encodeValType(type, scope: scope, encoder: &encoder)
                    } else {
                        encoder.output.append(OptionalMarker.absent.rawValue)
                    }
                    encoder.output.append(0x00)  // refines: none
                }

            case .alias(let aliasSyntax):
                try encodeComposite(aliasSyntax.typeRepr, scope: scope, encoder: &encoder)

            case .resource:
                throw Error.unsupportedFeature("resource types not yet supported")
            case .union:
                throw Error.unsupportedFeature("union types not yet supported")
            }
        }

        // MARK: - Import/export name encoding

        private static func encodeImportExportName(
            _ name: String,
            encoder: inout Encoder
        ) {
            encoder.output.append(NameVariant.plain.rawValue)  // 0x00
            encoder.encode(name)
        }
    }

#endif
