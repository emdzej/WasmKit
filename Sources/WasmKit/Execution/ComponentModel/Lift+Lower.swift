// Canonical ABI lifting and lowering, following the definitions in `CanonicalABI.md` and its
// reference `definitions.py`:
// https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md
//
// The functions here mirror the spec's `alignment`, `elem_size`, `flatten_type`, `load`, `store`,
// `lift_flat` and `lower_flat`, so that each can be checked against its counterpart. Futures and
// streams are not supported yet and are rejected; resource handles go through `Resources.swift`.

#if ComponentModel
    import ComponentModel

    /// The most core parameters a function passes directly; more are passed in memory.
    let MAX_FLAT_PARAMS = 16
    /// The most core results a function returns directly; more are returned in memory.
    let MAX_FLAT_RESULTS = 1

    /// The type information the canonical ABI needs: resolving type indices of one component.
    struct CanonicalABITypes {
        let space: ComponentTypeSpace

        func resolveType(_ index: ComponentTypeIndex) throws -> ComponentDefValType {
            try space.valueType(index)
        }

        func resourceType(_ index: ComponentTypeIndex) throws -> ComponentResourceType {
            try space.resourceType(index)
        }

        /// `t` with any top-level type index replaced by the type it names.
        ///
        /// Bounded, so that a cycle of type indices in a malformed component cannot loop.
        func despecialize(_ t: ComponentDefValType) throws -> ComponentDefValType {
            var t = t
            for _ in 0..<1024 {
                guard case .inlined(.index(let index)) = t else { return t }
                t = try resolveType(index)
            }
            throw CanonicalABIError(description: "type indices form a cycle")
        }

        func resolve(_ t: ComponentValType) throws -> ComponentDefValType {
            try despecialize(t.resolve(resolveType))
        }

        // MARK: - Variant shapes

        /// The payload types of a variant-like type's cases, in discriminant order: `variant`,
        /// `enum`, `option` and `result` all share the variant layout.
        func variantCases(_ t: ComponentDefValType) throws -> [ComponentDefValType?]? {
            switch try despecialize(t) {
            case .variant(let cases): return try cases.map { try $0.type.map(resolve) }
            case .enum(let labels): return labels.map { _ in nil }
            case .option(let some): return [nil, try resolve(some)]
            case .result(let ok, let error): return [try ok.map(resolve), try error.map(resolve)]
            default: return nil
            }
        }

        // MARK: - Layout

        /// The byte size of a discriminant for `count` cases.
        static func discriminantSize(cases count: Int) -> Int {
            count <= 1 << 8 ? 1 : count <= 1 << 16 ? 2 : 4
        }

        /// The byte size of the flags bit set for `count` labels.
        static func flagsSize(_ count: Int) -> Int {
            count <= 8 ? 1 : count <= 16 ? 2 : 4 * ((count + 31) / 32)
        }

        static func alignTo(_ offset: Int, _ alignment: Int) -> Int {
            (offset + alignment - 1) / alignment * alignment
        }

        func alignment(_ t: ComponentDefValType) throws -> Int {
            switch try despecialize(t) {
            case .inlined(.primitive(let p)):
                switch p {
                case .bool, .s8, .u8: return 1
                case .s16, .u16: return 2
                case .s32, .u32, .float32, .char, .string, .errorContext: return 4
                case .s64, .u64, .float64: return 8
                }
            case .list, .own, .borrow: return 4
            case .record(let fields): return try fields.reduce(1) { max($0, try alignment(resolve($1.type))) }
            case .tuple(let elements): return try elements.reduce(1) { max($0, try alignment(resolve($1))) }
            case .flags(let labels): return min(Self.flagsSize(labels.count), 4)
            case let t:
                guard let cases = try variantCases(t) else { throw unsupported(t) }
                return max(Self.discriminantSize(cases: cases.count), try maxCaseAlignment(cases))
            }
        }

        func maxCaseAlignment(_ cases: [ComponentDefValType?]) throws -> Int {
            try cases.reduce(1) { max($0, try $1.map(alignment) ?? 1) }
        }

        func size(_ t: ComponentDefValType) throws -> Int {
            switch try despecialize(t) {
            case .inlined(.primitive(let p)):
                switch p {
                case .bool, .s8, .u8: return 1
                case .s16, .u16: return 2
                case .s32, .u32, .float32, .char, .errorContext: return 4
                case .s64, .u64, .float64, .string: return 8
                }
            case .list: return 8
            case .own, .borrow: return 4
            case .record(let fields): return try fieldsSize(fields.map { try resolve($0.type) })
            case .tuple(let elements): return try fieldsSize(elements.map(resolve))
            case .flags(let labels): return Self.flagsSize(labels.count)
            case let t:
                guard let cases = try variantCases(t) else { throw unsupported(t) }
                var size = Self.discriminantSize(cases: cases.count)
                size = Self.alignTo(size, try maxCaseAlignment(cases))
                size += try cases.reduce(0) { max($0, try $1.map(self.size) ?? 0) }
                return Self.alignTo(size, try alignment(t))
            }
        }

        /// The size of fields laid out one after another, each at its alignment, as a record.
        func fieldsSize(_ fields: [ComponentDefValType]) throws -> Int {
            var size = 0
            var maxAlignment = 1
            for field in fields {
                let fieldAlignment = try alignment(field)
                maxAlignment = max(maxAlignment, fieldAlignment)
                size = Self.alignTo(size, fieldAlignment) + (try self.size(field))
            }
            return Self.alignTo(size, maxAlignment)
        }

        func fieldsAlignment(_ fields: [ComponentDefValType]) throws -> Int {
            try fields.reduce(1) { max($0, try alignment($1)) }
        }

        // MARK: - Flattening

        func flatten(_ t: ComponentDefValType) throws -> [ValueType] {
            switch try despecialize(t) {
            case .inlined(.primitive(let p)):
                switch p {
                case .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char, .errorContext: return [.i32]
                case .s64, .u64: return [.i64]
                case .float32: return [.f32]
                case .float64: return [.f64]
                case .string: return [.i32, .i32]
                }
            case .list: return [.i32, .i32]
            case .own, .borrow: return [.i32]
            case .record(let fields): return try fields.flatMap { try flatten(resolve($0.type)) }
            case .tuple(let elements): return try elements.flatMap { try flatten(resolve($0)) }
            case .flags(let labels): return Array(repeating: .i32, count: max(1, (labels.count + 31) / 32))
            case let t:
                guard let cases = try variantCases(t) else { throw unsupported(t) }
                return [.i32] + (try flattenVariantPayloads(cases))
            }
        }

        /// The joined payload slots of a variant's cases, after its discriminant.
        func flattenVariantPayloads(_ cases: [ComponentDefValType?]) throws -> [ValueType] {
            var flat: [ValueType] = []
            for case let payload? in cases {
                for (i, type) in try flatten(payload).enumerated() {
                    if i < flat.count {
                        flat[i] = Self.join(flat[i], type)
                    } else {
                        flat.append(type)
                    }
                }
            }
            return flat
        }

        static func join(_ a: ValueType, _ b: ValueType) -> ValueType {
            if a == b { return a }
            if (a == .i32 && b == .f32) || (a == .f32 && b == .i32) { return .i32 }
            return .i64
        }

        /// The core type of a function, as `flatten_functype`: `lifting` for a `canon lift`,
        /// whose results come back through a returned pointer, or not for a `canon lower`, whose
        /// caller passes a pointer to write them to.
        func flattenFunctionType(_ type: ComponentFuncType, lifting: Bool) throws -> FunctionType {
            var parameters = try type.params.flatMap { try flatten($0.type) }
            if parameters.count > MAX_FLAT_PARAMS {
                parameters = [.i32]
            }
            var results = try type.result.map(flatten) ?? []
            if results.count > MAX_FLAT_RESULTS {
                if lifting {
                    results = [.i32]
                } else {
                    parameters.append(.i32)
                    results = []
                }
            }
            return FunctionType(parameters: parameters, results: results)
        }

        func unsupported(_ t: ComponentDefValType) -> CanonicalABIError {
            CanonicalABIError(description: "the canonical ABI does not support \(t) yet")
        }
    }

    /// What one lift or lower runs against: the component's types, the canonical options, the
    /// store, and the instance whose handle table resources move through.
    struct CanonicalABIContext: ~Copyable {
        let types: CanonicalABITypes
        let options: CanonOptions
        let store: Store
        /// The spec's `cx.inst`: the instance of the `canon` definition doing the lift or lower.
        let instance: ComponentInstanceState?
        /// The call borrows are lowered into, when lowering a lifted function's arguments.
        let scope: CallScope?
        /// Handles lent to the call by lifting borrows of them, to return when it ends.
        var lenders: [ResourceHandle] = []
        /// Reused across `realloc` calls; a fresh stack costs an allocation per string or list.
        private var stack: ExecutionStack?

        init(
            types: CanonicalABITypes, options: CanonOptions, store: Store,
            instance: ComponentInstanceState? = nil, scope: CallScope? = nil
        ) {
            self.types = types
            self.options = options
            self.store = store
            self.instance = instance
            self.scope = scope
            self.stack = nil
        }

        /// Ends the loans of every handle a borrow was lifted from.
        mutating func releaseLenders() {
            for lender in lenders {
                lender.lendCount -= 1
            }
            lenders = []
        }

        // MARK: Handles

        var handleTable: ComponentInstanceState {
            get throws {
                guard let instance else {
                    throw CanonicalABIError(description: "resource handles need a component instance here")
                }
                return instance
            }
        }

        mutating func liftHandle(_ type: ComponentDefValType, _ index: UInt32) throws -> ComponentValue {
            switch type {
            case .own(let typeIndex):
                let resourceType = try types.resourceType(typeIndex)
                return .own(ComponentResource(type: resourceType, rep: try handleTable.liftOwn(index, of: resourceType)))
            case .borrow(let typeIndex):
                let resourceType = try types.resourceType(typeIndex)
                let rep = try handleTable.liftBorrow(index, of: resourceType, lenders: &lenders)
                return .borrow(ComponentResource(type: resourceType, rep: rep))
            default:
                preconditionFailure("\(type) is not a handle type")
            }
        }

        func lowerHandle(_ value: ComponentValue, as type: ComponentDefValType) throws -> UInt32 {
            switch (type, value) {
            case (.own(let typeIndex), .own(let resource)):
                let resourceType = try types.resourceType(typeIndex)
                guard resource.type === resourceType else { throw Self.mismatch(value, type) }
                return try handleTable.lowerOwn(resource.rep, of: resourceType)
            case (.borrow(let typeIndex), .borrow(let resource)), (.borrow(let typeIndex), .own(let resource)):
                // A host may lend a resource it owns without first wrapping it as a borrow.
                let resourceType = try types.resourceType(typeIndex)
                guard resource.type === resourceType else { throw Self.mismatch(value, type) }
                return try handleTable.lowerBorrow(resource.rep, of: resourceType, scope: scope)
            default:
                throw Self.mismatch(value, type)
            }
        }

        var memory: Memory {
            get throws {
                guard let memory = options.memory else {
                    throw CanonicalABIError(description: "the canonical ABI needs the `memory` option here")
                }
                return Memory(handle: memory, allocator: store.allocator)
            }
        }

        // MARK: Memory access

        /// Traps unless `count` bytes at `pointer` lie in memory and `pointer` is `alignment`-aligned.
        ///
        /// The messages follow wasmtime's, which the component model test suite checks for;
        /// `what` names the pointer in them, as `string` or `list`.
        func checkRange(_ pointer: Int, count: Int, alignment: Int, what: String? = nil) throws {
            guard pointer % alignment == 0 else {
                throw CanonicalABIError(description: "unaligned pointer: \(pointer) is not aligned to \(alignment)")
            }
            let (end, overflow) = pointer.addingReportingOverflow(count)
            guard pointer >= 0, count >= 0, !overflow, end <= (try memory.byteCount) else {
                let subject = what.map { "\($0) pointer/length" } ?? "pointer"
                throw CanonicalABIError(
                    description: "\(subject) out of bounds of memory: \(count) bytes at \(pointer)")
            }
        }

        func loadInt<T: FixedWidthInteger>(_ pointer: Int, as _: T.Type) throws -> T {
            try memory.withUnsafeBufferPointer(offset: UInt(pointer), count: MemoryLayout<T>.size) {
                T(littleEndian: $0.loadUnaligned(as: T.self))
            }
        }

        func storeInt<T: FixedWidthInteger>(_ value: T, at pointer: Int) throws {
            try memory.withUnsafeMutableBufferPointer(offset: UInt(pointer), count: MemoryLayout<T>.size) {
                $0.storeBytes(of: value.littleEndian, as: T.self)
            }
        }

        /// Reads an unsigned integer of `size` bytes (1, 2 or 4), as discriminants are stored.
        func loadDiscriminant(_ pointer: Int, size: Int) throws -> Int {
            switch size {
            case 1: return Int(try loadInt(pointer, as: UInt8.self))
            case 2: return Int(try loadInt(pointer, as: UInt16.self))
            default: return Int(try loadInt(pointer, as: UInt32.self))
            }
        }

        func storeDiscriminant(_ value: Int, size: Int, at pointer: Int) throws {
            switch size {
            case 1: try storeInt(UInt8(value), at: pointer)
            case 2: try storeInt(UInt16(value), at: pointer)
            default: try storeInt(UInt32(value), at: pointer)
            }
        }

        /// Asks the guest for `byteCount` bytes aligned to `alignment`, and checks what it returned.
        mutating func realloc(alignment: Int, byteCount: Int) throws -> Int {
            guard let realloc = options.realloc else {
                throw CanonicalABIError(description: "the canonical ABI needs the `realloc` option here")
            }
            guard let size = UInt32(exactly: byteCount) else {
                throw CanonicalABIError(description: "\(byteCount) bytes do not fit in guest memory")
            }
            if stack == nil {
                stack = ExecutionStack(pool: store.executionStacks)
            }
            let results = try realloc.invoke(
                [.i32(0), .i32(0), .i32(UInt32(alignment)), .i32(size)], store: store, stack: &stack!)
            guard results.count == 1, case .i32(let pointer) = results[0] else {
                throw CanonicalABIError(description: "realloc must return one i32")
            }
            // The pointer comes from the guest: check it before anything is written through it.
            try checkRange(Int(pointer), count: byteCount, alignment: alignment)
            return Int(pointer)
        }

        // MARK: - Load

        mutating func load(_ type: ComponentDefValType, at pointer: Int) throws -> ComponentValue {
            let t = try types.despecialize(type)
            switch t {
            case .inlined(.primitive(let p)):
                switch p {
                case .bool: return .bool(try loadInt(pointer, as: UInt8.self) != 0)
                case .s8: return .s8(try loadInt(pointer, as: Int8.self))
                case .u8: return .u8(try loadInt(pointer, as: UInt8.self))
                case .s16: return .s16(try loadInt(pointer, as: Int16.self))
                case .u16: return .u16(try loadInt(pointer, as: UInt16.self))
                case .s32: return .s32(try loadInt(pointer, as: Int32.self))
                case .u32: return .u32(try loadInt(pointer, as: UInt32.self))
                case .s64: return .s64(try loadInt(pointer, as: Int64.self))
                case .u64: return .u64(try loadInt(pointer, as: UInt64.self))
                case .float32: return .float32(Float(bitPattern: try loadInt(pointer, as: UInt32.self)))
                case .float64: return .float64(Double(bitPattern: try loadInt(pointer, as: UInt64.self)))
                case .char: return .char(try Self.char(try loadInt(pointer, as: UInt32.self)))
                case .string:
                    let begin = try loadInt(pointer, as: UInt32.self)
                    let taggedCodeUnits = try loadInt(pointer + 4, as: UInt32.self)
                    return .string(try loadString(begin: Int(begin), taggedCodeUnits: taggedCodeUnits))
                case .errorContext:
                    throw types.unsupported(t)
                }
            case .list(let element):
                let begin = try loadInt(pointer, as: UInt32.self)
                let length = try loadInt(pointer + 4, as: UInt32.self)
                return .list(try loadList(begin: Int(begin), length: Int(length), element: types.resolve(element)))
            case .own, .borrow:
                return try liftHandle(t, try loadInt(pointer, as: UInt32.self))
            case .record(let fields):
                let values = try loadFields(fields.map { try types.resolve($0.type) }, at: pointer)
                return .record(zip(fields, values).map { ($0.name, $1) })
            case .tuple(let elements):
                return .tuple(try loadFields(elements.map(types.resolve), at: pointer))
            case .flags(let labels):
                var bits: [UInt32] = []
                switch CanonicalABITypes.flagsSize(labels.count) {
                case 1: bits = [UInt32(try loadInt(pointer, as: UInt8.self))]
                case 2: bits = [UInt32(try loadInt(pointer, as: UInt16.self))]
                case let size:
                    for i in 0..<(size / 4) { bits.append(try loadInt(pointer + 4 * i, as: UInt32.self)) }
                }
                return Self.flags(labels, bits: bits)
            default:
                guard let cases = try types.variantCases(t) else { throw types.unsupported(t) }
                let discriminantSize = CanonicalABITypes.discriminantSize(cases: cases.count)
                let index = try loadDiscriminant(pointer, size: discriminantSize)
                guard index < cases.count else {
                    throw CanonicalABIError(description: "discriminant \(index) names no case of \(cases.count)")
                }
                let payloadOffset = CanonicalABITypes.alignTo(
                    pointer + discriminantSize, try types.maxCaseAlignment(cases))
                let payload = try cases[index].map { try load($0, at: payloadOffset) }
                return try Self.variantValue(t, case: index, payload: payload)
            }
        }

        /// Loads fields laid out as a record at `pointer`.
        mutating func loadFields(_ fieldTypes: [ComponentDefValType], at pointer: Int) throws -> [ComponentValue] {
            var offset = pointer
            var values: [ComponentValue] = []
            for fieldType in fieldTypes {
                offset = CanonicalABITypes.alignTo(offset, try types.alignment(fieldType))
                values.append(try load(fieldType, at: offset))
                offset += try types.size(fieldType)
            }
            return values
        }

        mutating func loadList(begin: Int, length: Int, element: ComponentDefValType) throws -> [ComponentValue] {
            let elementSize = try types.size(element)
            let (byteCount, overflow) = length.multipliedReportingOverflow(by: elementSize)
            guard !overflow else { throw CanonicalABIError(description: "list of \(length) elements overflows") }
            // Checked before reserving room for `length` values, which the guest chose.
            try checkRange(begin, count: byteCount, alignment: try types.alignment(element), what: "list")
            var values: [ComponentValue] = []
            values.reserveCapacity(length)
            for i in 0..<length {
                values.append(try load(element, at: begin + i * elementSize))
            }
            return values
        }

        static let utf16Tag: UInt32 = 1 << 31

        func loadString(begin: Int, taggedCodeUnits: UInt32) throws -> String {
            let alignment: Int
            let byteCount: Int
            let encoding: ComponentStringEncoding
            switch options.stringEncoding {
            case .utf8:
                (alignment, byteCount, encoding) = (1, Int(taggedCodeUnits), .utf8)
            case .utf16:
                (alignment, byteCount, encoding) = (2, 2 * Int(taggedCodeUnits), .utf16)
            case .latin1UTF16:
                if taggedCodeUnits & Self.utf16Tag != 0 {
                    (alignment, byteCount, encoding) = (2, 2 * Int(taggedCodeUnits ^ Self.utf16Tag), .utf16)
                } else {
                    // Latin-1 needs no alignment of its own, but the option is shared with UTF-16.
                    (alignment, byteCount, encoding) = (2, Int(taggedCodeUnits), .latin1UTF16)
                }
            }
            try checkRange(begin, count: byteCount, alignment: alignment, what: "string")
            return try memory.withUnsafeBufferPointer(offset: UInt(begin), count: byteCount) { bytes in
                switch encoding {
                case .utf8:
                    // `String(decoding:)` would replace invalid input with U+FFFD; the spec traps.
                    guard let string = String(validating: bytes, as: UTF8.self) else {
                        throw CanonicalABIError(description: "string is not valid UTF-8")
                    }
                    return string
                case .utf16:
                    let units = (0..<(byteCount / 2)).map {
                        UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8
                    }
                    guard let string = String(validating: units, as: UTF16.self) else {
                        throw CanonicalABIError(description: "string is not valid UTF-16")
                    }
                    return string
                case .latin1UTF16:
                    var scalars = String.UnicodeScalarView()
                    scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
                    return String(scalars)
                }
            }
        }

        // MARK: - Store

        mutating func store(_ value: ComponentValue, as type: ComponentDefValType, at pointer: Int) throws {
            let t = try types.despecialize(type)
            switch (t, value) {
            case (.inlined(.primitive(.bool)), .bool(let v)): try storeInt(UInt8(v ? 1 : 0), at: pointer)
            case (.inlined(.primitive(.s8)), .s8(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.u8)), .u8(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.s16)), .s16(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.u16)), .u16(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.s32)), .s32(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.u32)), .u32(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.s64)), .s64(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.u64)), .u64(let v)): try storeInt(v, at: pointer)
            case (.inlined(.primitive(.float32)), .float32(let v)): try storeInt(v.bitPattern, at: pointer)
            case (.inlined(.primitive(.float64)), .float64(let v)): try storeInt(v.bitPattern, at: pointer)
            case (.inlined(.primitive(.char)), .char(let v)): try storeInt(v.value, at: pointer)
            case (.inlined(.primitive(.string)), .string(let v)):
                let (begin, taggedCodeUnits) = try storeString(v)
                try storeInt(UInt32(begin), at: pointer)
                try storeInt(taggedCodeUnits, at: pointer + 4)
            case (.list(let element), .list(let elements)):
                let (begin, length) = try storeList(elements, element: types.resolve(element))
                try storeInt(UInt32(begin), at: pointer)
                try storeInt(UInt32(length), at: pointer + 4)
            case (.own, _), (.borrow, _):
                try storeInt(try lowerHandle(value, as: t), at: pointer)
            case (.record(let fields), .record(let values)):
                try storeFields(
                    Self.recordFields(fields, values), types: fields.map { try types.resolve($0.type) }, at: pointer)
            case (.tuple(let elements), .tuple(let values)):
                guard elements.count == values.count else { throw Self.mismatch(value, t) }
                try storeFields(values, types: elements.map(types.resolve), at: pointer)
            case (.flags(let labels), .flags(let set)):
                let bits = try Self.flagBits(labels, set)
                switch CanonicalABITypes.flagsSize(labels.count) {
                case 1: try storeInt(UInt8(bits[0]), at: pointer)
                case 2: try storeInt(UInt16(bits[0]), at: pointer)
                default: for (i, word) in bits.enumerated() { try storeInt(word, at: pointer + 4 * i) }
                }
            default:
                guard let cases = try types.variantCases(t) else { throw Self.mismatch(value, t) }
                let (index, payload) = try Self.variantCase(of: value, t)
                let discriminantSize = CanonicalABITypes.discriminantSize(cases: cases.count)
                try storeDiscriminant(index, size: discriminantSize, at: pointer)
                let payloadOffset = CanonicalABITypes.alignTo(
                    pointer + discriminantSize, try types.maxCaseAlignment(cases))
                if let payloadType = cases[index] {
                    guard let payload else { throw Self.mismatch(value, t) }
                    try store(payload, as: payloadType, at: payloadOffset)
                }
            }
        }

        /// Stores values laid out as a record at `pointer`.
        mutating func storeFields(
            _ values: [ComponentValue], types fieldTypes: [ComponentDefValType], at pointer: Int
        ) throws {
            var offset = pointer
            for (value, fieldType) in zip(values, fieldTypes) {
                offset = CanonicalABITypes.alignTo(offset, try types.alignment(fieldType))
                try store(value, as: fieldType, at: offset)
                offset += try types.size(fieldType)
            }
        }

        mutating func storeList(
            _ values: [ComponentValue], element: ComponentDefValType
        ) throws -> (begin: Int, length: Int) {
            let elementSize = try types.size(element)
            let (byteCount, overflow) = values.count.multipliedReportingOverflow(by: elementSize)
            guard !overflow else { throw CanonicalABIError(description: "list of \(values.count) elements overflows") }
            let begin = try realloc(alignment: try types.alignment(element), byteCount: byteCount)
            for (i, value) in values.enumerated() {
                try store(value, as: element, at: begin + i * elementSize)
            }
            return (begin, values.count)
        }

        /// Copies a string into guest memory in the options' encoding, returning where it went
        /// and its length in code units, tagged for UTF-16 under `latin1+utf16`.
        mutating func storeString(_ string: String) throws -> (begin: Int, taggedCodeUnits: UInt32) {
            func check(_ codeUnits: Int) throws -> UInt32 {
                // The spec caps strings below 2^31 code units, as the top bit is the UTF-16 tag.
                guard codeUnits < Int(Self.utf16Tag) else {
                    throw CanonicalABIError(description: "string of \(codeUnits) code units is too long")
                }
                return UInt32(codeUnits)
            }
            func write(_ bytes: [UInt8], at begin: Int) throws {
                try memory.withUnsafeMutableBufferPointer(offset: UInt(begin), count: bytes.count) {
                    $0.copyBytes(from: bytes)
                }
            }
            switch options.stringEncoding {
            case .utf8:
                let bytes = Array(string.utf8)
                let length = try check(bytes.count)
                let begin = try realloc(alignment: 1, byteCount: bytes.count)
                try write(bytes, at: begin)
                return (begin, length)
            case .latin1UTF16 where string.unicodeScalars.allSatisfy({ $0.value <= 0xFF }):
                let bytes = string.unicodeScalars.map { UInt8($0.value) }
                let length = try check(bytes.count)
                let begin = try realloc(alignment: 2, byteCount: bytes.count)
                try write(bytes, at: begin)
                return (begin, length)
            case .utf16, .latin1UTF16:
                let units = Array(string.utf16)
                let length = try check(units.count)
                let begin = try realloc(alignment: 2, byteCount: 2 * units.count)
                try write(units.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }, at: begin)
                return (begin, options.stringEncoding == .utf16 ? length : length | Self.utf16Tag)
            }
        }

        // MARK: - Lift flat

        /// Reads core values one at a time, as the spec's `ValueIter`, converting a joined
        /// variant slot back to the type its case wants.
        struct FlatValues {
            var values: [Value]
            var index = 0

            mutating func next(_ want: ValueType) throws -> Value {
                guard index < values.count else {
                    throw CanonicalABIError(description: "too few core values for the lifted type")
                }
                defer { index += 1 }
                return try Self.coerce(values[index], to: want)
            }

            /// A slot holds the join of its cases' types: reinterpret or narrow it back.
            static func coerce(_ value: Value, to want: ValueType) throws -> Value {
                switch (value, want) {
                case (.i32, .i32), (.i64, .i64), (.f32, .f32), (.f64, .f64): return value
                case (.i32(let bits), .f32): return .f32(bits)
                case (.i64(let bits), .i32): return .i32(UInt32(truncatingIfNeeded: bits))
                case (.i64(let bits), .f32): return .f32(UInt32(truncatingIfNeeded: bits))
                case (.i64(let bits), .f64): return .f64(bits)
                default:
                    throw CanonicalABIError(description: "core value \(value) where \(want) was expected")
                }
            }
        }

        mutating func liftFlat(_ type: ComponentDefValType, from values: inout FlatValues) throws -> ComponentValue {
            let t = try types.despecialize(type)
            func i32() throws -> UInt32 {
                guard case .i32(let v) = try values.next(.i32) else { preconditionFailure("coerced to i32") }
                return v
            }
            func i64() throws -> UInt64 {
                guard case .i64(let v) = try values.next(.i64) else { preconditionFailure("coerced to i64") }
                return v
            }
            switch t {
            case .inlined(.primitive(let p)):
                switch p {
                case .bool: return .bool(try i32() != 0)
                // Narrow integers take the low bits, as `lift_flat_unsigned`/`lift_flat_signed`.
                case .s8: return .s8(Int8(truncatingIfNeeded: try i32()))
                case .u8: return .u8(UInt8(truncatingIfNeeded: try i32()))
                case .s16: return .s16(Int16(truncatingIfNeeded: try i32()))
                case .u16: return .u16(UInt16(truncatingIfNeeded: try i32()))
                case .s32: return .s32(Int32(bitPattern: try i32()))
                case .u32: return .u32(try i32())
                case .s64: return .s64(Int64(bitPattern: try i64()))
                case .u64: return .u64(try i64())
                case .float32:
                    guard case .f32(let bits) = try values.next(.f32) else { preconditionFailure("coerced to f32") }
                    return .float32(Float(bitPattern: bits))
                case .float64:
                    guard case .f64(let bits) = try values.next(.f64) else { preconditionFailure("coerced to f64") }
                    return .float64(Double(bitPattern: bits))
                case .char: return .char(try Self.char(try i32()))
                case .string:
                    let begin = try i32()
                    let taggedCodeUnits = try i32()
                    return .string(try loadString(begin: Int(begin), taggedCodeUnits: taggedCodeUnits))
                case .errorContext:
                    throw types.unsupported(t)
                }
            case .list(let element):
                let begin = try i32()
                let length = try i32()
                return .list(try loadList(begin: Int(begin), length: Int(length), element: types.resolve(element)))
            case .own, .borrow:
                return try liftHandle(t, try i32())
            case .record(let fields):
                return .record(try fields.map { ($0.name, try liftFlat(types.resolve($0.type), from: &values)) })
            case .tuple(let elements):
                return .tuple(try elements.map { try liftFlat(types.resolve($0), from: &values) })
            case .flags(let labels):
                let bits = try (0..<max(1, (labels.count + 31) / 32)).map { _ in try i32() }
                return Self.flags(labels, bits: bits)
            default:
                guard let cases = try types.variantCases(t) else { throw types.unsupported(t) }
                let index = Int(try i32())
                guard index < cases.count else {
                    throw CanonicalABIError(description: "discriminant \(index) names no case of \(cases.count)")
                }
                // Every payload slot is read at its joined type; the case's payload takes the
                // first ones, converted back to its own types, and the rest are other cases'.
                var payloadValues = FlatValues(values: [])
                for slot in try types.flattenVariantPayloads(cases) {
                    payloadValues.values.append(try values.next(slot))
                }
                let payload = try cases[index].map { try liftFlat($0, from: &payloadValues) }
                return try Self.variantValue(t, case: index, payload: payload)
            }
        }

        // MARK: - Lower flat

        mutating func lowerFlat(_ value: ComponentValue, as type: ComponentDefValType) throws -> [Value] {
            let t = try types.despecialize(type)
            switch (t, value) {
            case (.inlined(.primitive(.bool)), .bool(let v)): return [.i32(v ? 1 : 0)]
            case (.inlined(.primitive(.s8)), .s8(let v)): return [.i32(UInt32(bitPattern: Int32(v)))]
            case (.inlined(.primitive(.u8)), .u8(let v)): return [.i32(UInt32(v))]
            case (.inlined(.primitive(.s16)), .s16(let v)): return [.i32(UInt32(bitPattern: Int32(v)))]
            case (.inlined(.primitive(.u16)), .u16(let v)): return [.i32(UInt32(v))]
            case (.inlined(.primitive(.s32)), .s32(let v)): return [.i32(UInt32(bitPattern: v))]
            case (.inlined(.primitive(.u32)), .u32(let v)): return [.i32(v)]
            case (.inlined(.primitive(.s64)), .s64(let v)): return [.i64(UInt64(bitPattern: v))]
            case (.inlined(.primitive(.u64)), .u64(let v)): return [.i64(v)]
            case (.inlined(.primitive(.float32)), .float32(let v)): return [.f32(v.bitPattern)]
            case (.inlined(.primitive(.float64)), .float64(let v)): return [.f64(v.bitPattern)]
            case (.inlined(.primitive(.char)), .char(let v)): return [.i32(v.value)]
            case (.inlined(.primitive(.string)), .string(let v)):
                let (begin, taggedCodeUnits) = try storeString(v)
                return [.i32(UInt32(begin)), .i32(taggedCodeUnits)]
            case (.list(let element), .list(let elements)):
                let (begin, length) = try storeList(elements, element: types.resolve(element))
                return [.i32(UInt32(begin)), .i32(UInt32(length))]
            case (.own, _), (.borrow, _):
                return [.i32(try lowerHandle(value, as: t))]
            case (.record(let fields), .record(let values)):
                var flat: [Value] = []
                for (field, value) in zip(fields, try Self.recordFields(fields, values)) {
                    flat += try lowerFlat(value, as: types.resolve(field.type))
                }
                return flat
            case (.tuple(let elements), .tuple(let values)):
                guard elements.count == values.count else { throw Self.mismatch(value, t) }
                var flat: [Value] = []
                for (element, value) in zip(elements, values) {
                    flat += try lowerFlat(value, as: types.resolve(element))
                }
                return flat
            case (.flags(let labels), .flags(let set)):
                return try Self.flagBits(labels, set).map { .i32($0) }
            default:
                guard let cases = try types.variantCases(t) else { throw Self.mismatch(value, t) }
                let (index, payload) = try Self.variantCase(of: value, t)
                var payloadFlat: [Value] = []
                if let payloadType = cases[index] {
                    guard let payload else { throw Self.mismatch(value, t) }
                    payloadFlat = try lowerFlat(payload, as: payloadType)
                }
                // Widen each payload value to its slot's joined type, then zero the other slots.
                var flat: [Value] = [.i32(UInt32(index))]
                for (i, slot) in try types.flattenVariantPayloads(cases).enumerated() {
                    flat.append(i < payloadFlat.count ? Self.widen(payloadFlat[i], to: slot) : Self.zero(slot))
                }
                return flat
            }
        }

        static func widen(_ value: Value, to slot: ValueType) -> Value {
            switch (value, slot) {
            case (.f32(let bits), .i32): return .i32(bits)
            case (.i32(let v), .i64): return .i64(UInt64(v))
            case (.f32(let bits), .i64): return .i64(UInt64(bits))
            case (.f64(let bits), .i64): return .i64(bits)
            default: return value
            }
        }

        static func zero(_ type: ValueType) -> Value {
            switch type {
            case .i32: return .i32(0)
            case .i64: return .i64(0)
            case .f32: return .f32(0)
            case .f64: return .f64(0)
            case .v128, .ref: preconditionFailure("the canonical ABI flattens to numbers only")
            }
        }

        // MARK: - Value helpers

        static func char(_ value: UInt32) throws -> Unicode.Scalar {
            // Surrogates and values past U+10FFFF are no scalar values, and trap.
            guard let scalar = Unicode.Scalar(value) else {
                throw CanonicalABIError(description: "invalid `char` bit pattern: \(value)")
            }
            return scalar
        }

        static func flags(_ labels: [String], bits: [UInt32]) -> ComponentValue {
            var set = Set<String>()
            for (i, label) in labels.enumerated() where bits[i / 32] & (1 << UInt32(i % 32)) != 0 {
                set.insert(label)
            }
            return .flags(set)
        }

        static func flagBits(_ labels: [String], _ set: Set<String>) throws -> [UInt32] {
            var bits = [UInt32](repeating: 0, count: max(1, (labels.count + 31) / 32))
            for label in set {
                guard let i = labels.firstIndex(of: label) else {
                    throw CanonicalABIError(description: "flags have no label '\(label)'")
                }
                bits[i / 32] |= 1 << UInt32(i % 32)
            }
            return bits
        }

        /// The values of a record in field order, whatever order `values` lists them in.
        static func recordFields(
            _ fields: [ComponentRecordField], _ values: [(name: String, value: ComponentValue)]
        ) throws -> [ComponentValue] {
            var byName: [String: ComponentValue] = [:]
            for (name, value) in values { byName[name] = value }
            return try fields.map { field in
                guard let value = byName[field.name] else {
                    throw CanonicalABIError(description: "record has no field '\(field.name)'")
                }
                return value
            }
        }

        /// The case index and payload of a variant-like value.
        ///
        /// For `result`, a value with `error` set is the `err` case; `.tuple([])` stands for an
        /// `err` without a payload, which `.result(ok: nil, error: nil)` (the `ok` case) could not.
        static func variantCase(
            of value: ComponentValue, _ t: ComponentDefValType
        ) throws -> (index: Int, payload: ComponentValue?) {
            switch (t, value) {
            case (.variant(let cases), .variant(let name, let payload)):
                guard let index = cases.firstIndex(where: { $0.name == name }) else { throw mismatch(value, t) }
                return (index, payload)
            case (.enum(let labels), .enum(let name)):
                guard let index = labels.firstIndex(of: name) else { throw mismatch(value, t) }
                return (index, nil)
            case (.option, .option(let some)):
                return some.map { (1, $0) } ?? (0, nil)
            case (.result(_, let errorType), .result(let ok, let error)):
                if let error {
                    return (1, errorType == nil ? nil : error)
                }
                return (0, ok)
            default:
                throw mismatch(value, t)
            }
        }

        static func variantValue(
            _ t: ComponentDefValType, case index: Int, payload: ComponentValue?
        ) throws -> ComponentValue {
            switch t {
            case .variant(let cases): return .variant(caseName: cases[index].name, payload: payload)
            case .enum(let labels): return .enum(labels[index])
            case .option: return .option(index == 0 ? nil : payload)
            case .result:
                return index == 0 ? .result(ok: payload, error: nil) : .result(ok: nil, error: payload ?? .tuple([]))
            default: throw CanonicalABIError(description: "\(t) is not a variant")
            }
        }

        static func mismatch(_ value: ComponentValue, _ t: ComponentDefValType) -> CanonicalABIError {
            CanonicalABIError(description: "\(value) is not a value of \(t)")
        }
    }

    // MARK: - Function boundaries

    extension CanonicalABIContext {
        /// Lowers a call's arguments into core values for a lifted function: flat, or stored in
        /// memory behind one pointer when they flatten to more than `MAX_FLAT_PARAMS`.
        mutating func lowerArguments(_ arguments: [ComponentValue], of type: ComponentFuncType) throws -> [Value] {
            guard arguments.count == type.params.count else {
                throw CanonicalABIError(description: "expected \(type.params.count) arguments, got \(arguments.count)")
            }
            let parameterTypes = type.params.map(\.type)
            if try parameterTypes.flatMap(types.flatten).count > MAX_FLAT_PARAMS {
                let pointer = try realloc(
                    alignment: try types.fieldsAlignment(parameterTypes), byteCount: try types.fieldsSize(parameterTypes))
                try storeFields(arguments, types: parameterTypes, at: pointer)
                return [.i32(UInt32(pointer))]
            }
            var flat: [Value] = []
            for (argument, parameterType) in zip(arguments, parameterTypes) {
                flat += try lowerFlat(argument, as: parameterType)
            }
            return flat
        }

        /// Lifts a lifted function's core results: flat, or loaded through the returned pointer
        /// when they flatten to more than `MAX_FLAT_RESULTS`.
        mutating func liftResults(_ results: [Value], of type: ComponentFuncType) throws -> [ComponentValue] {
            guard let resultType = type.result else { return [] }
            if try types.flatten(resultType).count > MAX_FLAT_RESULTS {
                guard results.count == 1, case .i32(let pointer) = results[0] else {
                    throw CanonicalABIError(description: "expected an i32 pointer to the results")
                }
                try checkRange(Int(pointer), count: try types.size(resultType), alignment: try types.alignment(resultType))
                return [try load(resultType, at: Int(pointer))]
            }
            var values = FlatValues(values: results)
            return [try liftFlat(resultType, from: &values)]
        }

        /// Lifts the core arguments a guest passes to a lowered function.
        mutating func liftArguments(_ arguments: [Value], of type: ComponentFuncType) throws -> [ComponentValue] {
            let parameterTypes = type.params.map(\.type)
            if try parameterTypes.flatMap(types.flatten).count > MAX_FLAT_PARAMS {
                guard let first = arguments.first, case .i32(let pointer) = first else {
                    throw CanonicalABIError(description: "expected an i32 pointer to the arguments")
                }
                try checkRange(
                    Int(pointer), count: try types.fieldsSize(parameterTypes),
                    alignment: try types.fieldsAlignment(parameterTypes))
                return try loadFields(parameterTypes, at: Int(pointer))
            }
            var values = FlatValues(values: arguments)
            return try parameterTypes.map { try liftFlat($0, from: &values) }
        }

        /// Lowers a lowered function's results for the guest that called it: as core results, or
        /// stored through the pointer it passed last when they flatten to more than
        /// `MAX_FLAT_RESULTS`.
        mutating func lowerResults(
            _ results: [ComponentValue], of type: ComponentFuncType, arguments: [Value]
        ) throws -> [Value] {
            guard let resultType = type.result else { return [] }
            guard results.count == 1 else {
                throw CanonicalABIError(description: "expected one result, got \(results.count)")
            }
            if try types.flatten(resultType).count > MAX_FLAT_RESULTS {
                guard let last = arguments.last, case .i32(let pointer) = last else {
                    throw CanonicalABIError(description: "expected an i32 pointer for the results")
                }
                try checkRange(Int(pointer), count: try types.size(resultType), alignment: try types.alignment(resultType))
                try store(results[0], as: resultType, at: Int(pointer))
                return []
            }
            return try lowerFlat(results[0], as: resultType)
        }
    }

#endif
