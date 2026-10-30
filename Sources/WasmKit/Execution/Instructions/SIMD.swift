import WasmTypes

// The SIMD instruction handlers are generated from `Utilities/Sources/VMSpec/SIMD.swift`, one
// per operation. Each is a Swift expression over the vectors defined here, which the compiler
// lowers to the host's vector instructions.

/// A type a `v128` can be split into lanes of.
protocol V128Lane: SIMDScalar {
    /// The vector of the lanes that make up a `v128`, such as `SIMD16<UInt8>`.
    associatedtype Vector: SIMD where Vector.Scalar == Self
    /// The lane whose bytes, in little-endian order, are those of `lane` in host order.
    init(littleEndianLane lane: Self)
}

extension V128Lane where Self: FixedWidthInteger {
    @inline(__always) init(littleEndianLane lane: Self) { self.init(littleEndian: lane) }
}

extension UInt8: V128Lane { typealias Vector = SIMD16<UInt8> }
extension Int8: V128Lane { typealias Vector = SIMD16<Int8> }
extension UInt16: V128Lane { typealias Vector = SIMD8<UInt16> }
extension Int16: V128Lane { typealias Vector = SIMD8<Int16> }
extension UInt32: V128Lane { typealias Vector = SIMD4<UInt32> }
extension Int32: V128Lane { typealias Vector = SIMD4<Int32> }
extension UInt64: V128Lane { typealias Vector = SIMD2<UInt64> }
extension Int64: V128Lane { typealias Vector = SIMD2<Int64> }
extension Float: V128Lane {
    typealias Vector = SIMD4<Float>
    @inline(__always) init(littleEndianLane lane: Float) { self.init(bitPattern: UInt32(littleEndian: lane.bitPattern)) }
}
extension Double: V128Lane {
    typealias Vector = SIMD2<Double>
    @inline(__always) init(littleEndianLane lane: Double) { self.init(bitPattern: UInt64(littleEndian: lane.bitPattern)) }
}

extension V128Storage {
    /// The value as lanes of `lane`, lane 0 being its least significant bits.
    @inline(__always)
    func lanes<L: V128Lane>(_ lane: L.Type) -> L.Vector {
        #if _endian(little)
            return unsafeBitCast(self, to: L.Vector.self)
        #else
            var vector = unsafeBitCast(V128Storage(lo: lo.littleEndian, hi: hi.littleEndian), to: L.Vector.self)
            for i in vector.indices { vector[i] = L(littleEndianLane: vector[i]) }
            return vector
        #endif
    }

    @inline(__always)
    init<V: SIMD>(_ vector: V) where V.Scalar: V128Lane {
        #if _endian(little)
            self = unsafeBitCast(vector, to: V128Storage.self)
        #else
            var vector = vector
            for i in vector.indices { vector[i] = V.Scalar(littleEndianLane: vector[i]) }
            let bytes = unsafeBitCast(vector, to: V128Storage.self)
            self.init(lo: UInt64(littleEndian: bytes.lo), hi: UInt64(littleEndian: bytes.hi))
        #endif
    }
}

extension Sp {
    /// The address of the slot pair a `v128` operand occupies.
    ///
    /// Both halves are addressed off one base pointer so the compiler can still
    /// merge them into a single 128-bit load or store (`ldr q`/`str q` on
    /// arm64); forming the second address by re-adding a byte offset to `sp`
    /// costs an extra add and a sign-extension and blocks the merge.
    @inline(__always)
    private func v128Slots(at reg: VReg) -> UnsafeMutablePointer<StackSlot> {
        UnsafeMutableRawPointer(self)
            .advanced(by: Int(reg.byteOffset))
            .assumingMemoryBound(to: StackSlot.self)
    }

    @inline(__always)
    func loadV128(at reg: VReg) -> V128Storage {
        let slots = v128Slots(at: reg)
        return V128Storage(lo: slots[0], hi: slots[1])
    }

    @inline(__always)
    func storeV128(_ value: V128Storage, at reg: VReg) {
        let slots = v128Slots(at: reg)
        slots[0] = value.lo
        slots[1] = value.hi
    }

    @inline(__always)
    func simd<A: V128Lane, R: V128Lane>(
        _ immediate: Instruction.SimdUnaryOperand, _: A.Type, _: R.Type, _ body: (A.Vector) -> R.Vector
    ) {
        storeV128(V128Storage(body(loadV128(at: immediate.input).lanes(A.self))), at: immediate.result)
    }

    @inline(__always)
    func simd<A: V128Lane>(_ immediate: Instruction.SimdUnaryOperand, _: A.Type, _ body: (A.Vector) -> A.Vector) {
        simd(immediate, A.self, A.self, body)
    }

    @inline(__always)
    func simd<A: V128Lane, R: V128Lane>(
        _ immediate: Instruction.SimdBinaryOperand, _: A.Type, _: R.Type, _ body: (A.Vector, A.Vector) -> R.Vector
    ) {
        let lhs = loadV128(at: immediate.lhs).lanes(A.self)
        let rhs = loadV128(at: immediate.rhs).lanes(A.self)
        storeV128(V128Storage(body(lhs, rhs)), at: immediate.result)
    }

    @inline(__always)
    func simd<A: V128Lane>(_ immediate: Instruction.SimdBinaryOperand, _: A.Type, _ body: (A.Vector, A.Vector) -> A.Vector) {
        simd(immediate, A.self, A.self, body)
    }

    @inline(__always)
    func simd<A: V128Lane, R: V128Lane>(
        _ immediate: Instruction.SimdTernaryOperand, _: A.Type, _: R.Type, _ body: (A.Vector, A.Vector, A.Vector) -> R.Vector
    ) {
        let a = loadV128(at: immediate.a).lanes(A.self)
        let b = loadV128(at: immediate.b).lanes(A.self)
        let c = loadV128(at: immediate.c).lanes(A.self)
        storeV128(V128Storage(body(a, b, c)), at: immediate.result)
    }

    @inline(__always)
    func simd<A: V128Lane>(
        _ immediate: Instruction.SimdTernaryOperand, _: A.Type, _ body: (A.Vector, A.Vector, A.Vector) -> A.Vector
    ) {
        simd(immediate, A.self, A.self, body)
    }

    /// A shift of the lanes of `lhs` by the `i32` in `rhs`, given to `body` as a lane value.
    /// The masking shifts `&<<` and `&>>` take it modulo the lane width, as WebAssembly does.
    @inline(__always)
    func simdShift<A: V128Lane & FixedWidthInteger>(
        _ immediate: Instruction.SimdBinaryOperand, _: A.Type, _ body: (A.Vector, A) -> A.Vector
    ) {
        let count = A(truncatingIfNeeded: self[immediate.rhs].i32)
        storeV128(V128Storage(body(loadV128(at: immediate.lhs).lanes(A.self), count)), at: immediate.result)
    }

    @inline(__always)
    func simdToI32<A: V128Lane>(_ immediate: Instruction.SimdUnaryOperand, _: A.Type, _ body: (A.Vector) -> UInt32) {
        self[immediate.result] = .i32(body(loadV128(at: immediate.input).lanes(A.self)))
    }

    @inline(__always)
    func simdFromScalar<V: SIMD>(_ immediate: Instruction.SimdUnaryOperand, _ body: (UntypedValue) -> V) where V.Scalar: V128Lane {
        storeV128(V128Storage(body(self[immediate.input])), at: immediate.result)
    }

    @inline(__always)
    func simdExtractLane<A: V128Lane>(_ immediate: Instruction.SimdExtractLaneOperand, _: A.Type, _ body: (A) -> UntypedValue) {
        self[immediate.result] = body(loadV128(at: immediate.vector).lanes(A.self)[Int(immediate.lane)])
    }

    @inline(__always)
    func simdReplaceLane<A: V128Lane>(_ immediate: Instruction.SimdReplaceLaneOperand, _: A.Type, _ body: (UntypedValue) -> A) {
        var lanes = loadV128(at: immediate.vector).lanes(A.self)
        lanes[Int(immediate.lane)] = body(self[immediate.scalar])
        storeV128(V128Storage(lanes), at: immediate.result)
    }
}

// MARK: - Memory

extension Execution {
    /// The address of an access of `length` bytes at `pointer` plus `offset`, trapping when it
    /// is out of bounds, or when the sum overflows: a 64-bit memory's index is arbitrary, and
    /// the wrapped sum could pass the bounds check at a low address.
    @inline(__always)
    private func simdAddress(_ pointer: UntypedValue, offset: UInt64, length: UInt64, ms: Ms) throws -> Int {
        let (address, overflow) = pointer.asAddressOffset().addingReportingOverflow(offset)
        let (end, endOverflow) = address.addingReportingOverflow(length)
        if _fastPath(!overflow && !endOverflow && end <= UInt64(ms)) { return Int(address) }
        try throwOutOfBoundsMemoryAccess()
    }

    @inline(__always)
    func simdLoad<T: FixedWidthInteger>(
        sp: Sp, md: Md, ms: Ms, _ immediate: Instruction.LoadOperand, _: T.Type, _ body: (T) -> V128Storage
    ) throws {
        let address = try simdAddress(sp[immediate.pointer], offset: immediate.offset, length: UInt64(MemoryLayout<T>.size), ms: ms)
        let value = T(littleEndian: md.unsafelyUnwrapped.loadUnaligned(fromByteOffset: address, as: T.self))
        sp.storeV128(body(value), at: immediate.result)
    }

    /// `v128.load`.
    @inline(__always)
    func simdLoad(sp: Sp, md: Md, ms: Ms, _ immediate: Instruction.LoadOperand) throws {
        let address = try simdAddress(sp[immediate.pointer], offset: immediate.offset, length: 16, ms: ms)
        let memory = md.unsafelyUnwrapped
        let lo = UInt64(littleEndian: memory.loadUnaligned(fromByteOffset: address, as: UInt64.self))
        let hi = UInt64(littleEndian: memory.loadUnaligned(fromByteOffset: address + 8, as: UInt64.self))
        sp.storeV128(V128Storage(lo: lo, hi: hi), at: immediate.result)
    }

    /// `v128.store`.
    @inline(__always)
    func simdStore(sp: Sp, md: Md, ms: Ms, _ immediate: Instruction.StoreOperand) throws {
        let address = try simdAddress(sp[immediate.pointer], offset: immediate.offset, length: 16, ms: ms)
        let value = sp.loadV128(at: immediate.value)
        let memory = md.unsafelyUnwrapped
        memory.storeBytes(of: value.lo.littleEndian, toByteOffset: address, as: UInt64.self)
        memory.storeBytes(of: value.hi.littleEndian, toByteOffset: address + 8, as: UInt64.self)
    }

    @inline(__always)
    func simdLoadLane<L: V128Lane & FixedWidthInteger>(
        sp: Sp, md: Md, ms: Ms, _ immediate: Instruction.SimdLoadLaneOperand, _: L.Type
    ) throws {
        let address = try simdAddress(sp[immediate.pointer], offset: immediate.offset, length: UInt64(MemoryLayout<L>.size), ms: ms)
        var lanes = sp.loadV128(at: immediate.vector).lanes(L.self)
        lanes[Int(immediate.lane)] = L(littleEndian: md.unsafelyUnwrapped.loadUnaligned(fromByteOffset: address, as: L.self))
        sp.storeV128(V128Storage(lanes), at: immediate.result)
    }

    @inline(__always)
    func simdStoreLane<L: V128Lane & FixedWidthInteger>(
        sp: Sp, md: Md, ms: Ms, _ immediate: Instruction.SimdStoreLaneOperand, _: L.Type
    ) throws {
        let address = try simdAddress(sp[immediate.pointer], offset: immediate.offset, length: UInt64(MemoryLayout<L>.size), ms: ms)
        let lane = sp.loadV128(at: immediate.vector).lanes(L.self)[Int(immediate.lane)]
        md.unsafelyUnwrapped.storeBytes(of: lane.littleEndian, toByteOffset: address, as: L.self)
    }
}

// MARK: - Instructions with their own immediates

extension Execution {
    mutating func v128Const(sp: Sp, immediate: Instruction.V128ConstOperand) {
        sp.storeV128(V128Storage(lo: immediate.lo, hi: immediate.hi), at: immediate.result)
    }

    mutating func i8x16Shuffle(sp: Sp, immediate: Instruction.I8x16ShuffleOperand) {
        let lhs = sp.loadV128(at: immediate.lhs).lanes(UInt8.self)
        let rhs = sp.loadV128(at: immediate.rhs).lanes(UInt8.self)
        let indices: SIMD16<UInt8> = [
            immediate.lane0, immediate.lane1, immediate.lane2, immediate.lane3,
            immediate.lane4, immediate.lane5, immediate.lane6, immediate.lane7,
            immediate.lane8, immediate.lane9, immediate.lane10, immediate.lane11,
            immediate.lane12, immediate.lane13, immediate.lane14, immediate.lane15,
        ]
        var result = SIMD16<UInt8>()
        for i in 0..<16 {
            let index = Int(indices[i])
            result[i] = index < 16 ? lhs[index] : rhs[index - 16]
        }
        sp.storeV128(V128Storage(result), at: immediate.result)
    }
}

// MARK: - Operations without a Swift operator

extension SIMD where Scalar: FixedWidthInteger {
    /// All bits set in the lanes where `mask` is true, and clear elsewhere.
    @inline(__always)
    static func allOnes(where mask: SIMDMask<MaskStorage>) -> Self {
        Self().replacing(with: ~Scalar.zero, where: mask)
    }
}

@inline(__always)
func lanewise<A: SIMD, R: SIMD>(_ a: A, _ transform: (A.Scalar) -> R.Scalar) -> R {
    var result = R()
    for i in a.indices { result[i] = transform(a[i]) }
    return result
}

@inline(__always)
func lanewise<V: SIMD>(_ a: V, _ b: V, _ transform: (V.Scalar, V.Scalar) -> V.Scalar) -> V {
    var result = V()
    for i in a.indices { result[i] = transform(a[i], b[i]) }
    return result
}

@inline(__always)
func bitselect(_ a: SIMD2<UInt64>, _ b: SIMD2<UInt64>, _ mask: SIMD2<UInt64>) -> SIMD2<UInt64> {
    (a & mask) | (b & ~mask)
}

/// The lanes of `a` at the indices in `indices`, or 0 for an index past the last lane.
@inline(__always)
func swizzle(_ a: SIMD16<UInt8>, _ indices: SIMD16<UInt8>) -> SIMD16<UInt8> {
    var result = SIMD16<UInt8>()
    for i in 0..<16 {
        let index = Int(indices[i])
        result[i] = index < 16 ? a[index] : 0
    }
    return result
}

/// The sign bit of each lane, lane 0 in bit 0.
@inline(__always)
func bitmask<V: SIMD>(_ v: V) -> UInt32 where V.Scalar: FixedWidthInteger & SignedInteger {
    var mask: UInt32 = 0
    for i in v.indices where v[i] < 0 { mask |= 1 << UInt32(i) }
    return mask
}

@inline(__always)
func saturatingAdd<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FixedWidthInteger {
    lanewise(a, b) { a, b in
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b < 0 ? .min : .max) : sum
    }
}

@inline(__always)
func saturatingSubtract<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FixedWidthInteger {
    lanewise(a, b) { a, b in
        let (difference, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? (b > 0 ? .min : .max) : difference
    }
}

/// `(a + b + 1) / 2` without overflowing the lane.
@inline(__always)
func roundingAverage<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FixedWidthInteger & UnsignedInteger {
    (a | b) &- ((a ^ b) &>> 1)
}

/// `(a * b + 0x4000) >> 15`, saturated.
@inline(__always)
func q15MulRoundSaturating(_ a: SIMD8<Int16>, _ b: SIMD8<Int16>) -> SIMD8<Int16> {
    let product = SIMD8<Int32>(truncatingIfNeeded: a) &* SIMD8<Int32>(truncatingIfNeeded: b)
    let rounded = (product &+ 0x4000) &>> 15
    return SIMD8<Int16>(truncatingIfNeeded: rounded.clamped(lowerBound: .init(repeating: -0x8000), upperBound: .init(repeating: 0x7FFF)))
}

/// The lanes of `a` then those of `b`, each saturated to `R`.
@inline(__always)
func narrow<R: FixedWidthInteger & SIMDScalar>(_ a: SIMD8<Int16>, _ b: SIMD8<Int16>) -> SIMD16<R> {
    let lower = SIMD8<Int16>(repeating: Int16(R.min))
    let upper = SIMD8<Int16>(repeating: Int16(R.max))
    return SIMD16(
        lowHalf: SIMD8(truncatingIfNeeded: a.clamped(lowerBound: lower, upperBound: upper)),
        highHalf: SIMD8(truncatingIfNeeded: b.clamped(lowerBound: lower, upperBound: upper)))
}

@inline(__always)
func narrow<R: FixedWidthInteger & SIMDScalar>(_ a: SIMD4<Int32>, _ b: SIMD4<Int32>) -> SIMD8<R> {
    let lower = SIMD4<Int32>(repeating: Int32(R.min))
    let upper = SIMD4<Int32>(repeating: Int32(R.max))
    return SIMD8(
        lowHalf: SIMD4(truncatingIfNeeded: a.clamped(lowerBound: lower, upperBound: upper)),
        highHalf: SIMD4(truncatingIfNeeded: b.clamped(lowerBound: lower, upperBound: upper)))
}

/// `a * b + c`, with the product rounded before the sum.
@inline(__always)
func unfusedMultiplyAdd<V: SIMD>(_ a: V, _ b: V, _ c: V) -> V where V.Scalar: FloatingPoint {
    let product = a * b
    return product + c
}

/// The products of adjacent pairs of lanes, summed and saturated to `i16`.
@inline(__always)
func relaxedDot(_ a: SIMD16<Int8>, _ b: SIMD16<Int8>) -> SIMD8<Int16> {
    let even = SIMD8<Int32>(truncatingIfNeeded: a.evenHalf) &* SIMD8<Int32>(truncatingIfNeeded: b.evenHalf)
    let odd = SIMD8<Int32>(truncatingIfNeeded: a.oddHalf) &* SIMD8<Int32>(truncatingIfNeeded: b.oddHalf)
    let sum = even &+ odd
    return SIMD8<Int16>(truncatingIfNeeded: sum.clamped(lowerBound: .init(repeating: -0x8000), upperBound: .init(repeating: 0x7FFF)))
}

/// ``relaxedDot(_:_:)``, its adjacent pairs summed to `i32`s, plus the `i32` lanes of `c`.
@inline(__always)
func relaxedDotAdd(_ a: SIMD16<Int8>, _ b: SIMD16<Int8>, _ c: SIMD16<Int8>) -> SIMD4<Int32> {
    let dot = SIMD8<Int32>(truncatingIfNeeded: relaxedDot(a, b))
    return dot.evenHalf &+ dot.oddHalf &+ V128Storage(c).lanes(Int32.self)
}
