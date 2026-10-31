// Checking that a value provided for an import has the type the import declares.
//
// This follows wasm-tools' validator (`SubtypeCx` in `component_types.rs`) rather than the
// explainer's subtyping: function and value types must be structurally equal, and resource
// types identical. The mismatch messages are wasm-tools' too. Function parameter names are only
// compared in strict mode: wasmtime's linker ignores them.

#if ComponentModel
    import ComponentModel
    import WasmParser

    /// Why a provided type does not match an expected one, outermost context first.
    struct ComponentTypeMismatch: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }

        /// This mismatch, found inside the part of the type `context` names.
        func within(_ context: String) -> ComponentTypeMismatch {
            ComponentTypeMismatch("\(context): \(description)")
        }

        /// Runs `body`, placing a mismatch it throws within `context`.
        static func within(_ context: String, _ body: () throws -> Void) throws {
            do {
                try body()
            } catch let mismatch as ComponentTypeMismatch {
                throw mismatch.within(context)
            }
        }
    }

    /// Compares an expected type, whose indices resolve in `expected`, against a provided one,
    /// whose indices resolve in `provided`.
    struct ComponentTypeMatcher {
        typealias Resolve = (ComponentTypeIndex) throws -> ComponentTypeSpace.Entry

        let expected: Resolve
        let provided: Resolve
        /// Whether function parameters must have the same names, not just the same types.
        let comparesParameterNames: Bool

        /// Types do not refer to themselves, but a malformed binary's indices could.
        private static let maxDepth = 100

        func match(_ expected: ComponentFuncType, _ provided: ComponentFuncType) throws {
            try match(expected, provided, depth: 0)
        }

        func match(_ expected: ComponentDefValType, _ provided: ComponentDefValType) throws {
            try match(expected, provided, depth: 0)
        }

        private func match(_ expected: ComponentFuncType, _ provided: ComponentFuncType, depth: Int) throws {
            guard expected.params.count == provided.params.count else {
                throw ComponentTypeMismatch("expected \(expected.params.count) parameters, found \(provided.params.count)")
            }
            for (expected, provided) in zip(expected.params, provided.params) {
                guard !comparesParameterNames || expected.name == provided.name else {
                    throw ComponentTypeMismatch("expected parameter named `\(expected.name)`, found `\(provided.name)`")
                }
                try nested("type mismatch in function parameter `\(expected.name)`") {
                    try match(expected.type, provided.type, depth: depth + 1)
                }
            }
            switch (expected.result, provided.result) {
            case (nil, nil): break
            case (nil, .some): throw ComponentTypeMismatch("expected no result, found one")
            case (.some, nil): throw ComponentTypeMismatch("expected a result, found none")
            case (.some(let expected), .some(let provided)):
                try nested("type mismatch with result type") {
                    try match(expected, provided, depth: depth + 1)
                }
            }
        }

        private func match(_ expected: ComponentValType?, _ provided: ComponentValType?, depth: Int, what: String) throws {
            switch (expected, provided) {
            case (nil, nil): break
            case (nil, .some): throw ComponentTypeMismatch("expected \(what) type to not be present")
            case (.some, nil): throw ComponentTypeMismatch("expected \(what) type, but found none")
            case (.some(let expected), .some(let provided)):
                try match(.inlined(expected), .inlined(provided), depth: depth + 1)
            }
        }

        private func match(_ expected: ComponentDefValType, _ provided: ComponentDefValType, depth: Int) throws {
            guard depth < Self.maxDepth else {
                throw ComponentTypeMismatch("type indices nest too deeply or form a cycle")
            }
            let expected = try Self.resolve(expected, in: self.expected)
            let provided = try Self.resolve(provided, in: self.provided)
            switch (expected, provided) {
            case (.inlined(.primitive(let e)), .inlined(.primitive(let p))):
                guard e == p else { throw mismatch(expected, provided) }

            case (.list(let e), .list(let p)):
                try nested("type mismatch in list element") {
                    try match(.inlined(e), .inlined(p), depth: depth + 1)
                }

            case (.tuple(let e), .tuple(let p)):
                guard e.count == p.count else {
                    throw ComponentTypeMismatch("expected \(e.count) types, found \(p.count)")
                }
                for (index, (e, p)) in zip(e, p).enumerated() {
                    try nested("type mismatch in tuple field \(index)") {
                        try match(.inlined(e), .inlined(p), depth: depth + 1)
                    }
                }

            case (.option(let e), .option(let p)):
                try nested("type mismatch in option") {
                    try match(.inlined(e), .inlined(p), depth: depth + 1)
                }

            case (.result(let eOk, let eError), .result(let pOk, let pError)):
                try nested("type mismatch in ok variant") {
                    try match(eOk, pOk, depth: depth, what: "ok")
                }
                try nested("type mismatch in err variant") {
                    try match(eError, pError, depth: depth, what: "err")
                }

            case (.future(let e), .future(let p)):
                try nested("type mismatch in future") {
                    try match(e, p, depth: depth, what: "future")
                }

            case (.stream(let eElement, let eEnd), .stream(let pElement, let pEnd)):
                try nested("type mismatch in stream") {
                    try match(eElement, pElement, depth: depth, what: "stream")
                    try match(eEnd, pEnd, depth: depth, what: "stream end")
                }

            case (.record(let e), .record(let p)):
                guard e.count == p.count else {
                    throw ComponentTypeMismatch("expected \(e.count) fields, found \(p.count)")
                }
                for (e, p) in zip(e, p) {
                    guard e.name == p.name else {
                        throw ComponentTypeMismatch("expected field name `\(e.name)`, found `\(p.name)`")
                    }
                    try nested("type mismatch in record field `\(e.name)`") {
                        try match(.inlined(e.type), .inlined(p.type), depth: depth + 1)
                    }
                }

            case (.variant(let e), .variant(let p)):
                guard e.count == p.count else {
                    throw ComponentTypeMismatch("expected \(e.count) cases, found \(p.count)")
                }
                for (e, p) in zip(e, p) {
                    guard e.name == p.name else {
                        throw ComponentTypeMismatch("expected case named `\(e.name)`, found `\(p.name)`")
                    }
                    switch (e.type, p.type) {
                    case (nil, nil): break
                    case (nil, .some): throw ComponentTypeMismatch("expected case `\(e.name)` to have no type")
                    case (.some, nil): throw ComponentTypeMismatch("expected case `\(e.name)` to have a type, found none")
                    case (.some(let eType), .some(let pType)):
                        try nested("type mismatch in variant case `\(e.name)`") {
                            try match(.inlined(eType), .inlined(pType), depth: depth + 1)
                        }
                    }
                }

            case (.flags(let e), .flags(let p)):
                guard e == p else { throw ComponentTypeMismatch("mismatch in flags elements") }

            case (.enum(let e), .enum(let p)):
                guard e == p else { throw ComponentTypeMismatch("mismatch in enum elements") }

            case (.own(let e), .own(let p)), (.borrow(let e), .borrow(let p)):
                guard case .resource(let e) = try self.expected(e), case .resource(let p) = try self.provided(p) else {
                    throw ComponentTypeMismatch("handle type does not refer to a resource")
                }
                guard e === p else { throw ComponentTypeMismatch("resource types are not the same") }

            default:
                throw mismatch(expected, provided)
            }
        }

        /// `type`, with a type index replaced by the value type it names.
        static func resolve(_ type: ComponentDefValType, in resolve: Resolve) throws -> ComponentDefValType {
            guard case .inlined(.index(let index)) = type else { return type }
            guard case .value(let type) = try resolve(index) else {
                throw ComponentTypeMismatch("type index \(index.rawValue) is not a value type")
            }
            // A value type definition is never just an index, but a malformed one could be.
            if case .inlined(.index) = type {
                throw ComponentTypeMismatch("type index \(index.rawValue) names another type index")
            }
            return type
        }

        private func nested(_ context: String, _ body: () throws -> Void) throws {
            try ComponentTypeMismatch.within(context, body)
        }

        private func mismatch(_ expected: ComponentDefValType, _ provided: ComponentDefValType) -> ComponentTypeMismatch {
            ComponentTypeMismatch("expected \(Self.describe(expected)), found \(Self.describe(provided))")
        }

        static func describe(_ type: ComponentDefValType) -> String {
            switch type {
            case .inlined(.primitive(let type)):
                switch type {
                case .bool: return "bool"
                case .s8: return "s8"
                case .s16: return "s16"
                case .s32: return "s32"
                case .s64: return "s64"
                case .u8: return "u8"
                case .u16: return "u16"
                case .u32: return "u32"
                case .u64: return "u64"
                case .float32: return "f32"
                case .float64: return "f64"
                case .char: return "char"
                case .string: return "string"
                case .errorContext: return "error-context"
                }
            case .inlined(.index): return "type"
            case .list: return "list"
            case .tuple: return "tuple"
            case .option: return "option"
            case .result: return "result"
            case .future: return "future"
            case .stream: return "stream"
            case .record: return "record"
            case .flags: return "flags"
            case .enum: return "enum"
            case .variant: return "variant"
            case .resource: return "resource"
            case .own: return "own"
            case .borrow: return "borrow"
            }
        }
    }

    // MARK: - Values

    /// Checks that an imported value is a value of the type its import declares, whose indices
    /// resolve with `resolve`.
    struct ComponentValueChecker {
        let resolve: ComponentTypeMatcher.Resolve

        /// As for types, a malformed binary's type indices could form a cycle.
        private static let maxDepth = 100

        func check(_ value: ComponentValue, _ type: ComponentDefValType) throws {
            try check(value, type, depth: 0)
        }

        private func check(_ value: ComponentValue, _ type: ComponentValType?, depth: Int, what: String) throws {
            switch (type, value) {
            case (nil, .tuple(let elements)) where elements.isEmpty: break
            case (nil, _): throw ComponentTypeMismatch("expected no \(what) payload, found one")
            case (.some(let type), _): try check(value, .inlined(type), depth: depth + 1)
            }
        }

        private func check(_ value: ComponentValue, _ type: ComponentDefValType, depth: Int) throws {
            guard depth < Self.maxDepth else {
                throw ComponentTypeMismatch("type indices nest too deeply or form a cycle")
            }
            let type = try ComponentTypeMatcher.resolve(type, in: resolve)
            switch (value, type) {
            case (.bool, .inlined(.primitive(.bool))), (.s8, .inlined(.primitive(.s8))), (.s16, .inlined(.primitive(.s16))),
                (.s32, .inlined(.primitive(.s32))), (.s64, .inlined(.primitive(.s64))), (.u8, .inlined(.primitive(.u8))),
                (.u16, .inlined(.primitive(.u16))), (.u32, .inlined(.primitive(.u32))), (.u64, .inlined(.primitive(.u64))),
                (.float32, .inlined(.primitive(.float32))), (.float64, .inlined(.primitive(.float64))),
                (.char, .inlined(.primitive(.char))), (.string, .inlined(.primitive(.string))):
                break

            case (.list(let values), .list(let element)):
                for (index, value) in values.enumerated() {
                    try ComponentTypeMismatch.within("type mismatch in list element \(index)") {
                        try check(value, .inlined(element), depth: depth + 1)
                    }
                }

            case (.tuple(let values), .tuple(let types)):
                guard values.count == types.count else {
                    throw ComponentTypeMismatch("expected \(types.count) types, found \(values.count)")
                }
                for (index, (value, type)) in zip(values, types).enumerated() {
                    try ComponentTypeMismatch.within("type mismatch in tuple field \(index)") {
                        try check(value, .inlined(type), depth: depth + 1)
                    }
                }

            case (.record(let fields), .record(let types)):
                guard fields.count == types.count else {
                    throw ComponentTypeMismatch("expected \(types.count) fields, found \(fields.count)")
                }
                for (field, type) in zip(fields, types) {
                    guard field.name == type.name else {
                        throw ComponentTypeMismatch("expected field name `\(type.name)`, found `\(field.name)`")
                    }
                    try ComponentTypeMismatch.within("type mismatch in record field `\(type.name)`") {
                        try check(field.value, .inlined(type.type), depth: depth + 1)
                    }
                }

            case (.variant(let name, let payload), .variant(let cases)):
                guard let declared = cases.first(where: { $0.name == name }) else {
                    throw ComponentTypeMismatch("no variant case named `\(name)`")
                }
                switch (declared.type, payload) {
                case (nil, nil): break
                case (nil, .some): throw ComponentTypeMismatch("expected case `\(name)` to have no payload")
                case (.some, nil): throw ComponentTypeMismatch("expected case `\(name)` to have a payload, found none")
                case (.some(let type), .some(let payload)):
                    try ComponentTypeMismatch.within("type mismatch in variant case `\(name)`") {
                        try check(payload, .inlined(type), depth: depth + 1)
                    }
                }

            case (.flags(let names), .flags(let declared)):
                if let name = names.subtracting(declared).sorted().first {
                    throw ComponentTypeMismatch("no flag named `\(name)`")
                }

            case (.enum(let name), .enum(let cases)):
                guard cases.contains(name) else { throw ComponentTypeMismatch("no enum case named `\(name)`") }

            case (.option(let payload), .option(let type)):
                if let payload {
                    try ComponentTypeMismatch.within("type mismatch in option") {
                        try check(payload, .inlined(type), depth: depth + 1)
                    }
                }

            // A value with `error` set is the `err` case, as for lowering.
            case (.result(_, let error?), .result(_, let errorType)):
                try ComponentTypeMismatch.within("type mismatch in err variant") {
                    try check(error, errorType, depth: depth, what: "err")
                }
            case (.result(let ok, nil), .result(let okType, _)):
                switch (ok, okType) {
                case (nil, nil), (nil, .some): break
                case (.some(let ok), _):
                    try ComponentTypeMismatch.within("type mismatch in ok variant") {
                        try check(ok, okType, depth: depth, what: "ok")
                    }
                }

            case (.own(let resource), .own(let index)), (.borrow(let resource), .borrow(let index)):
                guard case .resource(let type) = try resolve(index) else {
                    throw ComponentTypeMismatch("handle type does not refer to a resource")
                }
                guard resource.type === type else { throw ComponentTypeMismatch("resource types are not the same") }

            default:
                throw ComponentTypeMismatch("expected \(ComponentTypeMatcher.describe(type)), found \(Self.describe(value))")
            }
        }

        private static func describe(_ value: ComponentValue) -> String {
            switch value {
            case .bool: return "bool"
            case .s8: return "s8"
            case .s16: return "s16"
            case .s32: return "s32"
            case .s64: return "s64"
            case .u8: return "u8"
            case .u16: return "u16"
            case .u32: return "u32"
            case .u64: return "u64"
            case .float32: return "f32"
            case .float64: return "f64"
            case .char: return "char"
            case .string: return "string"
            case .list: return "list"
            case .record: return "record"
            case .variant: return "variant"
            case .tuple: return "tuple"
            case .flags: return "flags"
            case .enum: return "enum"
            case .option: return "option"
            case .result: return "result"
            case .own: return "own"
            case .borrow: return "borrow"
            }
        }
    }

#endif

#if ComponentModel
    import WasmTypes

    // MARK: - Core module types

    /// Checks that a module has the type a component declares for it, as wasmtime's linker does,
    /// with its messages: the module exports at least what the type declares, each a subtype of
    /// the declared one, and imports at most what the type declares, each a supertype.
    ///
    /// Function types compare by equality, with any concrete reference types in them compared by
    /// their index in each type section.
    struct CoreModuleTypeMatcher {
        let module: Module

        /// An import's or export's type, with function types resolved. A function type is `nil`
        /// where the matcher does not know it, from an outer alias, and is then not checked.
        enum ExternType {
            case function(FunctionType?)
            case table(TableType)
            case memory(MemoryType)
            case global(GlobalType)
            case tag(FunctionType?)

            var kind: String {
                switch self {
                case .function: return "func"
                case .table: return "table"
                case .memory: return "memory"
                case .global: return "global"
                case .tag: return "tag"
                }
            }
        }

        func match(_ declared: CoreModuleType) throws {
            // The module type's own type index space.
            var types: [FunctionType?] = []
            var declaredImports: [String: [String: ImportDescriptor]] = [:]
            var declaredExports: [(name: String, descriptor: ImportDescriptor)] = []
            for declaration in declared.declarations {
                switch declaration {
                case .type(.function(let type)): types.append(type)
                case .type(.module): types.append(nil)
                // An outer alias names a type of the enclosing component, which is not resolved.
                case .alias: types.append(nil)
                case .import(let entry): declaredImports[entry.module, default: [:]][entry.name] = entry.descriptor
                case .exportDecl(let name, let descriptor): declaredExports.append((name, descriptor))
                }
            }
            func declaredType(_ descriptor: ImportDescriptor) -> ExternType {
                Self.externType(descriptor) { types.indices.contains(Int($0)) ? types[Int($0)] : nil }
            }

            for export in declaredExports {
                guard let provided = module.exports.first(where: { $0.name == export.name }) else {
                    throw ComponentTypeMismatch("module export `\(export.name)` not defined")
                }
                let expected = declaredType(export.descriptor)
                let found = try externType(of: provided.descriptor)
                guard expected.kind == found.kind else {
                    throw ComponentTypeMismatch("expected \(expected.kind) found \(found.kind)")
                }
                if let detail = Self.mismatch(found, isSubtypeOf: expected) {
                    throw ComponentTypeMismatch("export `\(export.name)` has the wrong type: \(detail)")
                }
            }

            for entry in module.imports {
                guard let descriptor = declaredImports[entry.module]?[entry.name] else {
                    throw ComponentTypeMismatch("module import `\(entry.module)::\(entry.name)` not defined")
                }
                let required = Self.externType(entry.descriptor) { try? module.types.functionType(at: $0) }
                let given = declaredType(descriptor)
                guard required.kind == given.kind else {
                    throw ComponentTypeMismatch("expected \(required.kind) found \(given.kind)")
                }
                // What the component gives must be a subtype of what the module needs.
                if let detail = Self.mismatch(given, isSubtypeOf: required) {
                    throw ComponentTypeMismatch("module import `\(entry.module)::\(entry.name)` has the wrong type: \(detail)")
                }
            }
        }

        private static func externType(
            _ descriptor: ImportDescriptor, functionType: (TypeIndex) -> FunctionType?
        ) -> ExternType {
            switch descriptor {
            case .function(let index): return .function(functionType(index))
            case .table(let type): return .table(type)
            case .memory(let type): return .memory(type)
            case .global(let type): return .global(type)
            case .tag(let index): return .tag(functionType(index))
            }
        }

        /// The type of what the module exports.
        private func externType(of descriptor: ExportDescriptor) throws -> ExternType {
            func element<T>(_ array: [T], _ index: UInt32) throws -> T {
                guard array.indices.contains(Int(index)) else {
                    throw ComponentTypeMismatch("module export index \(index) out of range")
                }
                return array[Int(index)]
            }
            switch descriptor {
            case .function(let index):
                return .function(try? module.resolveFunctionType(index))
            case .table(let index):
                return .table(try element(module.tableTypes, index))
            case .memory(let index):
                return .memory(try element(module.memoryTypes, index))
            case .global(let index):
                let imported = module.imports.compactMap { entry -> GlobalType? in
                    guard case .global(let type) = entry.descriptor else { return nil }
                    return type
                }
                return .global(try element(imported + module.globals.map(\.type), index))
            case .tag(let index):
                return .tag(try? module.types.functionType(at: try element(module.tagTypes, index)))
            }
        }

        /// Why `sub` is not a subtype of `sup`, which has the same kind, or `nil` if it is.
        private static func mismatch(_ sub: ExternType, isSubtypeOf sup: ExternType) -> String? {
            switch (sub, sup) {
            case (.function(let subType), .function(let supType)), (.tag(let subType), .tag(let supType)):
                guard let subType, let supType, subType != supType else { return nil }
                return "expected type `\(describe(supType))`, found type `\(describe(subType))`"
            case (.table(let subType), .table(let supType)):
                guard subType.elementType == supType.elementType else {
                    return "expected \(supType.elementType) elements, found \(subType.elementType)"
                }
                return limitsMismatch(
                    subMin: subType.limits.min, subMax: subType.limits.max, supMin: supType.limits.min, supMax: supType.limits.max)
            case (.memory(let subType), .memory(let supType)):
                guard subType.shared == supType.shared, subType.isMemory64 == supType.isMemory64 else {
                    return "the memories differ in whether they are shared or 64-bit"
                }
                return limitsMismatch(subMin: subType.min, subMax: subType.max, supMin: supType.min, supMax: supType.max)
            case (.global(let subType), .global(let supType)):
                guard subType.mutability != supType.mutability || subType.valueType != supType.valueType else { return nil }
                return "expected global \(supType), found \(subType)"
            default:
                return "expected \(sup.kind) found \(sub.kind)"
            }
        }

        /// Why limits `sub` do not fit in `sup`, at least its minimum and at most its maximum.
        private static func limitsMismatch(subMin: UInt64, subMax: UInt64?, supMin: UInt64, supMax: UInt64?) -> String? {
            guard subMin >= supMin else { return "expected a minimum of at least \(supMin), found \(subMin)" }
            if let supMax {
                guard let subMax else { return "expected a maximum of at most \(supMax), found none" }
                guard subMax <= supMax else { return "expected a maximum of at most \(supMax), found \(subMax)" }
            }
            return nil
        }

        private static func describe(_ type: FunctionType) -> String {
            var text = "(func"
            if !type.parameters.isEmpty { text += " (param \(type.parameters.map(describe).joined(separator: " ")))" }
            if !type.results.isEmpty { text += " (result \(type.results.map(describe).joined(separator: " ")))" }
            return text + ")"
        }

        private static func describe(_ type: ValueType) -> String {
            switch type {
            case .i32: return "i32"
            case .i64: return "i64"
            case .f32: return "f32"
            case .f64: return "f64"
            case .v128: return "v128"
            case .ref(let reference): return "\(reference)"
            }
        }
    }
#endif
