import WasmParser
import WasmTypes

// # Canonical types
//
// A concrete heap type in a module, `(ref $t)`, names a type by its index in
// that module's type section. The typed function references proposal compares
// such types structurally, also across modules: two indices whose function
// types are equal (after resolving the concrete types nested in them) are the
// same type.
//
// Inside the engine, a concrete heap type therefore carries a canonical type ID
// instead of a module-relative index: the ID the engine's function type
// interner gives the type's signature once every nested concrete type in it
// has itself been made canonical. Because a type may only refer to types
// defined before it, the type section can be canonicalized in order, and two
// types are equivalent exactly when their canonical IDs are equal.
//
// Canonical types reuse `HeapType.concrete(typeIndex:)`, so the same Swift
// value means a module index in parsed `Module` data and a canonical ID in
// everything the translator and the runtime see: function entities, globals,
// tables, element segments and `Function.type`. A type without concrete heap
// types is its own canonical form. Function types given by the host are taken
// to be canonical already.

extension WasmKitError.Message {
    static func unknownType(_ index: UInt32) -> Self {
        Self("unknown type \(index)")
    }
}

/// Maps the type indices of one module to canonical type IDs.
struct TypeCanonicalizer {
    /// The canonical ID of each type in the module's type section.
    let typeIDs: [InternedFuncType]

    /// Canonicalizes a module's type section.
    ///
    /// Throws "unknown type" if a type refers to a later type, or to itself without `gc`.
    ///
    /// A function type is canonical by its signature alone. GC types are canonical by the
    /// recursion group they are defined in, with their finality and supertypes, which this does
    /// not model yet. So it rejects whatever would make two types with one signature distinct, or
    /// relate types other than by equality: recursion groups of more than one type, a type
    /// referring to itself, and a type that is not final or declares supertypes.
    init(typeSection: TypeSection, features: WasmFeatureSet, interner: Interner<FunctionType>) throws(WasmKitError) {
        var typeIDs: [InternedFuncType] = []
        typeIDs.reserveCapacity(typeSection.count)
        for group in typeSection.recursiveGroups {
            guard group.types.count <= 1 else {
                throw WasmKitError("recursion groups of more than one type are not supported yet")
            }
            for type in group.types {
                guard type.isFinal, type.supertypes.isEmpty else {
                    throw WasmKitError("subtype declarations are not supported yet")
                }
                guard case .function(let functionType) = type.body else {
                    throw WasmKitError("GC type definitions are not supported yet")
                }
                // With GC, a type may refer to the types of its own recursion group.
                let ownIndex = TypeIndex(typeIDs.count)
                if features.contains(.gc), (functionType.parameters + functionType.results).contains(where: { $0.concreteTypeIndex == ownIndex }) {
                    throw WasmKitError("recursive types are not supported yet")
                }
                // Only the types defined so far are visible to this one.
                let canonical = try TypeCanonicalizer(typeIDs: typeIDs).canonicalize(functionType)
                typeIDs.append(interner.intern(canonical))
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

extension ValueType {
    /// Whether the type refers to a type in a type section.
    fileprivate var hasConcreteHeapType: Bool {
        concreteTypeIndex != nil
    }

    /// The index of the type in a type section the type refers to, if any.
    fileprivate var concreteTypeIndex: TypeIndex? {
        guard case .ref(let referenceType) = self, case .concrete(let index) = referenceType.heapType else { return nil }
        return index
    }
}
