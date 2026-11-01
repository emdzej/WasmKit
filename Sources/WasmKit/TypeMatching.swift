import WasmTypes

// Subtyping between canonical types (see TypeCanonicalization.swift), as
// defined by the GC proposal:
//
// - A numeric or vector type matches only itself.
// - `(ref null? ht1) <: (ref null ht2)` and `(ref ht1) <: (ref ht2)` iff
//   `ht1 <: ht2`; a nullable reference never matches a non-nullable one.
// - Abstract heap types form four hierarchies: `none <: i31, struct, array <:
//   eq <: any`, `nofunc <: func`, `noextern <: extern` and `noexn <: exn`.
// - A concrete heap type is below `func`, `struct` or `array` by what it
//   defines, and above that hierarchy's bottom type; two concrete heap types
//   match iff the first is the second or declares it as a supertype.

extension AbstractHeapType {
    func isSubtype(of other: AbstractHeapType) -> Bool {
        if self == other { return true }
        switch (self, other) {
        case (.eq, .any), (.i31, .any), (.structRef, .any), (.arrayRef, .any), (.noneRef, .any): return true
        case (.i31, .eq), (.structRef, .eq), (.arrayRef, .eq), (.noneRef, .eq): return true
        case (.noneRef, .i31), (.noneRef, .structRef), (.noneRef, .arrayRef): return true
        case (.noFunc, .funcRef), (.noExtern, .externRef), (.noExn, .exnRef): return true
        default: return false
        }
    }

    /// The top of the hierarchy the type is in.
    var top: AbstractHeapType {
        switch self {
        case .any, .eq, .i31, .structRef, .arrayRef, .noneRef: .any
        case .funcRef, .noFunc: .funcRef
        case .externRef, .noExtern: .externRef
        case .exnRef, .noExn: .exnRef
        }
    }

    /// The bottom of the hierarchy the type is in.
    var bottom: AbstractHeapType {
        switch top {
        case .funcRef: .noFunc
        case .externRef: .noExtern
        case .exnRef: .noExn
        default: .noneRef
        }
    }
}

extension CompositeType {
    /// The abstract heap type right above every type that defines this.
    var abstractSupertype: AbstractHeapType {
        switch self {
        case .function: .funcRef
        case .structType: .structRef
        case .arrayType: .arrayRef
        }
    }
}

extension TypeRegistry {
    /// The abstract heap type right above a heap type, or the type itself if it is abstract.
    func abstraction(of heapType: HeapType) -> AbstractHeapType {
        switch heapType {
        case .abstract(let type): type
        case .concrete(let id): definition(of: id).composite.abstractSupertype
        }
    }

    /// The top of the hierarchy a heap type is in.
    func top(of heapType: HeapType) -> AbstractHeapType {
        abstraction(of: heapType).top
    }

    func isSubtype(_ type: HeapType, of other: HeapType) -> Bool {
        if type == other { return true }
        switch (type, other) {
        case (.abstract(let type), .abstract(let other)):
            return type.isSubtype(of: other)
        case (.concrete(let type), .concrete(let other)):
            return isSubtype(type, of: other)
        case (.concrete(let type), .abstract(let other)):
            return definition(of: type).composite.abstractSupertype.isSubtype(of: other)
        case (.abstract(let type), .concrete(let other)):
            return type == definition(of: other).composite.abstractSupertype.bottom
        }
    }

    func isSubtype(_ type: ReferenceType, of other: ReferenceType) -> Bool {
        if type == other { return true }
        guard other.isNullable || !type.isNullable else { return false }
        return isSubtype(type.heapType, of: other.heapType)
    }

    func isSubtype(_ type: ValueType, of other: ValueType) -> Bool {
        if type == other { return true }
        guard case .ref(let reference) = type, case .ref(let otherReference) = other else { return false }
        return isSubtype(reference, of: otherReference)
    }

    /// Whether each type is a subtype of the type at the same position in `other`.
    func isSubtype(_ types: [ValueType], of other: [ValueType]) -> Bool {
        guard types.count == other.count else { return false }
        return zip(types, other).allSatisfy { isSubtype($0, of: $1) }
    }

    func isSubtype(_ type: StorageType, of other: StorageType) -> Bool {
        switch (type, other) {
        case (.value(let type), .value(let other)): isSubtype(type, of: other)
        case (.packed(let type), .packed(let other)): type == other
        default: false
        }
    }

    /// A mutable field can be both read and written, so its type must stay the same.
    func isSubtype(_ field: FieldType, of other: FieldType) -> Bool {
        guard field.isMutable == other.isMutable else { return false }
        return field.isMutable ? field.storage == other.storage : isSubtype(field.storage, of: other.storage)
    }

    func isSubtype(_ type: CompositeType, of other: CompositeType) -> Bool {
        switch (type, other) {
        case (.function(let type), .function(let other)):
            return isSubtype(other.parameters, of: type.parameters) && isSubtype(type.results, of: other.results)
        case (.structType(let type), .structType(let other)):
            guard type.fields.count >= other.fields.count else { return false }
            return zip(type.fields, other.fields).allSatisfy { isSubtype($0, of: $1) }
        case (.arrayType(let type), .arrayType(let other)):
            return isSubtype(type.element, of: other.element)
        default:
            return false
        }
    }
}

extension ValueType {
    /// Whether the type has a default value: zero for numbers and vectors, null
    /// for nullable references.
    var isDefaultable: Bool {
        guard case .ref(let referenceType) = self else { return true }
        return referenceType.isNullable
    }
}

extension StorageType {
    /// The type a value read from this storage has on the operand stack.
    var unpacked: ValueType {
        switch self {
        case .value(let type): type
        case .packed: .i32
        }
    }

    var isDefaultable: Bool {
        guard case .value(let type) = self else { return true }
        return type.isDefaultable
    }
}
