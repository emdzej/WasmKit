import WasmTypes

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#numeric-instructions>
extension Execution {
    mutating func v128Const(sp: Sp, immediate: Instruction.V128ConstOperand) {
        sp.storeV128(V128Storage(lo: immediate.lo, hi: immediate.hi), at: immediate.result)
    }

    mutating func i8x16Shuffle(sp: Sp, immediate: Instruction.I8x16ShuffleOperand) {
        let lhs = sp.loadV128(at: immediate.lhs)
        let rhs = sp.loadV128(at: immediate.rhs)
        let lanes: LaneBuffer = [
            UInt64(immediate.lane0), UInt64(immediate.lane1), UInt64(immediate.lane2), UInt64(immediate.lane3),
            UInt64(immediate.lane4), UInt64(immediate.lane5), UInt64(immediate.lane6), UInt64(immediate.lane7),
            UInt64(immediate.lane8), UInt64(immediate.lane9), UInt64(immediate.lane10), UInt64(immediate.lane11),
            UInt64(immediate.lane12), UInt64(immediate.lane13), UInt64(immediate.lane14), UInt64(immediate.lane15),
        ]

        var out = LaneBuffer()
        out.reserveCapacity(16)
        let lhsBytes = V128Lanes.extract(lhs, widthBits: 8, laneCount: 16)
        let rhsBytes = V128Lanes.extract(rhs, widthBits: 8, laneCount: 16)
        for i in 0..<16 {
            let lane = Int(lanes[i])
            let v = lane < 16 ? lhsBytes[lane] : rhsBytes[lane - 16]
            out.append(v)
        }
        sp.storeV128(V128Lanes.pack(out, widthBits: 8, laneCount: 16), at: immediate.result)
    }

    mutating func simd(sp: Sp, md: Md, ms: Ms, immediate: Instruction.SimdOperand) throws {
        guard let opcode = SIMDOpcode(rawValue: immediate.opcode) else {
            preconditionFailure("Unknown SIMD opcode: \(immediate.opcode)")
        }

        if try simdExecuteMemoryAndLane(opcode: opcode, sp: sp, md: md, ms: ms, immediate: immediate) {
            return
        }
        if try simdExecuteNumeric(opcode: opcode, sp: sp, immediate: immediate) {
            return
        }

        preconditionFailure("SIMD opcode not implemented: \(opcode)")
    }
}
