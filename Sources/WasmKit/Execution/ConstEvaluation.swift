import WasmParser

protocol ConstEvaluationContextProtocol {
    var typeRegistry: TypeRegistry { get }
    var canonicalizer: TypeCanonicalizer { get }
    var gcHeap: GCHeap { get }
    func functionRef(_ index: FunctionIndex) throws -> Reference
    func globalValue(_ index: GlobalIndex) throws -> Value
}

struct ConstEvaluationContext: ConstEvaluationContextProtocol {
    let typeRegistry: TypeRegistry
    let canonicalizer: TypeCanonicalizer
    /// Where `struct.new` and the `array.new` instructions allocate.
    let gcHeap: GCHeap
    let functions: ImmutableArray<InternalFunction>
    /// The globals a constant expression may read, which depends on where it appears.
    var globals: [InternalGlobal]
    let onFunctionReferenced: ((FunctionIndex) -> Void)?

    init(
        typeRegistry: TypeRegistry,
        canonicalizer: TypeCanonicalizer,
        gcHeap: GCHeap,
        functions: ImmutableArray<InternalFunction>,
        globals: [InternalGlobal],
        onFunctionReferenced: ((FunctionIndex) -> Void)? = nil
    ) {
        self.typeRegistry = typeRegistry
        self.canonicalizer = canonicalizer
        self.gcHeap = gcHeap
        self.functions = functions
        self.globals = globals
        self.onFunctionReferenced = onFunctionReferenced
    }

    /// A context for element and data segment offsets, which may read every global.
    init(instance: InternalInstance, gcHeap: GCHeap) {
        self.init(
            typeRegistry: instance.typeRegistry, canonicalizer: instance.typeCanonicalizer, gcHeap: gcHeap,
            functions: instance.functions, globals: Array(instance.globals))
    }

    func functionRef(_ index: FunctionIndex) throws -> Reference {
        let function = try self.functions[validating: Int(index)]
        self.onFunctionReferenced?(index)
        return .function(from: function)
    }
    func globalValue(_ index: GlobalIndex) throws -> Value {
        guard index < globals.count else {
            throw GlobalEntity.createOutOfBoundsError(index: Int(index), count: globals.count)
        }
        let global = self.globals[Int(index)]
        guard global.globalType.mutability == .constant else {
            throw WasmKitError(message: .mutableGlobalInConstExpression(index: index))
        }
        return global.value
    }
}

extension ConstExpression {
    func evaluate<C: ConstEvaluationContextProtocol>(context: C, expectedType: WasmTypes.ValueType) throws -> Value {
        let result = try self._evaluate(context: context)
        try result.checkType(expectedType, in: context.typeRegistry)
        return result
    }

    fileprivate func _evaluate<C: ConstEvaluationContextProtocol>(context: C) throws -> Value {
        guard self.last == .end else {
            throw WasmKitError(message: .expectedEndAtOffsetExpression)
        }
        // Evaluate the expression as a small stack machine: a sequence of const-safe instructions
        // terminated by `end`. Extended constant expressions allow more than one instruction; anything
        // not handled below throws.
        var stack: [Value] = []
        for constInst in self.dropLast() {
            switch constInst {
            case .i32Const(let value): stack.append(.i32(UInt32(bitPattern: value)))
            case .i64Const(let value): stack.append(.i64(UInt64(bitPattern: value)))
            case .f32Const(let value): stack.append(.f32(value.bitPattern))
            case .f64Const(let value): stack.append(.f64(value.bitPattern))
            case .v128Const(let value): stack.append(.v128(value))
            case .globalGet(let globalIndex):
                stack.append(try context.globalValue(globalIndex))
            case .refNull(let type):
                let top = context.typeRegistry.top(of: try context.canonicalizer.canonicalize(type))
                stack.append(.ref(UntypedValue.nullReference.asReference(.funcRef, top: top)))
            case .refI31:
                guard case .i32(let value) = stack.popLast() else {
                    throw WasmKitError(message: .illegalConstExpressionInstruction(constInst))
                }
                stack.append(.ref(.any(.i31(value))))
            case .anyConvertExtern, .externConvertAny:
                // The value stays as it is, but for the null, which is of the other hierarchy.
                guard case .ref(let reference) = stack.popLast() else {
                    throw WasmKitError(message: .illegalConstExpressionInstruction(constInst))
                }
                switch (constInst, reference) {
                case (.anyConvertExtern, .extern(nil)): stack.append(.ref(.any(nil)))
                case (.externConvertAny, .any(nil)): stack.append(.ref(.extern(nil)))
                default: stack.append(.ref(reference))
                }
            case .structNew(let typeIndex), .structNewDefault(let typeIndex), .arrayNew(let typeIndex),
                .arrayNewDefault(let typeIndex), .arrayNewFixed(let typeIndex, _):
                stack.append(.ref(try Self.allocate(constInst, typeIndex: typeIndex, stack: &stack, context: context)))
            case .refFunc(let functionIndex):
                stack.append(.ref(try context.functionRef(functionIndex)))
            case .binary(let op):
                // Extended-const arithmetic: i32/i64 add/sub/mul. Other binary ops fall to the inner default.
                switch op {
                case .i32Add, .i32Sub, .i32Mul:
                    let (lhs, rhs) = try Self.popI32Pair(&stack, op)
                    switch op {
                    case .i32Add: stack.append(.i32(lhs.add(rhs)))
                    case .i32Sub: stack.append(.i32(lhs.sub(rhs)))
                    default: stack.append(.i32(lhs.mul(rhs)))  // .i32Mul
                    }
                case .i64Add, .i64Sub, .i64Mul:
                    let (lhs, rhs) = try Self.popI64Pair(&stack, op)
                    switch op {
                    case .i64Add: stack.append(.i64(lhs.add(rhs)))
                    case .i64Sub: stack.append(.i64(lhs.sub(rhs)))
                    default: stack.append(.i64(lhs.mul(rhs)))  // .i64Mul
                    }
                default:
                    throw WasmKitError(message: .illegalConstExpressionInstruction(constInst))
                }
            default:
                throw WasmKitError(message: .illegalConstExpressionInstruction(constInst))
            }
        }
        guard stack.count == 1 else {
            throw WasmKitError(message: .invalidConstExpressionArity(count: stack.count))
        }
        return stack[0]
    }

    /// Evaluates `struct.new`, `struct.new_default` or one of the `array.new` instructions that a
    /// constant expression allows, popping its operands.
    private static func allocate<C: ConstEvaluationContextProtocol>(
        _ instruction: WasmParser.Instruction, typeIndex: UInt32, stack: inout [Value], context: C
    ) throws -> Reference {
        let id = try context.canonicalizer.canonicalID(of: typeIndex).id
        guard let type = context.typeRegistry.definition(of: id).gcType else {
            throw WasmKitError(message: .illegalConstExpressionInstruction(instruction))
        }
        func pop(_ count: Int) throws -> ArraySlice<Value> {
            guard stack.count >= count else {
                throw WasmKitError(message: .illegalConstExpressionInstruction(instruction))
            }
            defer { stack.removeLast(count) }
            return stack.suffix(count)
        }
        func popLength() throws -> Int {
            guard case .i32(let length) = try pop(1).first else {
                throw WasmKitError(message: .illegalConstExpressionInstruction(instruction))
            }
            return Int(length)
        }
        func store(_ value: Value, _ kind: GCStorageKind, at pointer: UnsafeMutableRawPointer) {
            if case .v128(let vector) = value {
                let storage = V128Storage(vector)
                kind.store(storage.lo, storage.hi, to: pointer)
            } else {
                kind.store(UntypedValue(value).storage, 0, to: pointer)
            }
        }
        let object: GCObject
        switch instruction {
        case .structNew:
            let values = try pop(type.fields.count)
            object = try context.gcHeap.allocate(type)
            for (field, value) in zip(type.fields, values) {
                store(value, field.kind, at: object.storage + field.offset)
            }
        case .structNewDefault:
            object = try context.gcHeap.allocate(type)
        case .arrayNew:
            let length = try popLength()
            guard let value = try pop(1).first else {
                throw WasmKitError(message: .illegalConstExpressionInstruction(instruction))
            }
            object = try context.gcHeap.allocate(type, length: length)
            for index in 0..<length {
                store(value, type.element.kind, at: object.element(at: index))
            }
        case .arrayNewDefault:
            object = try context.gcHeap.allocate(type, length: try popLength())
        case .arrayNewFixed(_, let size):
            let values = try pop(Int(size))
            object = try context.gcHeap.allocate(type, length: Int(size))
            for (index, value) in values.enumerated() {
                store(value, type.element.kind, at: object.element(at: index))
            }
        default:
            throw WasmKitError(message: .illegalConstExpressionInstruction(instruction))
        }
        return .any(AnyReference(bits: object.bits, object: object))
    }

    /// Pops the two `i32` operands of a binary const-arithmetic instruction (right operand first, so the
    /// result is `lhs op rhs`). Throws on stack underflow or non-`i32` operands.
    private static func popI32Pair(_ stack: inout [Value], _ op: WasmParser.Instruction.Binary) throws -> (UInt32, UInt32) {
        guard stack.count >= 2, case .i32(let rhs) = stack.removeLast(), case .i32(let lhs) = stack.removeLast()
        else { throw WasmKitError(message: .illegalConstExpressionInstruction(.binary(op))) }
        return (lhs, rhs)
    }

    /// Pops the two `i64` operands of a binary const-arithmetic instruction (right operand first, so the
    /// result is `lhs op rhs`). Throws on stack underflow or non-`i64` operands.
    private static func popI64Pair(_ stack: inout [Value], _ op: WasmParser.Instruction.Binary) throws -> (UInt64, UInt64) {
        guard stack.count >= 2, case .i64(let rhs) = stack.removeLast(), case .i64(let lhs) = stack.removeLast()
        else { throw WasmKitError(message: .illegalConstExpressionInstruction(.binary(op))) }
        return (lhs, rhs)
    }
}

extension WasmParser.ElementSegment {
    /// Evaluates the segment's items, checking each against `type`, the
    /// segment's canonical element type.
    func evaluateInits<C: ConstEvaluationContextProtocol>(context: C, type: ReferenceType) throws -> [Reference] {
        return try self.initializer.map { expression -> Reference in
            let result = try Self._evaluateInits(context: context, expression: expression)
            try result.checkType(type, in: context.typeRegistry)
            return result
        }
    }
    static func _evaluateInits<C: ConstEvaluationContextProtocol>(
        context: C, expression: ConstExpression
    ) throws -> Reference {
        // Function-index items have no `end`.
        guard expression.count == 1 || (expression.count == 2 && expression[1] == .end) else {
            // A longer constant expression, such as `struct.new` with its operands, which `gc`
            // allows.
            guard expression.last == .end, case .ref(let reference) = try expression._evaluate(context: context) else {
                throw WasmKitError(message: .unexpectedElementInitializer(expression: "\(expression)"))
            }
            return reference
        }
        switch expression[0] {
        case .refFunc(let index):
            return try context.functionRef(index)
        case .refNull(.funcRef), .refNull(.concrete):
            return .function(nil)
        case .refNull(.externRef):
            return .extern(nil)
        case .refNull(.exnRef):
            return .exception(nil)
        case .globalGet(let index):
            // Any reference type: an `externref` or `exnref` table takes items from such
            // globals too. Validation has already matched the global's type to the segment's.
            guard case .ref(let reference) = try context.globalValue(index) else {
                throw WasmKitError(message: .unexpectedGlobalValueType)
            }
            return reference
        default:
            // Any other constant expression, such as `struct.new_default`.
            guard expression.last == .end, case .ref(let reference) = try expression._evaluate(context: context) else {
                throw WasmKitError(message: .unexpectedElementInitializer(expression: "\(expression)"))
            }
            return reference
        }
    }
}

/// What the static type of a constant expression depends on, with every type
/// canonical.
struct ConstExpressionTypeContext {
    let canonicalizer: TypeCanonicalizer
    let typeRegistry: TypeRegistry
    let functions: ImmutableArray<InternalFunction>
    /// The types of the globals a constant expression may read.
    var globalTypes: [GlobalType]
}

extension ConstExpression {
    /// Checks that the expression's static type is a subtype of `expectedType`.
    ///
    /// Evaluation checks the resulting value too, but a null value does not
    /// tell which null it is: `ref.null func` must not initialize a
    /// `(ref null $t)`. Malformed expressions are left for evaluation to report.
    func checkType(_ expectedType: ValueType, context: ConstExpressionTypeContext) throws(WasmKitError) {
        guard let type = try staticType(context: context) else { return }
        guard context.typeRegistry.isSubtype(type, of: expectedType) else {
            throw WasmKitError(message: .expectTypeButGot(expected: "\(expectedType)", got: "\(type)"))
        }
    }

    /// The type of the value the expression produces, or `nil` if the
    /// expression is not a well-formed constant expression.
    private func staticType(context: ConstExpressionTypeContext) throws(WasmKitError) -> ValueType? {
        var stack: [ValueType] = []
        for instruction in self {
            switch instruction {
            case .end: break
            case .i32Const: stack.append(.i32)
            case .i64Const: stack.append(.i64)
            case .f32Const: stack.append(.f32)
            case .f64Const: stack.append(.f64)
            case .v128Const: stack.append(.v128)
            case .globalGet(let index):
                guard Int(index) < context.globalTypes.count else { return nil }
                stack.append(context.globalTypes[Int(index)].valueType)
            case .refNull(let heapType):
                stack.append(.ref(ReferenceType(isNullable: true, heapType: try context.canonicalizer.canonicalize(heapType))))
            case .refFunc(let index):
                guard Int(index) < context.functions.count else { return nil }
                let function = context.functions[Int(index)]
                stack.append(.ref(ReferenceType(isNullable: false, heapType: .concrete(typeIndex: function.type.id))))
            case .refI31:
                guard stack.popLast() != nil else { return nil }
                stack.append(.ref(ReferenceType(isNullable: false, heapType: .abstract(.i31))))
            case .structNew(let typeIndex), .structNewDefault(let typeIndex), .arrayNew(let typeIndex),
                .arrayNewDefault(let typeIndex), .arrayNewFixed(let typeIndex, _):
                // Evaluation checks the operands' types.
                let id = try context.canonicalizer.canonicalID(of: typeIndex).id
                let operandCount: Int
                switch (instruction, context.typeRegistry.definition(of: id).composite) {
                case (.structNew, .structType(let type)): operandCount = type.fields.count
                case (.structNewDefault, .structType): operandCount = 0
                case (.arrayNew, .arrayType): operandCount = 2
                case (.arrayNewDefault, .arrayType): operandCount = 1
                case (.arrayNewFixed(_, let size), .arrayType): operandCount = Int(size)
                default: return nil
                }
                guard stack.count >= operandCount else { return nil }
                stack.removeLast(operandCount)
                stack.append(.ref(ReferenceType(isNullable: false, heapType: .concrete(typeIndex: id))))
            case .anyConvertExtern, .externConvertAny:
                guard case .ref(let operand) = stack.popLast() else { return nil }
                let heapType: AbstractHeapType = instruction == .anyConvertExtern ? .any : .externRef
                stack.append(.ref(ReferenceType(isNullable: operand.isNullable, heapType: .abstract(heapType))))
            case .binary(.i32Add), .binary(.i32Sub), .binary(.i32Mul), .binary(.i64Add), .binary(.i64Sub), .binary(.i64Mul):
                // Evaluation checks the operand types.
                guard let result = stack.popLast(), stack.popLast() != nil else { return nil }
                stack.append(result)
            default:
                return nil
            }
        }
        return stack.count == 1 ? stack[0] : nil
    }
}
