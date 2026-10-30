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
            let expected = try resolve(expected, in: self.expected)
            let provided = try resolve(provided, in: self.provided)
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
        private func resolve(_ type: ComponentDefValType, in resolve: Resolve) throws -> ComponentDefValType {
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
            do {
                try body()
            } catch let mismatch as ComponentTypeMismatch {
                throw mismatch.within(context)
            }
        }

        private func mismatch(_ expected: ComponentDefValType, _ provided: ComponentDefValType) -> ComponentTypeMismatch {
            ComponentTypeMismatch("expected \(Self.describe(expected)), found \(Self.describe(provided))")
        }

        private static func describe(_ type: ComponentDefValType) -> String {
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

#endif
