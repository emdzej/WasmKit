/// The SIMD instructions: one per WebAssembly SIMD operation.
///
/// Each handler works on the operands as Swift SIMD vectors (`SIMD16<UInt8>`, `SIMD4<Float>`,
/// ...), which the compiler lowers to the host's vector instructions. The bodies are Swift
/// expressions over the helpers in `Sources/WasmKit/Execution/Instructions/SIMD.swift`: a
/// lane type such as `UInt8` selects the vector type `UInt8.Vector`, which is `SIMD16<UInt8>`.
///
/// Every name is also a case of `SIMDOpcode`, which the translator maps WebAssembly
/// instructions to, so the generated `Instruction.simd(_:...)` constructors can switch on it.

extension VMGen.ImmediateLayout {
    static let simdUnary = Self(name: "SimdUnaryOperand") {
        $0.field(name: "input", type: .VReg)
        $0.field(name: "result", type: .VReg)
    }

    static let simdBinary = Self(name: "SimdBinaryOperand") {
        $0.field(name: "lhs", type: .VReg)
        $0.field(name: "rhs", type: .VReg)
        $0.field(name: "result", type: .VReg)
    }

    static let simdTernary = Self(name: "SimdTernaryOperand") {
        $0.field(name: "a", type: .VReg)
        $0.field(name: "b", type: .VReg)
        $0.field(name: "c", type: .VReg)
        $0.field(name: "result", type: .VReg)
    }

    static let simdExtractLane = Self(name: "SimdExtractLaneOperand") {
        $0.field(name: "vector", type: .VReg)
        $0.field(name: "result", type: .VReg)
        $0.field(name: "lane", type: .UInt8)
    }

    static let simdReplaceLane = Self(name: "SimdReplaceLaneOperand") {
        $0.field(name: "vector", type: .VReg)
        $0.field(name: "scalar", type: .VReg)
        $0.field(name: "result", type: .VReg)
        $0.field(name: "lane", type: .UInt8)
    }

    static let simdLoadLane = Self(name: "SimdLoadLaneOperand") {
        $0.field(name: "offset", type: .UInt64)
        $0.field(name: "pointer", type: .VReg)
        $0.field(name: "vector", type: .VReg)
        $0.field(name: "result", type: .VReg)
        $0.field(name: "lane", type: .UInt8)
    }

    static let simdStoreLane = Self(name: "SimdStoreLaneOperand") {
        $0.field(name: "offset", type: .UInt64)
        $0.field(name: "pointer", type: .VReg)
        $0.field(name: "vector", type: .VReg)
        $0.field(name: "lane", type: .UInt8)
    }
}

extension VMGen {
    /// The operands a SIMD instruction takes, which is also the `Instruction.simd(_:...)`
    /// constructor the translator builds it with.
    enum SIMDShape: CaseIterable {
        /// A `v128` or a scalar in, a `v128` or a scalar out.
        case unary
        /// Two operands in, one out. A shift's `rhs` is an `i32`.
        case binary
        /// Three `v128`s in, one out.
        case ternary
        case extractLane
        case replaceLane
        case load
        case store
        case loadLane
        case storeLane

        var layout: ImmediateLayout {
            switch self {
            case .unary: .simdUnary
            case .binary: .simdBinary
            case .ternary: .simdTernary
            case .extractLane: .simdExtractLane
            case .replaceLane: .simdReplaceLane
            case .load: .load
            case .store: .store
            case .loadLane: .simdLoadLane
            case .storeLane: .simdStoreLane
            }
        }

        /// The label of the operand in the generated `Instruction.simd(_:...)` constructor.
        var constructorLabel: String {
            switch self {
            case .unary: "unary"
            case .binary: "binary"
            case .ternary: "ternary"
            case .extractLane: "extractLane"
            case .replaceLane: "replaceLane"
            case .load: "load"
            case .store: "store"
            case .loadLane: "loadLane"
            case .storeLane: "storeLane"
            }
        }

        var accessesMemory: Bool {
            switch self {
            case .load, .store, .loadLane, .storeLane: true
            default: false
            }
        }
    }

    struct SIMDOp {
        let name: String
        let shape: SIMDShape
        /// The handler body.
        let implementation: String

        var instruction: Instruction {
            Instruction(
                name: name, documentation: "WebAssembly SIMD instruction",
                mayThrow: shape.accessesMemory,
                useCurrentMemory: shape.accessesMemory ? .read : .none,
                immediateLayout: shape.layout)
        }
    }

    /// `body` maps the operand's lanes, as `lane.Vector`, to the result's, as `result.Vector`.
    private static func unary(_ name: String, _ lane: String, to result: String? = nil, _ body: String) -> SIMDOp {
        let types = result.map { "\(lane).self, \($0).self" } ?? "\(lane).self"
        return SIMDOp(name: name, shape: .unary, implementation: "sp.pointee.simd(immediate, \(types)) { \(body) }")
    }

    private static func binary(_ name: String, _ lane: String, to result: String? = nil, _ body: String) -> SIMDOp {
        let types = result.map { "\(lane).self, \($0).self" } ?? "\(lane).self"
        return SIMDOp(name: name, shape: .binary, implementation: "sp.pointee.simd(immediate, \(types)) { \(body) }")
    }

    private static func ternary(_ name: String, _ lane: String, to result: String? = nil, _ body: String) -> SIMDOp {
        let types = result.map { "\(lane).self, \($0).self" } ?? "\(lane).self"
        return SIMDOp(name: name, shape: .ternary, implementation: "sp.pointee.simd(immediate, \(types)) { \(body) }")
    }

    /// A shift by an `i32`, `body` given the lanes and the count as a lane value.
    private static func shift(_ name: String, _ lane: String, _ body: String) -> SIMDOp {
        SIMDOp(name: name, shape: .binary, implementation: "sp.pointee.simdShift(immediate, \(lane).self) { \(body) }")
    }

    /// An operation from a `v128` to an `i32`.
    private static func test(_ name: String, _ lane: String, _ body: String) -> SIMDOp {
        SIMDOp(name: name, shape: .unary, implementation: "sp.pointee.simdToI32(immediate, \(lane).self) { \(body) }")
    }

    /// An operation from a scalar, as `UntypedValue`, to a `v128`.
    private static func splat(_ name: String, _ body: String) -> SIMDOp {
        SIMDOp(name: name, shape: .unary, implementation: "sp.pointee.simdFromScalar(immediate) { \(body) }")
    }

    /// `body` maps the lane to the result, an `UntypedValue`.
    private static func extractLane(_ name: String, _ lane: String, _ body: String) -> SIMDOp {
        SIMDOp(name: name, shape: .extractLane, implementation: "sp.pointee.simdExtractLane(immediate, \(lane).self) { \(body) }")
    }

    /// `body` maps the scalar, an `UntypedValue`, to the lane.
    private static func replaceLane(_ name: String, _ lane: String, _ body: String) -> SIMDOp {
        SIMDOp(name: name, shape: .replaceLane, implementation: "sp.pointee.simdReplaceLane(immediate, \(lane).self) { \(body) }")
    }

    /// `body` maps the `scalar` read from memory to the result's `V128Storage`.
    private static func load(_ name: String, _ scalar: String, _ body: String) -> SIMDOp {
        SIMDOp(
            name: name, shape: .load,
            implementation: "try simdLoad(sp: sp.pointee, md: md.pointee, ms: ms.pointee, immediate, \(scalar).self) { \(body) }")
    }

    static let simdOps: [SIMDOp] = {
        var ops: [SIMDOp] = [
            SIMDOp(name: "v128Load", shape: .load, implementation: "try simdLoad(sp: sp.pointee, md: md.pointee, ms: ms.pointee, immediate)"),
            load("v128Load8X8S", "UInt64", "V128Storage(Int16.Vector(truncatingIfNeeded: V128Storage(lo: $0, hi: 0).lanes(Int8.self).lowHalf))"),
            load("v128Load8X8U", "UInt64", "V128Storage(UInt16.Vector(truncatingIfNeeded: V128Storage(lo: $0, hi: 0).lanes(UInt8.self).lowHalf))"),
            load("v128Load16X4S", "UInt64", "V128Storage(Int32.Vector(truncatingIfNeeded: V128Storage(lo: $0, hi: 0).lanes(Int16.self).lowHalf))"),
            load("v128Load16X4U", "UInt64", "V128Storage(UInt32.Vector(truncatingIfNeeded: V128Storage(lo: $0, hi: 0).lanes(UInt16.self).lowHalf))"),
            load("v128Load32X2S", "UInt64", "V128Storage(Int64.Vector(truncatingIfNeeded: V128Storage(lo: $0, hi: 0).lanes(Int32.self).lowHalf))"),
            load("v128Load32X2U", "UInt64", "V128Storage(UInt64.Vector(truncatingIfNeeded: V128Storage(lo: $0, hi: 0).lanes(UInt32.self).lowHalf))"),
            load("v128Load8Splat", "UInt8", "V128Storage(UInt8.Vector(repeating: $0))"),
            load("v128Load16Splat", "UInt16", "V128Storage(UInt16.Vector(repeating: $0))"),
            load("v128Load32Splat", "UInt32", "V128Storage(UInt32.Vector(repeating: $0))"),
            load("v128Load64Splat", "UInt64", "V128Storage(lo: $0, hi: $0)"),
            load("v128Load32Zero", "UInt32", "V128Storage(lo: UInt64($0), hi: 0)"),
            load("v128Load64Zero", "UInt64", "V128Storage(lo: $0, hi: 0)"),
            SIMDOp(name: "v128Store", shape: .store, implementation: "try simdStore(sp: sp.pointee, md: md.pointee, ms: ms.pointee, immediate)"),
        ]
        for lane in ["UInt8", "UInt16", "UInt32", "UInt64"] {
            let bits = lane.dropFirst(4)
            ops.append(
                SIMDOp(
                    name: "v128Load\(bits)Lane", shape: .loadLane,
                    implementation: "try simdLoadLane(sp: sp.pointee, md: md.pointee, ms: ms.pointee, immediate, \(lane).self)"))
        }
        for lane in ["UInt8", "UInt16", "UInt32", "UInt64"] {
            let bits = lane.dropFirst(4)
            ops.append(
                SIMDOp(
                    name: "v128Store\(bits)Lane", shape: .storeLane,
                    implementation: "try simdStoreLane(sp: sp.pointee, md: md.pointee, ms: ms.pointee, immediate, \(lane).self)"))
        }

        ops += [
            extractLane("i8x16ExtractLaneS", "Int8", ".i32(UInt32(bitPattern: Int32($0)))"),
            extractLane("i8x16ExtractLaneU", "UInt8", ".i32(UInt32($0))"),
            replaceLane("i8x16ReplaceLane", "UInt8", "UInt8(truncatingIfNeeded: $0.i32)"),
            extractLane("i16x8ExtractLaneS", "Int16", ".i32(UInt32(bitPattern: Int32($0)))"),
            extractLane("i16x8ExtractLaneU", "UInt16", ".i32(UInt32($0))"),
            replaceLane("i16x8ReplaceLane", "UInt16", "UInt16(truncatingIfNeeded: $0.i32)"),
            extractLane("i32x4ExtractLane", "UInt32", ".i32($0)"),
            replaceLane("i32x4ReplaceLane", "UInt32", "$0.i32"),
            extractLane("i64x2ExtractLane", "UInt64", ".i64($0)"),
            replaceLane("i64x2ReplaceLane", "UInt64", "$0.i64"),
            // Float lanes move as bits, so that a NaN's payload is kept.
            extractLane("f32x4ExtractLane", "UInt32", ".rawF32($0)"),
            replaceLane("f32x4ReplaceLane", "UInt32", "$0.rawF32"),
            extractLane("f64x2ExtractLane", "UInt64", ".rawF64($0)"),
            replaceLane("f64x2ReplaceLane", "UInt64", "$0.rawF64"),

            binary("i8x16Swizzle", "UInt8", "swizzle($0, $1)"),
            splat("i8x16Splat", "UInt8.Vector(repeating: UInt8(truncatingIfNeeded: $0.i32))"),
            splat("i16x8Splat", "UInt16.Vector(repeating: UInt16(truncatingIfNeeded: $0.i32))"),
            splat("i32x4Splat", "UInt32.Vector(repeating: $0.i32)"),
            splat("i64x2Splat", "UInt64.Vector(repeating: $0.i64)"),
            splat("f32x4Splat", "UInt32.Vector(repeating: $0.rawF32)"),
            splat("f64x2Splat", "UInt64.Vector(repeating: $0.rawF64)"),
        ]

        // Comparisons, which set a lane to all ones where they hold.
        let integerComparisons = [("Eq", ".==", ""), ("Ne", ".!=", ""), ("Lt", ".<", "SU"), ("Gt", ".>", "SU"), ("Le", ".<=", "SU"), ("Ge", ".>=", "SU")]
        for (shape, width) in [("i8x16", "8"), ("i16x8", "16"), ("i32x4", "32"), ("i64x2", "64")] {
            for (name, op, signedness) in integerComparisons {
                if signedness.isEmpty {
                    ops.append(binary("\(shape)\(name)", "UInt\(width)", ".allOnes(where: $0 \(op) $1)"))
                    continue
                }
                ops.append(binary("\(shape)\(name)S", "Int\(width)", ".allOnes(where: $0 \(op) $1)"))
                // i64x2 has only signed comparisons.
                if width != "64" {
                    ops.append(binary("\(shape)\(name)U", "UInt\(width)", ".allOnes(where: $0 \(op) $1)"))
                }
            }
        }
        for (shape, lane, mask) in [("f32x4", "Float", "Int32"), ("f64x2", "Double", "Int64")] {
            for (name, op) in [("Eq", ".=="), ("Ne", ".!="), ("Lt", ".<"), ("Gt", ".>"), ("Le", ".<="), ("Ge", ".>=")] {
                ops.append(binary("\(shape)\(name)", lane, to: mask, ".allOnes(where: $0 \(op) $1)"))
            }
        }

        ops += [
            unary("v128Not", "UInt64", "~$0"),
            binary("v128And", "UInt64", "$0 & $1"),
            binary("v128Andnot", "UInt64", "$0 & ~$1"),
            binary("v128Or", "UInt64", "$0 | $1"),
            binary("v128Xor", "UInt64", "$0 ^ $1"),
            ternary("v128Bitselect", "UInt64", "bitselect($0, $1, $2)"),
            test("v128AnyTrue", "UInt64", "any($0 .!= 0) ? 1 : 0"),
        ]

        for (shape, width) in [("i8x16", "8"), ("i16x8", "16"), ("i32x4", "32"), ("i64x2", "64")] {
            ops += [
                unary("\(shape)Abs", "Int\(width)", "$0.replacing(with: 0 &- $0, where: $0 .< 0)"),
                unary("\(shape)Neg", "Int\(width)", "0 &- $0"),
                test("\(shape)AllTrue", "UInt\(width)", "all($0 .!= 0) ? 1 : 0"),
                test("\(shape)Bitmask", "Int\(width)", "bitmask($0)"),
                shift("\(shape)Shl", "UInt\(width)", "$0 &<< $1"),
                shift("\(shape)ShrS", "Int\(width)", "$0 &>> $1"),
                shift("\(shape)ShrU", "UInt\(width)", "$0 &>> $1"),
                binary("\(shape)Add", "UInt\(width)", "$0 &+ $1"),
                binary("\(shape)Sub", "UInt\(width)", "$0 &- $1"),
            ]
            if width != "8" {
                ops.append(binary("\(shape)Mul", "UInt\(width)", "$0 &* $1"))
            }
            if width == "8" || width == "16" {
                ops += [
                    binary("\(shape)AddSatS", "Int\(width)", "saturatingAdd($0, $1)"),
                    binary("\(shape)AddSatU", "UInt\(width)", "saturatingAdd($0, $1)"),
                    binary("\(shape)SubSatS", "Int\(width)", "saturatingSubtract($0, $1)"),
                    binary("\(shape)SubSatU", "UInt\(width)", "saturatingSubtract($0, $1)"),
                    binary("\(shape)AvgrU", "UInt\(width)", "roundingAverage($0, $1)"),
                ]
            }
            if width != "64" {
                ops += [
                    binary("\(shape)MinS", "Int\(width)", "pointwiseMin($0, $1)"),
                    binary("\(shape)MinU", "UInt\(width)", "pointwiseMin($0, $1)"),
                    binary("\(shape)MaxS", "Int\(width)", "pointwiseMax($0, $1)"),
                    binary("\(shape)MaxU", "UInt\(width)", "pointwiseMax($0, $1)"),
                ]
            }
        }

        // Widening and narrowing. `narrow`'s result type picks the signedness it saturates to.
        ops += [
            binary("i8x16NarrowI16X8S", "Int16", to: "Int8", "narrow($0, $1)"),
            binary("i8x16NarrowI16X8U", "Int16", to: "UInt8", "narrow($0, $1)"),
            binary("i16x8NarrowI32X4S", "Int32", to: "Int16", "narrow($0, $1)"),
            binary("i16x8NarrowI32X4U", "Int32", to: "UInt16", "narrow($0, $1)"),
        ]
        for (shape, narrow, wide) in [("i16x8", "8", "16"), ("i32x4", "16", "32"), ("i64x2", "32", "64")] {
            let narrowShape = ["8": "I8X16", "16": "I16X8", "32": "I32X4"][narrow]!
            for (signedness, prefix) in [("S", "Int"), ("U", "UInt")] {
                let from = "\(prefix)\(narrow)"
                let to = "\(prefix)\(wide)"
                ops += [
                    unary("\(shape)ExtendLow\(narrowShape)\(signedness)", from, to: to, ".init(truncatingIfNeeded: $0.lowHalf)"),
                    unary("\(shape)ExtendHigh\(narrowShape)\(signedness)", from, to: to, ".init(truncatingIfNeeded: $0.highHalf)"),
                    binary(
                        "\(shape)ExtmulLow\(narrowShape)\(signedness)", from, to: to,
                        "\(to).Vector(truncatingIfNeeded: $0.lowHalf) &* \(to).Vector(truncatingIfNeeded: $1.lowHalf)"),
                    binary(
                        "\(shape)ExtmulHigh\(narrowShape)\(signedness)", from, to: to,
                        "\(to).Vector(truncatingIfNeeded: $0.highHalf) &* \(to).Vector(truncatingIfNeeded: $1.highHalf)"),
                ]
                if wide != "64" {
                    ops.append(
                        unary(
                            "\(shape)ExtaddPairwise\(narrowShape)\(signedness)", from, to: to,
                            "\(to).Vector(truncatingIfNeeded: $0.evenHalf) &+ \(to).Vector(truncatingIfNeeded: $0.oddHalf)"))
                }
            }
        }
        ops += [
            binary(
                "i32x4DotI16X8S", "Int16", to: "Int32",
                "Int32.Vector(truncatingIfNeeded: $0.evenHalf) &* Int32.Vector(truncatingIfNeeded: $1.evenHalf) &+ Int32.Vector(truncatingIfNeeded: $0.oddHalf) &* Int32.Vector(truncatingIfNeeded: $1.oddHalf)"
            ),
            binary("i16x8Q15MulrSatS", "Int16", "q15MulRoundSaturating($0, $1)"),
            unary("i8x16Popcnt", "UInt8", "lanewise($0) { UInt8($0.nonzeroBitCount) }"),
        ]

        // Floating point. Abs and neg change only the sign bit, NaN or not.
        for (shape, lane, bits, signBit) in [("f32x4", "Float", "UInt32", "0x8000_0000"), ("f64x2", "Double", "UInt64", "0x8000_0000_0000_0000")] {
            ops += [
                unary("\(shape)Ceil", lane, "$0.rounded(.up)"),
                unary("\(shape)Floor", lane, "$0.rounded(.down)"),
                unary("\(shape)Trunc", lane, "$0.rounded(.towardZero)"),
                unary("\(shape)Nearest", lane, "$0.rounded(.toNearestOrEven)"),
                unary("\(shape)Abs", bits, "$0 & ~\(signBit)"),
                unary("\(shape)Neg", bits, "$0 ^ \(signBit)"),
                unary("\(shape)Sqrt", lane, "$0.squareRoot()"),
                binary("\(shape)Add", lane, "$0 + $1"),
                binary("\(shape)Sub", lane, "$0 - $1"),
                binary("\(shape)Mul", lane, "$0 * $1"),
                binary("\(shape)Div", lane, "$0 / $1"),
                binary("\(shape)Min", lane, "lanewise($0, $1) { $0.min($1) }"),
                binary("\(shape)Max", lane, "lanewise($0, $1) { $0.max($1) }"),
                // pmin is `b < a ? b : a`, and pmax `a < b ? b : a`.
                binary("\(shape)Pmin", lane, "$0.replacing(with: $1, where: $1 .< $0)"),
                binary("\(shape)Pmax", lane, "$0.replacing(with: $1, where: $0 .< $1)"),
            ]
        }
        ops += [
            unary("i32x4TruncSatF32X4S", "Float", to: "UInt32", "lanewise($0) { $0.truncSatToI32S }"),
            unary("i32x4TruncSatF32X4U", "Float", to: "UInt32", "lanewise($0) { $0.truncSatToI32U }"),
            unary("f32x4ConvertI32X4S", "Int32", to: "Float", ".init($0)"),
            unary("f32x4ConvertI32X4U", "UInt32", to: "Float", ".init($0)"),
            unary("f64x2ConvertLowI32X4S", "Int32", to: "Double", ".init($0.lowHalf)"),
            unary("f64x2ConvertLowI32X4U", "UInt32", to: "Double", ".init($0.lowHalf)"),
            unary("i32x4TruncSatF64X2SZero", "Double", to: "UInt32", ".init(lowHalf: lanewise($0) { $0.truncSatToI32S }, highHalf: .zero)"),
            unary("i32x4TruncSatF64X2UZero", "Double", to: "UInt32", ".init(lowHalf: lanewise($0) { $0.truncSatToI32U }, highHalf: .zero)"),
            unary("f32x4DemoteF64X2Zero", "Double", to: "Float", ".init(lowHalf: .init($0), highHalf: .zero)"),
            unary("f64x2PromoteLowF32X4", "Float", to: "Double", ".init($0.lowHalf)"),
        ]

        // Relaxed SIMD. Each picks one of the results the proposal allows, the deterministic one.
        ops += [
            binary("i8x16RelaxedSwizzle", "UInt8", "swizzle($0, $1)"),
            unary("i32x4RelaxedTruncF32X4S", "Float", to: "UInt32", "lanewise($0) { $0.truncSatToI32S }"),
            unary("i32x4RelaxedTruncF32X4U", "Float", to: "UInt32", "lanewise($0) { $0.truncSatToI32U }"),
            unary("i32x4RelaxedTruncF64X2SZero", "Double", to: "UInt32", ".init(lowHalf: lanewise($0) { $0.truncSatToI32S }, highHalf: .zero)"),
            unary("i32x4RelaxedTruncF64X2UZero", "Double", to: "UInt32", ".init(lowHalf: lanewise($0) { $0.truncSatToI32U }, highHalf: .zero)"),
            // Unfused: the product is rounded before the sum.
            ternary("f32x4RelaxedMadd", "Float", "unfusedMultiplyAdd($0, $1, $2)"),
            ternary("f32x4RelaxedNmadd", "Float", "unfusedMultiplyAdd(-$0, $1, $2)"),
            ternary("f64x2RelaxedMadd", "Double", "unfusedMultiplyAdd($0, $1, $2)"),
            ternary("f64x2RelaxedNmadd", "Double", "unfusedMultiplyAdd(-$0, $1, $2)"),
            ternary("i8x16RelaxedLaneselect", "UInt64", "bitselect($0, $1, $2)"),
            ternary("i16x8RelaxedLaneselect", "UInt64", "bitselect($0, $1, $2)"),
            ternary("i32x4RelaxedLaneselect", "UInt64", "bitselect($0, $1, $2)"),
            ternary("i64x2RelaxedLaneselect", "UInt64", "bitselect($0, $1, $2)"),
            binary("f32x4RelaxedMin", "Float", "lanewise($0, $1) { $0.min($1) }"),
            binary("f32x4RelaxedMax", "Float", "lanewise($0, $1) { $0.max($1) }"),
            binary("f64x2RelaxedMin", "Double", "lanewise($0, $1) { $0.min($1) }"),
            binary("f64x2RelaxedMax", "Double", "lanewise($0, $1) { $0.max($1) }"),
            binary("i16x8RelaxedQ15MulrS", "Int16", "q15MulRoundSaturating($0, $1)"),
            binary("i16x8RelaxedDotI8X16I7X16S", "Int8", to: "Int16", "relaxedDot($0, $1)"),
            ternary("i32x4RelaxedDotI8X16I7X16AddS", "Int8", to: "Int32", "relaxedDotAdd($0, $1, $2)"),
        ]
        return ops
    }()

    static var simdInstructions: [Instruction] {
        simdOps.map(\.instruction)
    }

    /// The constructors the translator builds SIMD instructions with, from a `SIMDOpcode` and
    /// the operand of the instruction's shape.
    static func generateSIMDConstructors() -> String {
        var output = """


            extension Instruction {
            """
        for shape in SIMDShape.allCases {
            let ops = simdOps.filter { $0.shape == shape }
            output += """

                    /// The instruction for `opcode`, which must take a `\(shape.layout.name)`.
                    static func simd(_ opcode: SIMDOpcode, \(shape.constructorLabel) operand: \(shape.layout.name)) -> Instruction {
                        switch opcode {
                """
            for op in ops {
                output += """

                            case .\(op.name): return .\(op.name)(operand)
                    """
            }
            output += """

                        default: preconditionFailure("\\(opcode) does not take a \(shape.layout.name)")
                        }
                    }

                """
        }
        output += """
            }

            """
        return output
    }
}
