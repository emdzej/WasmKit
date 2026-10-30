import WasmParser

/// The SIMD instructions, each of which the VM has an instruction of the same name for.
///
/// The translator maps a WebAssembly instruction to one of these, then builds the VM
/// instruction with the `Instruction.simd(_:...)` constructor of its operands' shape.
enum SIMDOpcode {
    case v128Load
    case v128Load8X8S
    case v128Load8X8U
    case v128Load16X4S
    case v128Load16X4U
    case v128Load32X2S
    case v128Load32X2U
    case v128Load8Splat
    case v128Load16Splat
    case v128Load32Splat
    case v128Load64Splat
    case v128Load32Zero
    case v128Load64Zero
    case v128Store
    case v128Load8Lane
    case v128Load16Lane
    case v128Load32Lane
    case v128Load64Lane
    case v128Store8Lane
    case v128Store16Lane
    case v128Store32Lane
    case v128Store64Lane
    case i8x16ExtractLaneS
    case i8x16ExtractLaneU
    case i8x16ReplaceLane
    case i16x8ExtractLaneS
    case i16x8ExtractLaneU
    case i16x8ReplaceLane
    case i32x4ExtractLane
    case i32x4ReplaceLane
    case i64x2ExtractLane
    case i64x2ReplaceLane
    case f32x4ExtractLane
    case f32x4ReplaceLane
    case f64x2ExtractLane
    case f64x2ReplaceLane
    case i8x16Swizzle
    case i8x16Splat
    case i16x8Splat
    case i32x4Splat
    case i64x2Splat
    case f32x4Splat
    case f64x2Splat
    case i8x16Eq
    case i8x16Ne
    case i8x16LtS
    case i8x16LtU
    case i8x16GtS
    case i8x16GtU
    case i8x16LeS
    case i8x16LeU
    case i8x16GeS
    case i8x16GeU
    case i16x8Eq
    case i16x8Ne
    case i16x8LtS
    case i16x8LtU
    case i16x8GtS
    case i16x8GtU
    case i16x8LeS
    case i16x8LeU
    case i16x8GeS
    case i16x8GeU
    case i32x4Eq
    case i32x4Ne
    case i32x4LtS
    case i32x4LtU
    case i32x4GtS
    case i32x4GtU
    case i32x4LeS
    case i32x4LeU
    case i32x4GeS
    case i32x4GeU
    case f32x4Eq
    case f32x4Ne
    case f32x4Lt
    case f32x4Gt
    case f32x4Le
    case f32x4Ge
    case f64x2Eq
    case f64x2Ne
    case f64x2Lt
    case f64x2Gt
    case f64x2Le
    case f64x2Ge
    case v128Not
    case v128And
    case v128Andnot
    case v128Or
    case v128Xor
    case v128Bitselect
    case i8x16Abs
    case i8x16Neg
    case i8x16AllTrue
    case i8x16Bitmask
    case i8x16NarrowI16X8S
    case i8x16NarrowI16X8U
    case i8x16Shl
    case i8x16ShrS
    case i8x16ShrU
    case i8x16Add
    case i8x16AddSatS
    case i8x16AddSatU
    case i8x16Sub
    case i8x16SubSatS
    case i8x16SubSatU
    case i8x16MinS
    case i8x16MinU
    case i8x16MaxS
    case i8x16MaxU
    case i8x16AvgrU
    case i16x8Abs
    case i16x8Neg
    case i16x8AllTrue
    case i16x8Bitmask
    case i16x8NarrowI32X4S
    case i16x8NarrowI32X4U
    case i16x8ExtendLowI8X16S
    case i16x8ExtendHighI8X16S
    case i16x8ExtendLowI8X16U
    case i16x8ExtendHighI8X16U
    case i16x8Shl
    case i16x8ShrS
    case i16x8ShrU
    case i16x8Add
    case i16x8AddSatS
    case i16x8AddSatU
    case i16x8Sub
    case i16x8SubSatS
    case i16x8SubSatU
    case i16x8Mul
    case i16x8MinS
    case i16x8MinU
    case i16x8MaxS
    case i16x8MaxU
    case i16x8AvgrU
    case i32x4Abs
    case i32x4Neg
    case i32x4AllTrue
    case i32x4Bitmask
    case i32x4ExtendLowI16X8S
    case i32x4ExtendHighI16X8S
    case i32x4ExtendLowI16X8U
    case i32x4ExtendHighI16X8U
    case i32x4Shl
    case i32x4ShrS
    case i32x4ShrU
    case i32x4Add
    case i32x4Sub
    case i32x4Mul
    case i32x4MinS
    case i32x4MinU
    case i32x4MaxS
    case i32x4MaxU
    case i32x4DotI16X8S
    case i64x2Abs
    case i64x2Neg
    case i64x2Bitmask
    case i64x2ExtendLowI32X4S
    case i64x2ExtendHighI32X4S
    case i64x2ExtendLowI32X4U
    case i64x2ExtendHighI32X4U
    case i64x2Shl
    case i64x2ShrS
    case i64x2ShrU
    case i64x2Add
    case i64x2Sub
    case i64x2Mul
    case f32x4Ceil
    case f32x4Floor
    case f32x4Trunc
    case f32x4Nearest
    case f64x2Ceil
    case f64x2Floor
    case f64x2Trunc
    case f64x2Nearest
    case f32x4Abs
    case f32x4Neg
    case f32x4Sqrt
    case f32x4Add
    case f32x4Sub
    case f32x4Mul
    case f32x4Div
    case f32x4Min
    case f32x4Max
    case f32x4Pmin
    case f32x4Pmax
    case f64x2Abs
    case f64x2Neg
    case f64x2Sqrt
    case f64x2Add
    case f64x2Sub
    case f64x2Mul
    case f64x2Div
    case f64x2Min
    case f64x2Max
    case f64x2Pmin
    case f64x2Pmax
    case i32x4TruncSatF32X4S
    case i32x4TruncSatF32X4U
    case f32x4ConvertI32X4S
    case f32x4ConvertI32X4U
    case i8x16RelaxedSwizzle
    case i32x4RelaxedTruncF32X4S
    case i32x4RelaxedTruncF32X4U
    case i32x4RelaxedTruncF64X2SZero
    case i32x4RelaxedTruncF64X2UZero
    case f32x4RelaxedMadd
    case f32x4RelaxedNmadd
    case f64x2RelaxedMadd
    case f64x2RelaxedNmadd
    case i8x16RelaxedLaneselect
    case i16x8RelaxedLaneselect
    case i32x4RelaxedLaneselect
    case i64x2RelaxedLaneselect
    case f32x4RelaxedMin
    case f32x4RelaxedMax
    case f64x2RelaxedMin
    case f64x2RelaxedMax
    case i16x8RelaxedQ15MulrS
    case i16x8RelaxedDotI8X16I7X16S
    case i32x4RelaxedDotI8X16I7X16AddS
    case i16x8ExtmulLowI8X16S
    case i16x8ExtmulHighI8X16S
    case i16x8ExtmulLowI8X16U
    case i16x8ExtmulHighI8X16U
    case i32x4ExtmulLowI16X8S
    case i32x4ExtmulHighI16X8S
    case i32x4ExtmulLowI16X8U
    case i32x4ExtmulHighI16X8U
    case i64x2ExtmulLowI32X4S
    case i64x2ExtmulHighI32X4S
    case i64x2ExtmulLowI32X4U
    case i64x2ExtmulHighI32X4U
    case i16x8Q15MulrSatS
    case v128AnyTrue
    case i64x2Eq
    case i64x2Ne
    case i64x2LtS
    case i64x2GtS
    case i64x2LeS
    case i64x2GeS
    case i64x2AllTrue
    case f64x2ConvertLowI32X4S
    case f64x2ConvertLowI32X4U
    case i32x4TruncSatF64X2SZero
    case i32x4TruncSatF64X2UZero
    case f32x4DemoteF64X2Zero
    case f64x2PromoteLowF32X4
    case i8x16Popcnt
    case i16x8ExtaddPairwiseI8X16S
    case i16x8ExtaddPairwiseI8X16U
    case i32x4ExtaddPairwiseI16X8S
    case i32x4ExtaddPairwiseI16X8U
}

extension SIMDOpcode {
    static func fromLoad(_ value: WasmParser.Instruction.Load) -> SIMDOpcode? {
        switch value {
        case .v128Load: return .v128Load
        case .v128Load8X8S: return .v128Load8X8S
        case .v128Load8X8U: return .v128Load8X8U
        case .v128Load16X4S: return .v128Load16X4S
        case .v128Load16X4U: return .v128Load16X4U
        case .v128Load32X2S: return .v128Load32X2S
        case .v128Load32X2U: return .v128Load32X2U
        case .v128Load8Splat: return .v128Load8Splat
        case .v128Load16Splat: return .v128Load16Splat
        case .v128Load32Splat: return .v128Load32Splat
        case .v128Load64Splat: return .v128Load64Splat
        case .v128Load32Zero: return .v128Load32Zero
        case .v128Load64Zero: return .v128Load64Zero
        default: return nil
        }
    }

    static func fromStore(_ value: WasmParser.Instruction.Store) -> SIMDOpcode? {
        switch value {
        case .v128Store: return .v128Store
        default: return nil
        }
    }

    static func fromSimd(_ value: WasmParser.Instruction.Simd) -> SIMDOpcode? {
        switch value {
        case .i8x16Swizzle: return .i8x16Swizzle
        case .i8x16Splat: return .i8x16Splat
        case .i16x8Splat: return .i16x8Splat
        case .i32x4Splat: return .i32x4Splat
        case .i64x2Splat: return .i64x2Splat
        case .f32x4Splat: return .f32x4Splat
        case .f64x2Splat: return .f64x2Splat
        case .i8x16Eq: return .i8x16Eq
        case .i8x16Ne: return .i8x16Ne
        case .i8x16LtS: return .i8x16LtS
        case .i8x16LtU: return .i8x16LtU
        case .i8x16GtS: return .i8x16GtS
        case .i8x16GtU: return .i8x16GtU
        case .i8x16LeS: return .i8x16LeS
        case .i8x16LeU: return .i8x16LeU
        case .i8x16GeS: return .i8x16GeS
        case .i8x16GeU: return .i8x16GeU
        case .i16x8Eq: return .i16x8Eq
        case .i16x8Ne: return .i16x8Ne
        case .i16x8LtS: return .i16x8LtS
        case .i16x8LtU: return .i16x8LtU
        case .i16x8GtS: return .i16x8GtS
        case .i16x8GtU: return .i16x8GtU
        case .i16x8LeS: return .i16x8LeS
        case .i16x8LeU: return .i16x8LeU
        case .i16x8GeS: return .i16x8GeS
        case .i16x8GeU: return .i16x8GeU
        case .i32x4Eq: return .i32x4Eq
        case .i32x4Ne: return .i32x4Ne
        case .i32x4LtS: return .i32x4LtS
        case .i32x4LtU: return .i32x4LtU
        case .i32x4GtS: return .i32x4GtS
        case .i32x4GtU: return .i32x4GtU
        case .i32x4LeS: return .i32x4LeS
        case .i32x4LeU: return .i32x4LeU
        case .i32x4GeS: return .i32x4GeS
        case .i32x4GeU: return .i32x4GeU
        case .f32x4Eq: return .f32x4Eq
        case .f32x4Ne: return .f32x4Ne
        case .f32x4Lt: return .f32x4Lt
        case .f32x4Gt: return .f32x4Gt
        case .f32x4Le: return .f32x4Le
        case .f32x4Ge: return .f32x4Ge
        case .f64x2Eq: return .f64x2Eq
        case .f64x2Ne: return .f64x2Ne
        case .f64x2Lt: return .f64x2Lt
        case .f64x2Gt: return .f64x2Gt
        case .f64x2Le: return .f64x2Le
        case .f64x2Ge: return .f64x2Ge
        case .v128Not: return .v128Not
        case .v128And: return .v128And
        case .v128Andnot: return .v128Andnot
        case .v128Or: return .v128Or
        case .v128Xor: return .v128Xor
        case .v128Bitselect: return .v128Bitselect
        case .i8x16Abs: return .i8x16Abs
        case .i8x16Neg: return .i8x16Neg
        case .i8x16AllTrue: return .i8x16AllTrue
        case .i8x16Bitmask: return .i8x16Bitmask
        case .i8x16NarrowI16X8S: return .i8x16NarrowI16X8S
        case .i8x16NarrowI16X8U: return .i8x16NarrowI16X8U
        case .i8x16Shl: return .i8x16Shl
        case .i8x16ShrS: return .i8x16ShrS
        case .i8x16ShrU: return .i8x16ShrU
        case .i8x16Add: return .i8x16Add
        case .i8x16AddSatS: return .i8x16AddSatS
        case .i8x16AddSatU: return .i8x16AddSatU
        case .i8x16Sub: return .i8x16Sub
        case .i8x16SubSatS: return .i8x16SubSatS
        case .i8x16SubSatU: return .i8x16SubSatU
        case .i8x16MinS: return .i8x16MinS
        case .i8x16MinU: return .i8x16MinU
        case .i8x16MaxS: return .i8x16MaxS
        case .i8x16MaxU: return .i8x16MaxU
        case .i8x16AvgrU: return .i8x16AvgrU
        case .i16x8Abs: return .i16x8Abs
        case .i16x8Neg: return .i16x8Neg
        case .i16x8AllTrue: return .i16x8AllTrue
        case .i16x8Bitmask: return .i16x8Bitmask
        case .i16x8NarrowI32X4S: return .i16x8NarrowI32X4S
        case .i16x8NarrowI32X4U: return .i16x8NarrowI32X4U
        case .i16x8ExtendLowI8X16S: return .i16x8ExtendLowI8X16S
        case .i16x8ExtendHighI8X16S: return .i16x8ExtendHighI8X16S
        case .i16x8ExtendLowI8X16U: return .i16x8ExtendLowI8X16U
        case .i16x8ExtendHighI8X16U: return .i16x8ExtendHighI8X16U
        case .i16x8Shl: return .i16x8Shl
        case .i16x8ShrS: return .i16x8ShrS
        case .i16x8ShrU: return .i16x8ShrU
        case .i16x8Add: return .i16x8Add
        case .i16x8AddSatS: return .i16x8AddSatS
        case .i16x8AddSatU: return .i16x8AddSatU
        case .i16x8Sub: return .i16x8Sub
        case .i16x8SubSatS: return .i16x8SubSatS
        case .i16x8SubSatU: return .i16x8SubSatU
        case .i16x8Mul: return .i16x8Mul
        case .i16x8MinS: return .i16x8MinS
        case .i16x8MinU: return .i16x8MinU
        case .i16x8MaxS: return .i16x8MaxS
        case .i16x8MaxU: return .i16x8MaxU
        case .i16x8AvgrU: return .i16x8AvgrU
        case .i32x4Abs: return .i32x4Abs
        case .i32x4Neg: return .i32x4Neg
        case .i32x4AllTrue: return .i32x4AllTrue
        case .i32x4Bitmask: return .i32x4Bitmask
        case .i32x4ExtendLowI16X8S: return .i32x4ExtendLowI16X8S
        case .i32x4ExtendHighI16X8S: return .i32x4ExtendHighI16X8S
        case .i32x4ExtendLowI16X8U: return .i32x4ExtendLowI16X8U
        case .i32x4ExtendHighI16X8U: return .i32x4ExtendHighI16X8U
        case .i32x4Shl: return .i32x4Shl
        case .i32x4ShrS: return .i32x4ShrS
        case .i32x4ShrU: return .i32x4ShrU
        case .i32x4Add: return .i32x4Add
        case .i32x4Sub: return .i32x4Sub
        case .i32x4Mul: return .i32x4Mul
        case .i32x4MinS: return .i32x4MinS
        case .i32x4MinU: return .i32x4MinU
        case .i32x4MaxS: return .i32x4MaxS
        case .i32x4MaxU: return .i32x4MaxU
        case .i32x4DotI16X8S: return .i32x4DotI16X8S
        case .i64x2Abs: return .i64x2Abs
        case .i64x2Neg: return .i64x2Neg
        case .i64x2Bitmask: return .i64x2Bitmask
        case .i64x2ExtendLowI32X4S: return .i64x2ExtendLowI32X4S
        case .i64x2ExtendHighI32X4S: return .i64x2ExtendHighI32X4S
        case .i64x2ExtendLowI32X4U: return .i64x2ExtendLowI32X4U
        case .i64x2ExtendHighI32X4U: return .i64x2ExtendHighI32X4U
        case .i64x2Shl: return .i64x2Shl
        case .i64x2ShrS: return .i64x2ShrS
        case .i64x2ShrU: return .i64x2ShrU
        case .i64x2Add: return .i64x2Add
        case .i64x2Sub: return .i64x2Sub
        case .i64x2Mul: return .i64x2Mul
        case .f32x4Ceil: return .f32x4Ceil
        case .f32x4Floor: return .f32x4Floor
        case .f32x4Trunc: return .f32x4Trunc
        case .f32x4Nearest: return .f32x4Nearest
        case .f64x2Ceil: return .f64x2Ceil
        case .f64x2Floor: return .f64x2Floor
        case .f64x2Trunc: return .f64x2Trunc
        case .f64x2Nearest: return .f64x2Nearest
        case .f32x4Abs: return .f32x4Abs
        case .f32x4Neg: return .f32x4Neg
        case .f32x4Sqrt: return .f32x4Sqrt
        case .f32x4Add: return .f32x4Add
        case .f32x4Sub: return .f32x4Sub
        case .f32x4Mul: return .f32x4Mul
        case .f32x4Div: return .f32x4Div
        case .f32x4Min: return .f32x4Min
        case .f32x4Max: return .f32x4Max
        case .f32x4Pmin: return .f32x4Pmin
        case .f32x4Pmax: return .f32x4Pmax
        case .f64x2Abs: return .f64x2Abs
        case .f64x2Neg: return .f64x2Neg
        case .f64x2Sqrt: return .f64x2Sqrt
        case .f64x2Add: return .f64x2Add
        case .f64x2Sub: return .f64x2Sub
        case .f64x2Mul: return .f64x2Mul
        case .f64x2Div: return .f64x2Div
        case .f64x2Min: return .f64x2Min
        case .f64x2Max: return .f64x2Max
        case .f64x2Pmin: return .f64x2Pmin
        case .f64x2Pmax: return .f64x2Pmax
        case .i32x4TruncSatF32X4S: return .i32x4TruncSatF32X4S
        case .i32x4TruncSatF32X4U: return .i32x4TruncSatF32X4U
        case .f32x4ConvertI32X4S: return .f32x4ConvertI32X4S
        case .f32x4ConvertI32X4U: return .f32x4ConvertI32X4U
        case .i16x8ExtmulLowI8X16S: return .i16x8ExtmulLowI8X16S
        case .i16x8ExtmulHighI8X16S: return .i16x8ExtmulHighI8X16S
        case .i16x8ExtmulLowI8X16U: return .i16x8ExtmulLowI8X16U
        case .i16x8ExtmulHighI8X16U: return .i16x8ExtmulHighI8X16U
        case .i32x4ExtmulLowI16X8S: return .i32x4ExtmulLowI16X8S
        case .i32x4ExtmulHighI16X8S: return .i32x4ExtmulHighI16X8S
        case .i32x4ExtmulLowI16X8U: return .i32x4ExtmulLowI16X8U
        case .i32x4ExtmulHighI16X8U: return .i32x4ExtmulHighI16X8U
        case .i64x2ExtmulLowI32X4S: return .i64x2ExtmulLowI32X4S
        case .i64x2ExtmulHighI32X4S: return .i64x2ExtmulHighI32X4S
        case .i64x2ExtmulLowI32X4U: return .i64x2ExtmulLowI32X4U
        case .i64x2ExtmulHighI32X4U: return .i64x2ExtmulHighI32X4U
        case .i16x8Q15MulrSatS: return .i16x8Q15MulrSatS
        case .v128AnyTrue: return .v128AnyTrue
        case .i64x2Eq: return .i64x2Eq
        case .i64x2Ne: return .i64x2Ne
        case .i64x2LtS: return .i64x2LtS
        case .i64x2GtS: return .i64x2GtS
        case .i64x2LeS: return .i64x2LeS
        case .i64x2GeS: return .i64x2GeS
        case .i64x2AllTrue: return .i64x2AllTrue
        case .f64x2ConvertLowI32X4S: return .f64x2ConvertLowI32X4S
        case .f64x2ConvertLowI32X4U: return .f64x2ConvertLowI32X4U
        case .i32x4TruncSatF64X2SZero: return .i32x4TruncSatF64X2SZero
        case .i32x4TruncSatF64X2UZero: return .i32x4TruncSatF64X2UZero
        case .f32x4DemoteF64X2Zero: return .f32x4DemoteF64X2Zero
        case .f64x2PromoteLowF32X4: return .f64x2PromoteLowF32X4
        case .i8x16Popcnt: return .i8x16Popcnt
        case .i16x8ExtaddPairwiseI8X16S: return .i16x8ExtaddPairwiseI8X16S
        case .i16x8ExtaddPairwiseI8X16U: return .i16x8ExtaddPairwiseI8X16U
        case .i32x4ExtaddPairwiseI16X8S: return .i32x4ExtaddPairwiseI16X8S
        case .i32x4ExtaddPairwiseI16X8U: return .i32x4ExtaddPairwiseI16X8U
        case .i8x16RelaxedSwizzle: return .i8x16RelaxedSwizzle
        case .i32x4RelaxedTruncF32X4S: return .i32x4RelaxedTruncF32X4S
        case .i32x4RelaxedTruncF32X4U: return .i32x4RelaxedTruncF32X4U
        case .i32x4RelaxedTruncF64X2SZero: return .i32x4RelaxedTruncF64X2SZero
        case .i32x4RelaxedTruncF64X2UZero: return .i32x4RelaxedTruncF64X2UZero
        case .f32x4RelaxedMadd: return .f32x4RelaxedMadd
        case .f32x4RelaxedNmadd: return .f32x4RelaxedNmadd
        case .f64x2RelaxedMadd: return .f64x2RelaxedMadd
        case .f64x2RelaxedNmadd: return .f64x2RelaxedNmadd
        case .i8x16RelaxedLaneselect: return .i8x16RelaxedLaneselect
        case .i16x8RelaxedLaneselect: return .i16x8RelaxedLaneselect
        case .i32x4RelaxedLaneselect: return .i32x4RelaxedLaneselect
        case .i64x2RelaxedLaneselect: return .i64x2RelaxedLaneselect
        case .f32x4RelaxedMin: return .f32x4RelaxedMin
        case .f32x4RelaxedMax: return .f32x4RelaxedMax
        case .f64x2RelaxedMin: return .f64x2RelaxedMin
        case .f64x2RelaxedMax: return .f64x2RelaxedMax
        case .i16x8RelaxedQ15MulrS: return .i16x8RelaxedQ15MulrS
        case .i16x8RelaxedDotI8X16I7X16S: return .i16x8RelaxedDotI8X16I7X16S
        case .i32x4RelaxedDotI8X16I7X16AddS: return .i32x4RelaxedDotI8X16I7X16AddS
        }
    }

    static func fromSimdLane(_ value: WasmParser.Instruction.SimdLane) -> SIMDOpcode? {
        switch value {
        case .i8x16ExtractLaneS: return .i8x16ExtractLaneS
        case .i8x16ExtractLaneU: return .i8x16ExtractLaneU
        case .i8x16ReplaceLane: return .i8x16ReplaceLane
        case .i16x8ExtractLaneS: return .i16x8ExtractLaneS
        case .i16x8ExtractLaneU: return .i16x8ExtractLaneU
        case .i16x8ReplaceLane: return .i16x8ReplaceLane
        case .i32x4ExtractLane: return .i32x4ExtractLane
        case .i32x4ReplaceLane: return .i32x4ReplaceLane
        case .i64x2ExtractLane: return .i64x2ExtractLane
        case .i64x2ReplaceLane: return .i64x2ReplaceLane
        case .f32x4ExtractLane: return .f32x4ExtractLane
        case .f32x4ReplaceLane: return .f32x4ReplaceLane
        case .f64x2ExtractLane: return .f64x2ExtractLane
        case .f64x2ReplaceLane: return .f64x2ReplaceLane
        }
    }

    static func fromSimdMemLane(_ value: WasmParser.Instruction.SimdMemLane) -> SIMDOpcode? {
        switch value {
        case .v128Load8Lane: return .v128Load8Lane
        case .v128Load16Lane: return .v128Load16Lane
        case .v128Load32Lane: return .v128Load32Lane
        case .v128Load64Lane: return .v128Load64Lane
        case .v128Store8Lane: return .v128Store8Lane
        case .v128Store16Lane: return .v128Store16Lane
        case .v128Store32Lane: return .v128Store32Lane
        case .v128Store64Lane: return .v128Store64Lane
        }
    }
}
