// Resource types and handles, following `CanonicalABI.md`'s `ResourceHandle`, `Table`,
// `lift_own`/`lift_borrow`/`lower_own`/`lower_borrow` and the `resource.new`, `resource.drop` and
// `resource.rep` built-ins:
// https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md
//
// The trap messages follow wasmtime's, which the component model test suite checks for.

#if ComponentModel
    import ComponentModel
    import WasmParser

    // MARK: - Type index space

    /// What a component instance's type indices name once it is instantiated.
    ///
    /// Resource types only exist at runtime, as each instantiation of a component defining one
    /// creates a new type, so type indices resolve against the instance rather than its binary.
    /// A type brought in from another instance, by an alias, import or export, is copied in
    /// with the type indices inside it rewritten to point at copies of what they named there.
    final class ComponentTypeSpace {
        enum Entry {
            case value(ComponentDefValType)
            case function(ComponentFuncType)
            case instance(InstanceTypeDecl)
            case component(ComponentTypeDecl)
            case resource(ComponentResourceType)
            /// A type the loader keeps no definition of, such as an instance type from another
            /// component, whose declarations resolve against scopes that are gone.
            case opaque
        }

        /// The entries the component's definitions give, at their binary indices.
        private(set) var entries: [Entry] = []

        /// Copies of types other spaces' entries refer to, at `syntheticBase` and up, so that
        /// they never take an index one of the component's own definitions will.
        private var synthetic: [Entry] = []
        private static let syntheticBase = 1 << 31

        var count: Int { entries.count }

        func append(_ entry: Entry) {
            entries.append(entry)
        }

        /// Appends a type that `space` defines, copying it over if `space` is not this one.
        func append(_ entry: Entry, from space: ComponentTypeSpace) throws {
            entries.append(try localize(entry, from: space))
        }

        func entry(_ index: ComponentTypeIndex) throws -> Entry {
            let index = Int(index.rawValue)
            if index >= Self.syntheticBase, synthetic.indices.contains(index - Self.syntheticBase) {
                return synthetic[index - Self.syntheticBase]
            }
            guard entries.indices.contains(index) else {
                throw CanonicalABIError(description: "type index \(index) out of bounds (have \(entries.count) types)")
            }
            return entries[index]
        }

        func valueType(_ index: ComponentTypeIndex) throws -> ComponentDefValType {
            guard case .value(let type) = try entry(index) else {
                throw CanonicalABIError(description: "type index \(index.rawValue) is not a defined value type")
            }
            return type
        }

        func resourceType(_ index: ComponentTypeIndex) throws -> ComponentResourceType {
            guard case .resource(let type) = try entry(index) else {
                throw CanonicalABIError(description: "type index \(index.rawValue) is not a resource type")
            }
            return type
        }

        func functionType(_ index: ComponentTypeIndex) throws -> ComponentFuncType {
            guard case .function(let type) = try entry(index) else {
                throw CanonicalABIError(description: "type index \(index.rawValue) is not a function type")
            }
            return type
        }

        // MARK: Copying types between spaces

        /// `entry`, from `space`, with its type indices made to resolve against this space.
        func localize(_ entry: Entry, from space: ComponentTypeSpace) throws -> Entry {
            if space === self { return entry }
            var copier = Copier(source: space, target: self)
            return try copier.copy(entry, depth: 0)
        }

        private struct Copier {
            let source: ComponentTypeSpace
            let target: ComponentTypeSpace
            /// Source indices already copied, so that a type referred to twice is copied once.
            var copied: [UInt32: ComponentTypeIndex] = [:]

            /// Types do not refer to themselves, but a malformed binary's indices could.
            static let maxDepth = 100

            mutating func copy(_ entry: Entry, depth: Int) throws -> Entry {
                switch entry {
                case .value(let type): return .value(try copy(type, depth: depth))
                case .function(let type):
                    return .function(
                        ComponentFuncType(
                            params: try type.params.map {
                                ComponentFuncType.Param(name: $0.name, type: try copy($0.type, depth: depth))
                            },
                            result: try type.result.map { try copy($0, depth: depth) }))
                case .resource, .opaque: return entry
                // Their declarations resolve against nested scopes, which a copy cannot follow.
                case .instance, .component: return .opaque
                }
            }

            mutating func copy(_ index: ComponentTypeIndex, depth: Int) throws -> ComponentTypeIndex {
                if let copy = copied[index.rawValue] { return copy }
                guard depth < Self.maxDepth else {
                    throw CanonicalABIError(description: "type indices nest too deeply or form a cycle")
                }
                let entry = try copy(try source.entry(index), depth: depth + 1)
                target.synthetic.append(entry)
                let copy = ComponentTypeIndex(rawValue: ComponentTypeSpace.syntheticBase + target.synthetic.count - 1)
                copied[index.rawValue] = copy
                return copy
            }

            mutating func copy(_ type: ComponentValType, depth: Int) throws -> ComponentValType {
                switch type {
                case .primitive: return type
                case .index(let index): return .index(try copy(index, depth: depth))
                }
            }

            mutating func copy(_ type: ComponentValType?, depth: Int) throws -> ComponentValType? {
                try type.map { try copy($0, depth: depth) }
            }

            mutating func copy(_ type: ComponentDefValType, depth: Int) throws -> ComponentDefValType {
                switch type {
                case .inlined(let type): return .inlined(try copy(type, depth: depth))
                case .list(let element): return .list(try copy(element, depth: depth))
                case .tuple(let elements): return .tuple(try elements.map { try copy($0, depth: depth) })
                case .option(let some): return .option(try copy(some, depth: depth))
                case .result(let ok, let error):
                    return .result(ok: try copy(ok, depth: depth), error: try copy(error, depth: depth))
                case .future(let element): return .future(try copy(element, depth: depth))
                case .stream(let element, let end):
                    return .stream(element: try copy(element, depth: depth), end: try copy(end, depth: depth))
                case .record(let fields):
                    return .record(
                        try fields.map { ComponentRecordField(name: $0.name, type: try copy($0.type, depth: depth)) })
                case .variant(let cases):
                    return .variant(
                        try cases.map { ComponentCaseField(name: $0.name, type: try copy($0.type, depth: depth)) })
                case .flags, .enum, .resource: return type
                case .own(let index): return .own(try copy(index, depth: depth))
                case .borrow(let index): return .borrow(try copy(index, depth: depth))
                }
            }
        }
    }

    // MARK: - Handles

    /// A handle in a component instance's table: `ResourceHandle` in the spec.
    final class ResourceHandle {
        let type: ComponentResourceType
        let rep: UInt32
        /// Whether the handle owns the resource, rather than borrowing it.
        let isOwn: Bool
        /// The call a borrow was lent to, which must drop it before returning.
        let scope: CallScope?
        /// How many calls in progress this handle is lent to. It cannot be removed while any.
        var lendCount = 0

        init(type: ComponentResourceType, rep: UInt32, isOwn: Bool, scope: CallScope? = nil) {
            self.type = type
            self.rep = rep
            self.isOwn = isOwn
            self.scope = scope
        }
    }

    /// The borrows lowered into one call of a lifted function: `Task.num_borrows` in the spec.
    final class CallScope {
        var borrowCount = 0
    }

    /// A component instance's handle table: `Table` in the spec.
    ///
    /// Index 0 is never valid, and a freed index is reused before the table grows, the most
    /// recently freed first.
    struct HandleTable {
        enum Element {
            case handle(ResourceHandle)
            /// The thread running a call into the instance, which the spec keeps in the same
            /// table, so a handle created during a call never takes the thread's index.
            case thread
        }

        /// The spec's `Table.MAX_LENGTH`.
        static let maxLength = (1 << 28) - 1

        private var elements: [Element?] = [nil]
        private var free: [Int] = []

        mutating func add(_ element: Element) throws -> UInt32 {
            if let index = free.popLast() {
                elements[index] = element
                return UInt32(index)
            }
            guard elements.count < Self.maxLength else {
                throw CanonicalABIError(description: "too many handles in one component instance")
            }
            elements.append(element)
            return UInt32(elements.count - 1)
        }

        func get(_ index: UInt32) throws -> Element {
            guard let element = elements.indices.contains(Int(index)) ? elements[Int(index)] : nil else {
                throw CanonicalABIError(description: "unknown handle index \(index)")
            }
            return element
        }

        mutating func remove(_ index: UInt32) throws -> Element {
            let element = try get(index)
            elements[Int(index)] = nil
            free.append(Int(index))
            return element
        }
    }

    // MARK: - Component instance state

    /// The runtime state of one component instance that the canonical ABI reads and changes:
    /// `ComponentInstance` in the spec.
    ///
    /// Each `canon` definition captures the state of the instance it appears in, as the spec's
    /// `cx.inst`: lifting and lowering move handles in and out of that instance's table.
    final class ComponentInstanceState {
        var table = HandleTable()

        /// Whether a call into the instance is in progress. The spec traps rather than enter an
        /// instance already on the stack (`Task.trap_if_on_the_stack`).
        private(set) var isEntered = false

        /// The spec's `may_leave`: false while the runtime lowers values into the instance's
        /// memory, with its `realloc`, and while its post-return function runs. Calling out
        /// of the instance then traps.
        private(set) var mayLeave = true

        /// Traps if the instance may not call out of itself now.
        func checkMayLeave() throws {
            guard mayLeave else {
                throw CanonicalABIError(description: "cannot leave component instance")
            }
        }

        /// Runs `body` with calls out of the instance forbidden.
        func withoutLeaving<R>(_ body: () throws -> R) throws -> R {
            let previous = mayLeave
            mayLeave = false
            defer { mayLeave = previous }
            return try body()
        }

        /// The handle at `index`, which must be one to a resource of `type`.
        func handle(_ index: UInt32, of type: ComponentResourceType) throws -> ResourceHandle {
            try Self.check(table.get(index), index: index, type: type)
        }

        /// Removes the handle at `index`, which must be one to a resource of `type`.
        func removeHandle(_ index: UInt32, of type: ComponentResourceType) throws -> ResourceHandle {
            // Checked before removing, so that a trap leaves the table as it was.
            let handle = try handle(index, of: type)
            guard handle.lendCount == 0 else {
                throw CanonicalABIError(description: "cannot remove owned resource while borrowed")
            }
            _ = try table.remove(index)
            return handle
        }

        private static func check(
            _ element: HandleTable.Element, index: UInt32, type: ComponentResourceType
        ) throws -> ResourceHandle {
            guard case .handle(let handle) = element else {
                throw CanonicalABIError(description: "index \(index) is not a resource")
            }
            guard handle.type === type else {
                func kind(_ type: ComponentResourceType) -> String {
                    type.isHostDefined ? "host-defined resource" : "guest-defined resource"
                }
                let found = type.isHostDefined == handle.type.isHostDefined ? "a different \(kind(handle.type))" : kind(handle.type)
                throw CanonicalABIError(
                    description: "handle index \(index) used with the wrong type, expected \(kind(type)) but found \(found)")
            }
            return handle
        }

        // MARK: Lifting and lowering

        /// `lift_own`: moves the owning handle at `index` out of the table.
        func liftOwn(_ index: UInt32, of type: ComponentResourceType) throws -> UInt32 {
            let handle = try self.handle(index, of: type)
            guard handle.isOwn else {
                throw CanonicalABIError(description: "handle index \(index) is a borrow, where an owning handle was expected")
            }
            return try removeHandle(index, of: type).rep
        }

        /// `lift_borrow`: lends the handle at `index` to a call, recording it in `lenders` so
        /// that the call's end can return it.
        func liftBorrow(_ index: UInt32, of type: ComponentResourceType, lenders: inout [ResourceHandle]) throws -> UInt32 {
            let handle = try self.handle(index, of: type)
            handle.lendCount += 1
            lenders.append(handle)
            return handle.rep
        }

        /// `lower_own`: a new owning handle in the table.
        func lowerOwn(_ rep: UInt32, of type: ComponentResourceType) throws -> UInt32 {
            try table.add(.handle(ResourceHandle(type: type, rep: rep, isOwn: true)))
        }

        /// `lower_borrow`: the representation itself, for the instance that defined `type`, or
        /// a borrow that the call `scope` must drop before it returns.
        func lowerBorrow(_ rep: UInt32, of type: ComponentResourceType, scope: CallScope?) throws -> UInt32 {
            if type.implementation === self {
                return rep
            }
            guard let scope else {
                throw CanonicalABIError(description: "a borrow can only be passed into a call")
            }
            let index = try table.add(.handle(ResourceHandle(type: type, rep: rep, isOwn: false, scope: scope)))
            scope.borrowCount += 1
            return index
        }

        // MARK: Built-ins

        /// `resource.new`.
        func resourceNew(_ type: ComponentResourceType, rep: UInt32) throws -> UInt32 {
            try checkMayLeave()
            return try lowerOwn(rep, of: type)
        }

        /// `resource.drop`: removes the handle, and runs the destructor if it owned the resource.
        func resourceDrop(_ type: ComponentResourceType, index: UInt32) throws {
            try checkMayLeave()
            let handle = try removeHandle(index, of: type)
            if handle.isOwn {
                try Self.destroy(type, rep: handle.rep, from: self)
            } else {
                handle.scope?.borrowCount -= 1
            }
        }

        /// Runs the destructor of a resource of `type` that `caller`, or the host if `nil`,
        /// dropped the last owning handle to. Another instance's destructor runs as a call into
        /// it, which traps if that instance is on the stack, even if it has no destructor.
        static func destroy(_ type: ComponentResourceType, rep: UInt32, from caller: ComponentInstanceState?) throws {
            guard let implementation = type.implementation as? ComponentInstanceState, implementation !== caller else {
                try type.destructor?(rep)
                return
            }
            try implementation.enterCall { _ in try type.destructor?(rep) }
        }

        /// `resource.rep`.
        func resourceRep(_ type: ComponentResourceType, index: UInt32) throws -> UInt32 {
            try handle(index, of: type).rep
        }

        // MARK: Calls

        /// Runs `body` as a call into this instance: the spec's `Task`, which holds a thread
        /// in the table for the call's duration and requires every borrow lent to the call to
        /// be dropped by its end.
        func enterCall<R>(_ body: (CallScope) throws -> R) throws -> R {
            guard !isEntered else {
                throw CanonicalABIError(description: "cannot enter component instance")
            }
            isEntered = true
            defer { isEntered = false }
            let threadIndex = try table.add(.thread)
            defer { _ = try? table.remove(threadIndex) }
            let scope = CallScope()
            let result = try body(scope)
            guard scope.borrowCount == 0 else {
                throw CanonicalABIError(description: "borrow handles still remain at the end of the call")
            }
            return result
        }
    }

    extension ComponentResource {
        /// Drops a resource the host owns, running its type's destructor.
        ///
        /// Call this once for each owned resource the host received from a component and keeps,
        /// such as a constructor's result: otherwise a guest-defined resource is never destroyed.
        /// Do not use the resource after, nor drop one the host passed on to a component, as that
        /// gave the component the ownership.
        ///
        /// - Throws: A trap if the destructor traps, or if the component that defines the type is
        ///   in a call already, such as when a host function it called drops the resource.
        public func drop() throws {
            try ComponentInstanceState.destroy(type, rep: rep, from: nil)
        }
    }

#endif
