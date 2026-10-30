import WasmTypes

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
}

/// Up to 16 lanes of a `v128`, stored inline.
///
/// The SIMD handlers build several of these per instruction; as `Array`s each was a heap
/// allocation, which dominated the cost of most SIMD instructions.
struct LaneBuffer: RandomAccessCollection, MutableCollection, ExpressibleByArrayLiteral {
    private var storage: (
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private(set) var count: Int = 0

    @inline(__always) init() {}

    @inline(__always) init(repeating value: UInt64, count: Int) {
        for _ in 0..<count { append(value) }
    }

    @inline(__always) init(arrayLiteral elements: UInt64...) {
        for element in elements { append(element) }
    }

    @inline(__always) var startIndex: Int { 0 }
    @inline(__always) var endIndex: Int { count }

    @inline(__always) subscript(index: Int) -> UInt64 {
        get {
            precondition(index >= 0 && index < count, "lane index out of range")
            return withUnsafeBytes(of: storage) { $0.load(fromByteOffset: index * 8, as: UInt64.self) }
        }
        set {
            precondition(index >= 0 && index < count, "lane index out of range")
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: newValue, toByteOffset: index * 8, as: UInt64.self) }
        }
    }

    @inline(__always) mutating func append(_ value: UInt64) {
        precondition(count < 16, "a v128 has at most 16 lanes")
        count += 1
        self[count - 1] = value
    }

    /// Kept for the call sites written against `Array`; the storage is always 16 lanes.
    @inline(__always) mutating func reserveCapacity(_ capacity: Int) {}

    /// The lanes transformed by `transform`, without the `Array` that `Sequence.map` returns.
    @inline(__always) func map(_ transform: (UInt64) throws -> UInt64) rethrows -> LaneBuffer {
        var result = LaneBuffer()
        for lane in self { result.append(try transform(lane)) }
        return result
    }

    @inline(__always) static func + (lhs: LaneBuffer, rhs: LaneBuffer) -> LaneBuffer {
        var result = lhs
        for lane in rhs { result.append(lane) }
        return result
    }
}

struct V128Lanes {
    @inline(__always)
    static func laneMask(widthBits: Int) -> UInt64 {
        precondition(widthBits == 8 || widthBits == 16 || widthBits == 32 || widthBits == 64)
        if widthBits == 64 { return UInt64.max }
        return (UInt64(1) << UInt64(widthBits)) &- 1
    }

    @inline(__always)
    static func boolMask(widthBits: Int, truth: Bool) -> UInt64 {
        truth ? laneMask(widthBits: widthBits) : 0
    }

    @inline(__always)
    static func extract(_ v: V128Storage, widthBits: Int, laneCount: Int) -> LaneBuffer {
        let mask = laneMask(widthBits: widthBits)
        var lanes = LaneBuffer()
        lanes.reserveCapacity(laneCount)
        for i in 0..<laneCount {
            let bitOffset = i * widthBits
            let value: UInt64
            if bitOffset < 64 {
                value = (v.lo >> UInt64(bitOffset)) & mask
            } else {
                value = (v.hi >> UInt64(bitOffset - 64)) & mask
            }
            lanes.append(value)
        }
        return lanes
    }

    @inline(__always)
    static func pack(_ lanes: LaneBuffer, widthBits: Int, laneCount: Int) -> V128Storage {
        precondition(lanes.count == laneCount)
        let mask = laneMask(widthBits: widthBits)
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        for i in 0..<laneCount {
            let bitOffset = i * widthBits
            let v = lanes[i] & mask
            if bitOffset < 64 {
                lo |= v << UInt64(bitOffset)
            } else {
                hi |= v << UInt64(bitOffset - 64)
            }
        }
        return V128Storage(lo: lo, hi: hi)
    }

    @inline(__always)
    static func map(
        _ v: V128Storage,
        widthBits: Int,
        laneCount: Int,
        _ f: (UInt64) throws -> UInt64
    ) rethrows -> V128Storage {
        let lanes = extract(v, widthBits: widthBits, laneCount: laneCount)
        let out = try lanes.map(f)
        return pack(out, widthBits: widthBits, laneCount: laneCount)
    }

    @inline(__always)
    static func zip(
        _ a: V128Storage,
        _ b: V128Storage,
        widthBits: Int,
        laneCount: Int,
        _ f: (UInt64, UInt64) throws -> UInt64
    ) rethrows -> V128Storage {
        let la = extract(a, widthBits: widthBits, laneCount: laneCount)
        let lb = extract(b, widthBits: widthBits, laneCount: laneCount)
        var out = LaneBuffer()
        out.reserveCapacity(laneCount)
        for i in 0..<laneCount {
            out.append(try f(la[i], lb[i]))
        }
        return pack(out, widthBits: widthBits, laneCount: laneCount)
    }

    @inline(__always)
    static func zip3(
        _ a: V128Storage,
        _ b: V128Storage,
        _ c: V128Storage,
        widthBits: Int,
        laneCount: Int,
        _ f: (UInt64, UInt64, UInt64) throws -> UInt64
    ) rethrows -> V128Storage {
        let la = extract(a, widthBits: widthBits, laneCount: laneCount)
        let lb = extract(b, widthBits: widthBits, laneCount: laneCount)
        let lc = extract(c, widthBits: widthBits, laneCount: laneCount)
        var out = LaneBuffer()
        out.reserveCapacity(laneCount)
        for i in 0..<laneCount {
            out.append(try f(la[i], lb[i], lc[i]))
        }
        return pack(out, widthBits: widthBits, laneCount: laneCount)
    }
}
