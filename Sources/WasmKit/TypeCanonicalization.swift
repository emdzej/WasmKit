import WasmParser
import WasmTypes

// # Canonical types
//
// A concrete heap type in a module, `(ref $t)`, names a type by its index in
// that module's type section. Types are compared iso-recursively, also across
// modules: a type is identified by the recursion group it is defined in and its
// position there, and two groups are the same when they define the same types
// in the same order, with the same finality and supertypes, where references to
// a type of the group itself are compared by position and references to types
// outside it by their own identity.
//
// Inside the engine, a concrete heap type therefore carries a canonical type ID
// instead of a module-relative index: the ID the engine's ``TypeRegistry``
// gives the type when its group is registered. Because a group may only refer
// to the groups defined before it, the type section can be canonicalized in
// order, and two types are equivalent exactly when their canonical IDs are
// equal.
//
// Canonical types reuse `HeapType.concrete(typeIndex:)`, so the same Swift
// value means a module index in parsed `Module` data and a canonical ID in
// everything the translator and the runtime see: function entities, globals,
// tables, element segments and `Function.type`. Function types given by the
// host are taken to be canonical already, and define a final type of a group of
// their own, as a function type outside a `rec` group does.

extension WasmKitError.Message {
    static func unknownType(_ index: UInt32) -> Self {
        Self("unknown type \(index)")
    }
}

/// The definition of a canonical type, with every concrete heap type in it a canonical ID.
struct DefinedType: Sendable {
    let composite: CompositeType
    let isFinal: Bool
    /// The type's supertypes from the root of its hierarchy down to the type itself.
    let supertypeChain: [UInt32]

    /// The declared supertype, if any.
    var supertype: UInt32? {
        supertypeChain.count > 1 ? supertypeChain[supertypeChain.count - 2] : nil
    }

    /// How many supertypes the type has above it.
    var depth: Int { supertypeChain.count - 1 }
}

/// The engine-wide set of canonical types, which gives each recursion group of
/// type definitions its identity. Thread-safe like the rest of ``Engine``.
final class TypeRegistry: Sendable {
    /// A concrete type index in a group's key refers to the type at this offset
    /// within the group when the flag is set, and to a canonical ID otherwise.
    fileprivate static let groupRelativeFlag: UInt32 = 1 << 31

    private struct State {
        var definitions: [DefinedType] = []
        /// The first canonical ID of each group, by the group's key.
        var groups: [[SubType]: UInt32] = [:]
    }

    // `var` because the single-threaded PlatformMutex fallback mutates in
    // place; the mutex itself guarantees exclusivity, which Sendable checking
    // cannot see.
    nonisolated(unsafe) private var state = PlatformMutex(State())

    /// The canonical ID of a final function type outside any `rec` group.
    func intern(_ type: FunctionType) -> InternedFuncType {
        let first = register(group: [SubType(isFinal: true, supertypes: [], body: .function(type))])
        return InternedFuncType(id: first)
    }

    /// The signature of a canonical function type.
    func resolve(_ type: InternedFuncType) -> FunctionType {
        guard case .function(let functionType) = definition(of: type.id).composite else {
            preconditionFailure("canonical type \(type.id) is not a function type")
        }
        return functionType
    }

    func definition(of id: UInt32) -> DefinedType {
        state.withLock { $0.definitions[Int(id)] }
    }

    /// Whether the canonical type `sub` is `sup` or declares it as a supertype, directly or not.
    func isSubtype(_ sub: UInt32, of sup: UInt32) -> Bool {
        if sub == sup { return true }
        return state.withLock { state in
            let subChain = state.definitions[Int(sub)].supertypeChain
            let supDepth = state.definitions[Int(sup)].depth
            return supDepth < subChain.count && subChain[supDepth] == sup
        }
    }

    /// Registers a group given by its key, and returns the canonical ID of its first type; the
    /// others follow in order.
    ///
    /// In the key, a concrete type index with ``groupRelativeFlag`` set refers to a type of the
    /// group itself, and one without it to a canonical ID. A supertype must come before its subtype.
    fileprivate func register(group key: [SubType]) -> UInt32 {
        state.withLock { state in
            if let first = state.groups[key] {
                return first
            }
            let first = UInt32(state.definitions.count)
            precondition(UInt64(first) + UInt64(key.count) < UInt64(Self.groupRelativeFlag), "too many canonical types")
            func resolve(_ index: UInt32) -> UInt32 {
                index & Self.groupRelativeFlag != 0 ? first + (index & ~Self.groupRelativeFlag) : index
            }
            for type in key {
                let chain: [UInt32]
                if let supertype = type.supertypes.first {
                    chain = state.definitions[Int(resolve(supertype))].supertypeChain + [UInt32(state.definitions.count)]
                } else {
                    chain = [UInt32(state.definitions.count)]
                }
                state.definitions.append(
                    DefinedType(composite: type.body.mapTypeIndices(resolve), isFinal: type.isFinal, supertypeChain: chain))
            }
            state.groups[key] = first
            return first
        }
    }
}

/// Maps the type indices of one module to canonical type IDs.
struct TypeCanonicalizer {
    /// The canonical ID of each type in the module's type section.
    let typeIDs: [InternedFuncType]

    /// Canonicalizes and validates a module's type section, registering its groups in `registry`.
    ///
    /// Throws "unknown type" if a type refers to a type after its own group, or names a
    /// supertype that is not defined before it.
    init(typeSection: TypeSection, features: WasmFeatureSet, registry: TypeRegistry) throws(WasmKitError) {
        var typeIDs: [InternedFuncType] = []
        typeIDs.reserveCapacity(typeSection.count)
        for group in typeSection.recursiveGroups {
            let groupStart = UInt32(typeIDs.count)
            let groupEnd = groupStart + UInt32(group.types.count)
            let earlier = typeIDs
            func keyIndex(_ index: UInt32) throws(WasmKitError) -> UInt32 {
                if index < groupStart { return earlier[Int(index)].id }
                guard index < groupEnd else { throw WasmKitError(message: .unknownType(index)) }
                return TypeRegistry.groupRelativeFlag | (index - groupStart)
            }
            var key: [SubType] = []
            key.reserveCapacity(group.types.count)
            for (offset, type) in group.types.enumerated() {
                let ownIndex = groupStart + UInt32(offset)
                guard type.supertypes.count <= 1 else {
                    throw WasmKitError("a type may declare at most one supertype")
                }
                var supertypes: [UInt32] = []
                for supertype in type.supertypes {
                    guard supertype < ownIndex else { throw WasmKitError(message: .unknownType(supertype)) }
                    supertypes.append(try keyIndex(supertype))
                }
                key.append(SubType(isFinal: type.isFinal, supertypes: supertypes, body: try type.body.mapTypeIndices(keyIndex)))
            }
            let first = registry.register(group: key)
            for offset in 0..<UInt32(group.types.count) {
                typeIDs.append(InternedFuncType(id: first + offset))
            }
            for id in first..<first + UInt32(group.types.count) {
                try registry.validateSupertype(of: id)
            }
        }
        self.typeIDs = typeIDs
    }

    init(typeIDs: [InternedFuncType]) {
        self.typeIDs = typeIDs
    }

    func canonicalID(of index: TypeIndex) throws(WasmKitError) -> InternedFuncType {
        guard Int(index) < typeIDs.count else {
            throw WasmKitError(message: .unknownType(index))
        }
        return typeIDs[Int(index)]
    }

    func canonicalize(_ heapType: HeapType) throws(WasmKitError) -> HeapType {
        switch heapType {
        case .abstract: return heapType
        case .concrete(let index): return .concrete(typeIndex: try canonicalID(of: index).id)
        }
    }

    func canonicalize(_ type: ReferenceType) throws(WasmKitError) -> ReferenceType {
        guard case .concrete = type.heapType else { return type }
        return ReferenceType(isNullable: type.isNullable, heapType: try canonicalize(type.heapType))
    }

    func canonicalize(_ type: ValueType) throws(WasmKitError) -> ValueType {
        guard case .ref(let referenceType) = type else { return type }
        return .ref(try canonicalize(referenceType))
    }

    func canonicalize(_ types: [ValueType]) throws(WasmKitError) -> [ValueType] {
        // Most types refer to no other type; keep them without copying.
        guard types.contains(where: \.hasConcreteHeapType) else { return types }
        var result: [ValueType] = []
        result.reserveCapacity(types.count)
        for type in types {
            result.append(try canonicalize(type))
        }
        return result
    }

    func canonicalize(_ type: FunctionType) throws(WasmKitError) -> FunctionType {
        guard type.parameters.contains(where: \.hasConcreteHeapType) || type.results.contains(where: \.hasConcreteHeapType) else {
            return type
        }
        return FunctionType(parameters: try canonicalize(type.parameters), results: try canonicalize(type.results))
    }

    func canonicalize(_ type: GlobalType) throws(WasmKitError) -> GlobalType {
        GlobalType(mutability: type.mutability, valueType: try canonicalize(type.valueType))
    }

    func canonicalize(_ type: TableType) throws(WasmKitError) -> TableType {
        TableType(elementType: try canonicalize(type.elementType), limits: type.limits)
    }
}

extension TypeRegistry {
    /// Checks that a canonical type may declare the supertype it does: one that is not final,
    /// and of which it is a structural subtype.
    fileprivate func validateSupertype(of id: UInt32) throws(WasmKitError) {
        let type = definition(of: id)
        guard let supertypeID = type.supertype else { return }
        let supertype = definition(of: supertypeID)
        guard !supertype.isFinal else {
            throw WasmKitError("sub type \(id) declares a final supertype")
        }
        guard isSubtype(type.composite, of: supertype.composite) else {
            throw WasmKitError("sub type \(id) does not match its supertype")
        }
    }
}

extension ValueType {
    /// Whether the type refers to a type in a type section.
    fileprivate var hasConcreteHeapType: Bool {
        guard case .ref(let referenceType) = self, case .concrete = referenceType.heapType else { return false }
        return true
    }

    fileprivate func mapTypeIndices<E: Error>(_ transform: (UInt32) throws(E) -> UInt32) throws(E) -> ValueType {
        guard case .ref(let referenceType) = self, case .concrete(let index) = referenceType.heapType else { return self }
        return .ref(ReferenceType(isNullable: referenceType.isNullable, heapType: .concrete(typeIndex: try transform(index))))
    }
}

extension FieldType {
    fileprivate func mapTypeIndices<E: Error>(_ transform: (UInt32) throws(E) -> UInt32) throws(E) -> FieldType {
        guard case .value(let valueType) = storage else { return self }
        return FieldType(storage: .value(try valueType.mapTypeIndices(transform)), isMutable: isMutable)
    }
}

extension CompositeType {
    fileprivate func mapTypeIndices<E: Error>(_ transform: (UInt32) throws(E) -> UInt32) throws(E) -> CompositeType {
        switch self {
        case .function(let type):
            var parameters: [ValueType] = []
            parameters.reserveCapacity(type.parameters.count)
            for parameter in type.parameters { parameters.append(try parameter.mapTypeIndices(transform)) }
            var results: [ValueType] = []
            results.reserveCapacity(type.results.count)
            for result in type.results { results.append(try result.mapTypeIndices(transform)) }
            return .function(FunctionType(parameters: parameters, results: results))
        case .structType(let type):
            var fields: [FieldType] = []
            fields.reserveCapacity(type.fields.count)
            for field in type.fields { fields.append(try field.mapTypeIndices(transform)) }
            return .structType(StructType(fields: fields))
        case .arrayType(let type):
            return .arrayType(ArrayType(element: try type.element.mapTypeIndices(transform)))
        }
    }
}
