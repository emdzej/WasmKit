import WasmParser
import WasmTypes

// # GC values
//
// Every value of the `any` and `extern` hierarchies but their nulls has
// ``AnyReference/anyTag`` set in its ``UntypedValue``, which keeps it apart
// from function and exception references and from the null bit. Below the tag:
//
// - an `i31` is its 31 bits shifted left by one, with the lowest bit set;
// - an external value is its ``ExternAddress`` shifted left by two, over `0b10`;
// - a struct or an array is the address of its ``GCObject``, whose low bits
//   are clear.
//
// `any.convert_extern` and `extern.convert_any` therefore leave a value as it is.
//
// The objects live as long as the store that allocated them: ``GCHeap`` keeps
// each one, and a register or a field holds only its address.

/// How an instruction reads or writes a struct field or an array element, by the field's storage
/// type and, for a packed field, the extension it reads with.
enum GCStorageKind: UInt8 {
    /// An `i64`, an `f64` or a reference, in 8 bytes.
    case word = 0
    /// An `i32` or an `f32`, in 4 bytes.
    case u32
    case s8, u8
    case s16, u16
    /// A `v128`, in 16 bytes.
    case v128

    /// How a field of `storage` is accessed: `signed` picks the extension of a packed field.
    init(_ storage: StorageType, signed: Bool = false) {
        switch storage {
        case .packed(.i8): self = signed ? .s8 : .u8
        case .packed(.i16): self = signed ? .s16 : .u16
        case .value(.i32), .value(.f32): self = .u32
        case .value(.i64), .value(.f64), .value(.ref): self = .word
        case .value(.v128): self = .v128
        }
    }

    var byteCount: Int {
        switch self {
        case .word: 8
        case .u32: 4
        case .s8, .u8: 1
        case .s16, .u16: 2
        case .v128: 16
        }
    }

    /// Reads a value of this kind at `pointer`, as the low slot of a register and, for a
    /// `v128`, the high one.
    @inline(__always)
    func load(from pointer: UnsafeRawPointer) -> (UInt64, UInt64) {
        switch self {
        case .word: (pointer.loadUnaligned(as: UInt64.self), 0)
        case .u32: (UInt64(pointer.loadUnaligned(as: UInt32.self)), 0)
        case .s8: (UInt64(UInt32(bitPattern: Int32(pointer.load(as: Int8.self)))), 0)
        case .u8: (UInt64(pointer.load(as: UInt8.self)), 0)
        case .s16: (UInt64(UInt32(bitPattern: Int32(pointer.loadUnaligned(as: Int16.self)))), 0)
        case .u16: (UInt64(pointer.loadUnaligned(as: UInt16.self)), 0)
        case .v128: (pointer.loadUnaligned(as: UInt64.self), pointer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
    }

    /// Writes a value of this kind at `pointer`; a packed value is wrapped.
    @inline(__always)
    func store(_ low: UInt64, _ high: UInt64, to pointer: UnsafeMutableRawPointer) {
        switch self {
        case .word: pointer.storeBytes(of: low, as: UInt64.self)
        case .u32: pointer.storeBytes(of: UInt32(truncatingIfNeeded: low), as: UInt32.self)
        case .s8, .u8: pointer.storeBytes(of: UInt8(truncatingIfNeeded: low), as: UInt8.self)
        case .s16, .u16: pointer.storeBytes(of: UInt16(truncatingIfNeeded: low), as: UInt16.self)
        case .v128:
            pointer.storeBytes(of: low, as: UInt64.self)
            pointer.storeBytes(of: high, toByteOffset: 8, as: UInt64.self)
        }
    }

    /// Reads a value of this kind from the little-endian bytes of a data segment.
    func loadLittleEndian(from pointer: UnsafeRawPointer) -> (UInt64, UInt64) {
        switch self {
        case .word: (UInt64(littleEndian: pointer.loadUnaligned(as: UInt64.self)), 0)
        case .u32: (UInt64(UInt32(littleEndian: pointer.loadUnaligned(as: UInt32.self))), 0)
        case .s8, .u8: (UInt64(pointer.load(as: UInt8.self)), 0)
        case .s16, .u16: (UInt64(UInt16(littleEndian: pointer.loadUnaligned(as: UInt16.self))), 0)
        case .v128:
            (
                UInt64(littleEndian: pointer.loadUnaligned(as: UInt64.self)),
                UInt64(littleEndian: pointer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            )
        }
    }
}

/// Where a struct field or an array element is, and how it is stored.
struct GCField {
    /// The field's offset in a struct; zero for an array element.
    let offset: Int
    let kind: GCStorageKind
    /// Whether the field holds a reference, which a new object initializes to null.
    let isReference: Bool
}

/// The run-time view of a struct or array type, shared by its objects.
///
/// Owned by the ``TypeRegistry`` that defines the type; instructions and objects refer to it by
/// address, as the registry outlives every store of its engine.
final class GCTypeInfo: @unchecked Sendable {
    let typeID: UInt32
    /// See ``DefinedType/supertypeChain``.
    let supertypeChain: [UInt32]
    let isArray: Bool
    /// The struct's fields, or the array's element.
    let fields: [GCField]
    /// The size of a struct, or of an array element.
    let size: Int

    init(typeID: UInt32, supertypeChain: [UInt32], composite: CompositeType) {
        self.typeID = typeID
        self.supertypeChain = supertypeChain
        func field(_ type: FieldType, offset: Int) -> GCField {
            let isReference: Bool
            if case .value(.ref) = type.storage { isReference = true } else { isReference = false }
            return GCField(offset: offset, kind: GCStorageKind(type.storage), isReference: isReference)
        }
        switch composite {
        case .structType(let type):
            isArray = false
            var fields: [GCField] = []
            var offset = 0
            for fieldType in type.fields {
                let byteCount = GCStorageKind(fieldType.storage).byteCount
                let alignment = min(byteCount, 8)
                offset = (offset + alignment - 1) / alignment * alignment
                fields.append(field(fieldType, offset: offset))
                offset += byteCount
            }
            self.fields = fields
            size = offset
        case .arrayType(let type):
            isArray = true
            let element = field(type.element, offset: 0)
            fields = [element]
            size = element.kind.byteCount
        case .function:
            preconditionFailure("a function type has no objects")
        }
    }

    var element: GCField { fields[0] }

    /// Whether the type is `typeID` or declares it as a supertype, `depth` levels below the root.
    @inline(__always)
    func isSubtype(of typeID: UInt32, depth: Int) -> Bool {
        depth < supertypeChain.count && supertypeChain[depth] == typeID
    }

    var rawValue: UInt64 { UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())) }

    static func fromRaw(_ raw: UInt64) -> GCTypeInfo {
        Unmanaged<GCTypeInfo>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(raw)).unsafelyUnwrapped).takeUnretainedValue()
    }
}

struct GCObjectHeader {
    unowned(unsafe) let type: GCTypeInfo
    /// The number of elements of an array; zero for a struct.
    let length: Int
}

/// A struct or an array: its fields or elements, as ``GCTypeInfo`` lays them out.
final class GCObject: ManagedBuffer<GCObjectHeader, UInt64> {
    var type: GCTypeInfo { header.type }
    var length: Int { header.length }

    @inline(__always)
    var storage: UnsafeMutableRawPointer {
        withUnsafeMutablePointerToElements { UnsafeMutableRawPointer($0) }
    }

    /// The value of a reference to the object.
    var bits: UInt64 {
        AnyReference.anyTag | UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
    }

    /// The object a non-null value refers to, which must be a struct or an array.
    @inline(__always)
    static func from(bits: UInt64) -> GCObject {
        let address = UInt(truncatingIfNeeded: bits & ~AnyReference.anyTag)
        return Unmanaged<GCObject>.fromOpaque(UnsafeRawPointer(bitPattern: address).unsafelyUnwrapped).takeUnretainedValue()
    }

    /// The element at `index` of an array, which must be in bounds.
    @inline(__always)
    func element(at index: Int) -> UnsafeMutableRawPointer {
        storage + index * type.size
    }
}

/// Classifies the value of a non-null reference of the `any` or `extern` hierarchies.
enum GCBits {
    @inline(__always)
    static func isAnyOrExtern(_ bits: UInt64) -> Bool { bits & AnyReference.anyTag != 0 }
    @inline(__always)
    static func isI31(_ bits: UInt64) -> Bool { bits & 1 == 1 }
    @inline(__always)
    static func isObject(_ bits: UInt64) -> Bool { bits & 0b11 == 0 }
    @inline(__always)
    static func isExtern(_ bits: UInt64) -> Bool { bits & 0b11 == 0b10 }

    static func i31(_ value: UInt32) -> UInt64 {
        AnyReference.anyTag | (UInt64(value & 0x7FFF_FFFF) << 1) | 1
    }

    static func extern(_ address: ExternAddress) -> UInt64 {
        precondition(address >= 0 && UInt64(address) < 1 << 60, "an extern address must be in 0..<2^60")
        return AnyReference.anyTag | (UInt64(address) << 2) | 0b10
    }

    static func externAddress(_ bits: UInt64) -> ExternAddress {
        ExternAddress(truncatingIfNeeded: (bits & ~AnyReference.anyTag) >> 2)
    }

    /// The reference a non-null value of the `any` or `extern` hierarchies stands for.
    static func reference(_ bits: UInt64) -> Reference {
        if isExtern(bits) { return .extern(externAddress(bits)) }
        return .any(AnyReference(bits: bits, object: isObject(bits) ? GCObject.from(bits: bits) : nil))
    }
}

extension AnyReference {
    /// Whether the value is a struct.
    public var isStruct: Bool {
        GCBits.isObject(bits) && !GCObject.from(bits: bits).type.isArray
    }

    /// Whether the value is an array.
    public var isArray: Bool {
        GCBits.isObject(bits) && GCObject.from(bits: bits).type.isArray
    }
}

/// The reference type `ref.test`, `ref.cast` and `br_on_cast` test a reference against, packed
/// into an immediate.
///
/// Bits 0 to 31 hold a concrete type's canonical ID, 32 to 39 the raw value of an abstract heap
/// type or `0xFF` for a concrete one, bit 40 whether null matches, 41 and 42 what a concrete type
/// defines, and 48 to 55 its depth below the root of its supertypes.
struct CastTarget {
    let rawValue: UInt64

    private static let concrete: UInt64 = 0xFF
    private enum Kind: UInt64 {
        case function = 0, structType, arrayType
    }

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(_ type: ReferenceType, registry: TypeRegistry) {
        var rawValue: UInt64 = type.isNullable ? 1 << 40 : 0
        switch type.heapType {
        case .abstract(let heapType):
            rawValue |= UInt64(heapType.rawValue) << 32
        case .concrete(let id):
            let definition = registry.definition(of: id)
            let kind: Kind
            switch definition.composite {
            case .function: kind = .function
            case .structType: kind = .structType
            case .arrayType: kind = .arrayType
            }
            rawValue |= UInt64(id) | Self.concrete << 32 | kind.rawValue << 41 | UInt64(definition.depth) << 48
        }
        self.rawValue = rawValue
    }

    private var typeID: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
    private var heapTypeRawValue: UInt64 { (rawValue >> 32) & 0xFF }
    private var isNullable: Bool { rawValue & (1 << 40) != 0 }
    private var depth: Int { Int((rawValue >> 48) & 0xFF) }

    /// Whether `value`, a reference of the target's hierarchy, is of the target type.
    func matches(_ value: UntypedValue, registry: TypeRegistry) -> Bool {
        guard !value.isNullRef else { return isNullable }
        let bits = value.storage
        guard heapTypeRawValue != Self.concrete else {
            switch Kind(rawValue: (rawValue >> 41) & 0b11) {
            case .function:
                let actual = InternalFunction(bitPattern: Int(truncatingIfNeeded: bits)).type.id
                return actual == typeID || registry.isSubtype(actual, of: typeID)
            case .structType, .arrayType:
                return GCBits.isAnyOrExtern(bits) && GCBits.isObject(bits)
                    && GCObject.from(bits: bits).type.isSubtype(of: typeID, depth: depth)
            case nil:
                return false
            }
        }
        switch AbstractHeapType(rawValue: UInt8(heapTypeRawValue)) {
        case .any, .funcRef, .externRef, .exnRef:
            return true
        case .eq:
            return GCBits.isAnyOrExtern(bits) && !GCBits.isExtern(bits)
        case .i31:
            return GCBits.isAnyOrExtern(bits) && GCBits.isI31(bits)
        case .structRef:
            return GCBits.isAnyOrExtern(bits) && GCBits.isObject(bits) && !GCObject.from(bits: bits).type.isArray
        case .arrayRef:
            return GCBits.isAnyOrExtern(bits) && GCBits.isObject(bits) && GCObject.from(bits: bits).type.isArray
        case .noneRef, .noExtern, .noFunc, .noExn, nil:
            return false
        }
    }
}

/// The structs and arrays of a store.
///
/// An object is freed once no root reaches it, by a mark-and-sweep collection that an allocation
/// starts when the heap has grown enough since the last one. The roots are:
///
/// - the slots of every stack the store's guest code runs on, scanned conservatively, as a slot
///   does not say what it holds: one that looks like the address of an object keeps it;
/// - the values of the store's globals and tables, from ``rootScanner``;
/// - every object something but the heap holds a strong reference to, which is how an
///   ``AnyReference`` the host keeps, an element segment or an exception keeps one.
///
/// From the roots, the fields and elements of reference type of each object reached are traced.
final class GCHeap {
    private var objects: [GCObject] = []
    /// The bytes the objects take, to refuse an allocation the host could not make.
    private var byteCount = 0
    /// The bytes allocated since the last collection, and how many start the next.
    private var allocatedSinceCollection = 0
    private var collectionThreshold = GCHeap.minimumThreshold
    /// The stacks guest code of the store is running, or suspended, on.
    private var stacks: [UnsafeMutableBufferPointer<StackSlot>] = []
    /// Reports the values of the store's globals and tables to a collection.
    var rootScanner: ((inout GCMarker) -> Void)?

    /// The most bytes the objects of one store may take: 4 GiB, or what a 32-bit host can address.
    static let byteLimit = Int(clamping: UInt64(1) << 32)
    /// The bytes a heap grows by before its first collection; later, it may grow by as much as it
    /// kept in the last one.
    private static let minimumThreshold = 1 << 20

    /// The bytes the objects take on top of their fields, which a collection's trigger counts too.
    private static let objectOverhead = 32

    /// Records a stack whose slots are roots until ``removeStack(_:)``.
    func addStack(_ slots: UnsafeMutablePointer<StackSlot>, count: Int) {
        stacks.append(UnsafeMutableBufferPointer(start: slots, count: count))
    }

    func removeStack(_ slots: UnsafeMutablePointer<StackSlot>) {
        guard let index = stacks.lastIndex(where: { $0.baseAddress == slots }) else { return }
        stacks.remove(at: index)
    }

    /// Allocates an array of `type` with a length a guest chose.
    func allocate(_ type: GCTypeInfo, length: UInt32) throws -> GCObject {
        guard let length = Int(exactly: length) else {
            throw Trap(.message(.gcAllocationTooLarge))
        }
        return try allocate(type, length: length)
    }

    /// Allocates an object of `type` with its fields or elements zeroed, and its references null.
    ///
    /// - Parameter length: The number of elements of an array.
    func allocate(_ type: GCTypeInfo, length: Int = 0) throws -> GCObject {
        let (size, overflow) = type.isArray ? length.multipliedReportingOverflow(by: type.size) : (type.size, false)
        guard !overflow, size <= Self.byteLimit else {
            throw Trap(.message(.gcAllocationTooLarge))
        }
        if allocatedSinceCollection + size >= collectionThreshold || size > Self.byteLimit - byteCount {
            collect()
            guard size <= Self.byteLimit - byteCount else {
                throw Trap(.message(.gcAllocationTooLarge))
            }
        }
        let wordCount = (size + 7) / 8
        let object = unsafeDowncast(
            GCObject.create(minimumCapacity: wordCount) { _ in GCObjectHeader(type: type, length: length) },
            to: GCObject.self)
        let storage = object.storage
        storage.initializeMemory(as: UInt64.self, repeating: 0, count: wordCount)
        if type.isArray {
            if type.element.isReference {
                storage.initializeMemory(as: UInt64.self, repeating: UntypedValue.nullReference.storage, count: length)
            }
        } else {
            for field in type.fields where field.isReference {
                (storage + field.offset).storeBytes(of: UntypedValue.nullReference.storage, as: UInt64.self)
            }
        }
        objects.append(object)
        byteCount += size
        allocatedSinceCollection += size + Self.objectOverhead
        return object
    }

    /// The number of objects the heap holds, for tests.
    var objectCount: Int { objects.count }

    /// Frees every object no root reaches.
    func collect() {
        var marker = GCMarker(objects: objects)
        // Before anything else makes a temporary reference to an object.
        for index in objects.indices where !isKnownUniquelyReferenced(&objects[index]) {
            marker.mark(index)
        }
        for stack in stacks {
            for slot in stack {
                marker.visit(slot)
            }
        }
        rootScanner?(&marker)
        marker.trace(objects)

        var kept: [GCObject] = []
        kept.reserveCapacity(marker.markedCount)
        var keptBytes = 0
        for (index, object) in objects.enumerated() where marker.isMarked(index) {
            kept.append(object)
            keptBytes += object.type.isArray ? object.length * object.type.size : object.type.size
        }
        objects = kept
        byteCount = keptBytes
        allocatedSinceCollection = 0
        collectionThreshold = max(Self.minimumThreshold, keptBytes + kept.count * Self.objectOverhead)
    }
}

/// The objects a collection has reached so far.
struct GCMarker {
    /// The index of each object by its address.
    private let indices: [UInt: Int]
    private var marked: [Bool]
    private var pending: [Int] = []
    private(set) var markedCount = 0

    fileprivate init(objects: [GCObject]) {
        var indices: [UInt: Int] = [:]
        indices.reserveCapacity(objects.count)
        for (index, object) in objects.enumerated() {
            indices[UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())] = index
        }
        self.indices = indices
        self.marked = Array(repeating: false, count: objects.count)
    }

    fileprivate mutating func mark(_ index: Int) {
        guard !marked[index] else { return }
        marked[index] = true
        markedCount += 1
        pending.append(index)
    }

    fileprivate func isMarked(_ index: Int) -> Bool { marked[index] }

    /// Marks the object `bits` refers to, if it is a reference to one of the heap's objects.
    mutating func visit(_ bits: UInt64) {
        guard bits & UntypedValue.nullReference.storage == 0, GCBits.isAnyOrExtern(bits), GCBits.isObject(bits),
            let index = indices[UInt(truncatingIfNeeded: bits & ~AnyReference.anyTag)]
        else { return }
        mark(index)
    }

    /// Marks what the marked objects refer to, until nothing more is reached.
    fileprivate mutating func trace(_ objects: [GCObject]) {
        while let index = pending.popLast() {
            let object = objects[index]
            let type = object.type
            if type.isArray {
                guard type.element.isReference else { continue }
                let elements = object.storage.assumingMemoryBound(to: UInt64.self)
                for element in 0..<object.length {
                    visit(elements[element])
                }
            } else {
                for field in type.fields where field.isReference {
                    visit((object.storage + field.offset).loadUnaligned(as: UInt64.self))
                }
            }
        }
    }
}
