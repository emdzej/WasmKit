/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#aggregate-reference-instructions>

import WasmParser

extension Execution {
    // MARK: - i31

    mutating func refI31(sp: Sp, immediate: Instruction.RefI31Operand) {
        sp[immediate.result] = UntypedValue(storage: GCBits.i31(sp[immediate.value].i32))
    }
    mutating func i31GetS(sp: Sp, immediate: Instruction.I31GetSOperand) throws {
        let value = sp[immediate.value]
        guard !value.isNullRef else { throw Trap(.message(.nullI31Reference)) }
        // Shifting the 31 bits to the top and back extends their sign.
        let bits = UInt32(truncatingIfNeeded: value.storage >> 1) << 1
        sp[immediate.result] = UntypedValue(signed: Int32(bitPattern: bits) >> 1)
    }
    mutating func i31GetU(sp: Sp, immediate: Instruction.I31GetUOperand) throws {
        let value = sp[immediate.value]
        guard !value.isNullRef else { throw Trap(.message(.nullI31Reference)) }
        sp[immediate.result] = .i32(UInt32(truncatingIfNeeded: value.storage >> 1) & 0x7FFF_FFFF)
    }

    // MARK: - Structs

    mutating func structNew(sp: Sp, immediate: Instruction.StructNewOperand) throws {
        let type = GCTypeInfo.fromRaw(immediate.rawType)
        let object = try store.value.gcHeap.allocate(type)
        let storage = object.storage
        var slot = immediate.fields
        for field in type.fields {
            if field.kind == .v128 {
                field.kind.store(sp[slot].storage, sp[slot.nextSlot].storage, to: storage + field.offset)
                slot = slot.nextSlot.nextSlot
            } else {
                field.kind.store(sp[slot].storage, 0, to: storage + field.offset)
                slot = slot.nextSlot
            }
        }
        sp[immediate.result] = UntypedValue(storage: object.bits)
    }
    mutating func structNewDefault(sp: Sp, immediate: Instruction.StructNewDefaultOperand) throws {
        let object = try store.value.gcHeap.allocate(GCTypeInfo.fromRaw(immediate.rawType))
        sp[immediate.result] = UntypedValue(storage: object.bits)
    }
    mutating func structGet(sp: Sp, immediate: Instruction.StructGetOperand) throws {
        let reference = sp[immediate.object]
        guard !reference.isNullRef else { throw Trap(.message(.nullStructReference)) }
        let object = GCObject.from(bits: reference.storage)
        let kind = GCStorageKind(rawValue: immediate.kind).unsafelyUnwrapped
        let (low, high) = kind.load(from: object.storage + Int(immediate.offset))
        sp[immediate.result] = UntypedValue(storage: low)
        if kind == .v128 {
            sp[immediate.result.nextSlot] = UntypedValue(storage: high)
        }
    }
    mutating func structSet(sp: Sp, immediate: Instruction.StructSetOperand) throws {
        let reference = sp[immediate.object]
        guard !reference.isNullRef else { throw Trap(.message(.nullStructReference)) }
        let object = GCObject.from(bits: reference.storage)
        let kind = GCStorageKind(rawValue: immediate.kind).unsafelyUnwrapped
        let high = kind == .v128 ? sp[immediate.value.nextSlot].storage : 0
        kind.store(sp[immediate.value].storage, high, to: object.storage + Int(immediate.offset))
    }

    // MARK: - Arrays

    /// The array a non-null reference refers to.
    private func array(_ reference: UntypedValue) throws -> GCObject {
        guard !reference.isNullRef else { throw Trap(.message(.nullArrayReference)) }
        return GCObject.from(bits: reference.storage)
    }

    /// Checks that `count` elements from `offset` are in an array of `length` elements.
    private func checkArrayRange(offset: UInt32, count: UInt32, length: Int) throws {
        guard UInt64(offset) + UInt64(count) <= UInt64(length) else {
            throw Trap(.message(.arrayOutOfBounds))
        }
    }

    /// Reads the value of an element-kind register, with its high slot for a `v128`.
    private func load(_ register: VReg, kind: GCStorageKind, sp: Sp) -> (UInt64, UInt64) {
        (sp[register].storage, kind == .v128 ? sp[register.nextSlot].storage : 0)
    }

    private func fill(_ object: GCObject, from index: Int, count: Int, with value: (UInt64, UInt64)) {
        let kind = object.type.element.kind
        for index in index..<index + count {
            kind.store(value.0, value.1, to: object.element(at: index))
        }
    }

    mutating func arrayNew(sp: Sp, pc: Pc, immediate: Instruction.ArrayNewOperand) throws {
        let type = GCTypeInfo.fromRaw(immediate.rawType)
        let length = sp[immediate.length].i32
        let bytes = UInt64(length) * UInt64(type.size)
        try reserveBytesCopied(bytes, sp: sp, pc: pc, for: Instruction.ArrayNewOperand.self)
        let object = try store.value.gcHeap.allocate(type, length: length)
        fill(object, from: 0, count: object.length, with: load(immediate.value, kind: type.element.kind, sp: sp))
        sp[immediate.result] = UntypedValue(storage: object.bits)
        try chargeBytesCopied(bytes)
    }
    mutating func arrayNewDefault(sp: Sp, pc: Pc, immediate: Instruction.ArrayNewDefaultOperand) throws {
        let type = GCTypeInfo.fromRaw(immediate.rawType)
        let length = sp[immediate.length].i32
        let bytes = UInt64(length) * UInt64(type.size)
        try reserveBytesCopied(bytes, sp: sp, pc: pc, for: Instruction.ArrayNewDefaultOperand.self)
        let object = try store.value.gcHeap.allocate(type, length: length)
        sp[immediate.result] = UntypedValue(storage: object.bits)
        try chargeBytesCopied(bytes)
    }
    mutating func arrayNewFixed(sp: Sp, immediate: Instruction.ArrayNewFixedOperand) throws {
        let type = GCTypeInfo.fromRaw(immediate.rawType)
        let object = try store.value.gcHeap.allocate(type, length: Int(immediate.count))
        let kind = type.element.kind
        var slot = immediate.values
        for index in 0..<Int(immediate.count) {
            kind.store(sp[slot].storage, kind == .v128 ? sp[slot.nextSlot].storage : 0, to: object.element(at: index))
            slot = kind == .v128 ? slot.nextSlot.nextSlot : slot.nextSlot
        }
        sp[immediate.result] = UntypedValue(storage: object.bits)
    }
    mutating func arrayNewData(sp: Sp, pc: Pc, immediate: Instruction.ArrayNewDataOperand) throws {
        let type = GCTypeInfo.fromRaw(immediate.rawType)
        let offset = sp[immediate.offset].i32
        let length = sp[immediate.length].i32
        let data = currentInstance(sp: sp).dataSegments[Int(immediate.dataIndex)].data
        let byteCount = UInt64(length) * UInt64(type.size)
        try reserveBytesCopied(byteCount, sp: sp, pc: pc, for: Instruction.ArrayNewDataOperand.self)
        guard UInt64(offset) + byteCount <= UInt64(data.count) else {
            throw Trap(.memoryOutOfBounds)
        }
        let object = try store.value.gcHeap.allocate(type, length: length)
        Self.copy(data, from: Int(offset), into: object, at: 0, count: object.length)
        sp[immediate.result] = UntypedValue(storage: object.bits)
        try chargeBytesCopied(byteCount)
    }
    mutating func arrayNewElem(sp: Sp, pc: Pc, immediate: Instruction.ArrayNewElemOperand) throws {
        let type = GCTypeInfo.fromRaw(immediate.rawType)
        let offset = sp[immediate.offset].i32
        let length = sp[immediate.length].i32
        let references = currentInstance(sp: sp).elementSegments[Int(immediate.elemIndex)].references
        try reserveElementsCopied(UInt64(length), sp: sp, pc: pc, for: Instruction.ArrayNewElemOperand.self)
        guard UInt64(offset) + UInt64(length) <= UInt64(references.count) else {
            throw Trap(.tableOutOfBounds(Int(clamping: offset)))
        }
        let object = try store.value.gcHeap.allocate(type, length: length)
        Self.copy(references, from: Int(offset), into: object, at: 0, count: object.length)
        sp[immediate.result] = UntypedValue(storage: object.bits)
        try chargeElementsCopied(UInt64(length))
    }

    /// Copies elements from the little-endian bytes of a data segment.
    private static func copy(_ data: ArraySlice<UInt8>, from offset: Int, into object: GCObject, at index: Int, count: Int) {
        let kind = object.type.element.kind
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for element in 0..<count {
                let (low, high) = kind.loadLittleEndian(from: base + offset + element * kind.byteCount)
                kind.store(low, high, to: object.element(at: index + element))
            }
        }
    }

    /// Copies references from an element segment.
    private static func copy(_ references: [Reference], from offset: Int, into object: GCObject, at index: Int, count: Int) {
        for element in 0..<count {
            let value = UntypedValue(.ref(references[offset + element]))
            object.type.element.kind.store(value.storage, 0, to: object.element(at: index + element))
        }
    }

    mutating func arrayGet(sp: Sp, immediate: Instruction.ArrayGetOperand) throws {
        let object = try array(sp[immediate.array])
        let index = sp[immediate.index].i32
        // Compared unsigned: an index above `Int.max` is out of bounds on a 32-bit host too.
        guard UInt(index) < UInt(object.length) else { throw Trap(.message(.arrayOutOfBounds)) }
        let kind = GCStorageKind(rawValue: immediate.kind).unsafelyUnwrapped
        let (low, high) = kind.load(from: object.element(at: Int(index)))
        sp[immediate.result] = UntypedValue(storage: low)
        if kind == .v128 {
            sp[immediate.result.nextSlot] = UntypedValue(storage: high)
        }
    }
    mutating func arraySet(sp: Sp, immediate: Instruction.ArraySetOperand) throws {
        let object = try array(sp[immediate.array])
        let index = sp[immediate.index].i32
        // Compared unsigned: an index above `Int.max` is out of bounds on a 32-bit host too.
        guard UInt(index) < UInt(object.length) else { throw Trap(.message(.arrayOutOfBounds)) }
        let kind = GCStorageKind(rawValue: immediate.kind).unsafelyUnwrapped
        let (low, high) = load(immediate.value, kind: kind, sp: sp)
        kind.store(low, high, to: object.element(at: Int(index)))
    }
    mutating func arrayLen(sp: Sp, immediate: Instruction.ArrayLenOperand) throws {
        let object = try array(sp[immediate.array])
        sp[immediate.result] = .i32(UInt32(truncatingIfNeeded: object.length))
    }
    mutating func arrayFill(sp: Sp, pc: Pc, immediate: Instruction.ArrayFillOperand) throws {
        let object = try array(sp[immediate.array])
        let offset = sp[immediate.offset].i32
        let size = sp[immediate.size].i32
        let bytes = UInt64(size) * UInt64(object.type.size)
        try reserveBytesCopied(bytes, sp: sp, pc: pc, for: Instruction.ArrayFillOperand.self)
        try checkArrayRange(offset: offset, count: size, length: object.length)
        let kind = GCStorageKind(rawValue: immediate.kind).unsafelyUnwrapped
        fill(object, from: Int(offset), count: Int(size), with: load(immediate.value, kind: kind, sp: sp))
        try chargeBytesCopied(bytes)
    }
    mutating func arrayCopy(sp: Sp, pc: Pc, immediate: Instruction.ArrayCopyOperand) throws {
        let destination = try array(sp[immediate.destArray])
        let source = try array(sp[immediate.sourceArray])
        let destinationOffset = sp[immediate.destOffset].i32
        let sourceOffset = sp[immediate.sourceOffset].i32
        let size = sp[immediate.size].i32
        let bytes = UInt64(size) * UInt64(destination.type.size)
        try reserveBytesCopied(bytes, sp: sp, pc: pc, for: Instruction.ArrayCopyOperand.self)
        try checkArrayRange(offset: destinationOffset, count: size, length: destination.length)
        try checkArrayRange(offset: sourceOffset, count: size, length: source.length)
        guard size > 0 else { return }
        // The element types match, so the elements are moved as bytes; `copyMemory` allows the
        // ranges of one array to overlap.
        destination.element(at: Int(destinationOffset)).copyMemory(
            from: source.element(at: Int(sourceOffset)), byteCount: Int(bytes))
        try chargeBytesCopied(bytes)
    }
    mutating func arrayInitData(sp: Sp, pc: Pc, immediate: Instruction.ArrayInitDataOperand) throws {
        let object = try array(sp[immediate.array])
        let destinationOffset = sp[immediate.destOffset].i32
        let sourceOffset = sp[immediate.sourceOffset].i32
        let size = sp[immediate.size].i32
        let bytes = UInt64(size) * UInt64(object.type.size)
        try reserveBytesCopied(bytes, sp: sp, pc: pc, for: Instruction.ArrayInitDataOperand.self)
        try checkArrayRange(offset: destinationOffset, count: size, length: object.length)
        let data = currentInstance(sp: sp).dataSegments[Int(immediate.dataIndex)].data
        guard UInt64(sourceOffset) + bytes <= UInt64(data.count) else {
            throw Trap(.memoryOutOfBounds)
        }
        Self.copy(data, from: Int(sourceOffset), into: object, at: Int(destinationOffset), count: Int(size))
        try chargeBytesCopied(bytes)
    }
    mutating func arrayInitElem(sp: Sp, pc: Pc, immediate: Instruction.ArrayInitElemOperand) throws {
        let object = try array(sp[immediate.array])
        let destinationOffset = sp[immediate.destOffset].i32
        let sourceOffset = sp[immediate.sourceOffset].i32
        let size = sp[immediate.size].i32
        try reserveElementsCopied(UInt64(size), sp: sp, pc: pc, for: Instruction.ArrayInitElemOperand.self)
        try checkArrayRange(offset: destinationOffset, count: size, length: object.length)
        let references = currentInstance(sp: sp).elementSegments[Int(immediate.elemIndex)].references
        guard UInt64(sourceOffset) + UInt64(size) <= UInt64(references.count) else {
            throw Trap(.tableOutOfBounds(Int(clamping: sourceOffset)))
        }
        Self.copy(references, from: Int(sourceOffset), into: object, at: Int(destinationOffset), count: Int(size))
        try chargeElementsCopied(UInt64(size))
    }

    // MARK: - Casts

    mutating func refTest(sp: Sp, immediate: Instruction.RefTestOperand) {
        let matches = CastTarget(rawValue: immediate.rawTarget).matches(sp[immediate.value], registry: store.value.engine.typeRegistry)
        sp[immediate.result] = .i32(matches ? 1 : 0)
    }
    mutating func refCast(sp: Sp, immediate: Instruction.RefCastOperand) throws {
        let value = sp[immediate.value]
        guard CastTarget(rawValue: immediate.rawTarget).matches(value, registry: store.value.engine.typeRegistry) else {
            throw Trap(.message(.castFailure))
        }
        sp[immediate.result] = value
    }
    mutating func brIfCast(sp: Sp, pc: Pc, immediate: Instruction.BrIfCastOperand) -> (Pc, CodeSlot) {
        guard CastTarget(rawValue: immediate.rawTarget).matches(sp[immediate.value], registry: store.value.engine.typeRegistry) else {
            return pc.next()
        }
        return pc.advanced(by: Int(immediate.offset)).next()
    }
    mutating func brIfNotCast(sp: Sp, pc: Pc, immediate: Instruction.BrIfNotCastOperand) -> (Pc, CodeSlot) {
        guard !CastTarget(rawValue: immediate.rawTarget).matches(sp[immediate.value], registry: store.value.engine.typeRegistry) else {
            return pc.next()
        }
        return pc.advanced(by: Int(immediate.offset)).next()
    }
}
