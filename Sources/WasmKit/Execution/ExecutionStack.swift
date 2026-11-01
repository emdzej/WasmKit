/// The stack a guest runs on.
///
/// Every call into a guest needs one. By default ``Function/invoke(_:)`` takes
/// one its store keeps for such calls, allocating one only if none is free,
/// such as for a call made while another is running.
///
/// An embedder can instead make one of these and hand it to
/// ``Function/invoke(_:on:)``.
public struct ExecutionStack: ~Copyable {
    let slots: UnsafeMutablePointer<StackSlot>
    let count: Int
    /// Where the slots go back to when the stack is done with, rather than being freed.
    private let pool: ExecutionStackPool?

    /// Allocates a stack of the size `engine` is configured for.
    ///
    /// Taking the engine rather than a size is deliberate: a stack shorter than
    /// the engine expects would be written past rather than reported, and the
    /// size that is right for an engine is already part of its configuration.
    public init(engine: Engine) {
        count = Self.slotCount(engine: engine)
        slots = Self.allocateSlots(count: count)
        pool = nil
    }

    /// A stack from `pool`, which goes back to it when done with.
    init(pool: ExecutionStackPool) {
        // Initialized through another `init` rather than property by property: with the
        // latter, optimized builds over-released `pool` here (Swift 6.4), and freed it.
        let count = pool.slotCount
        let slots = pool.take() ?? Self.allocateSlots(count: count)
        self.init(slots: slots, count: count, pool: pool)
    }

    private init(slots: UnsafeMutablePointer<StackSlot>, count: Int, pool: ExecutionStackPool?) {
        self.slots = slots
        self.count = count
        self.pool = pool
    }

    /// Zeroed, as a garbage collection scans every slot of a stack in use: see ``GCHeap``.
    static func allocateSlots(count: Int) -> UnsafeMutablePointer<StackSlot> {
        let slots = UnsafeMutablePointer<StackSlot>.allocate(capacity: count)
        slots.initialize(repeating: 0, count: count)
        return slots
    }

    static func slotCount(engine: Engine) -> Int {
        engine.configuration.stackSize / MemoryLayout<StackSlot>.stride
    }

    deinit {
        if let pool, pool.give(slots) { return }
        slots.deallocate()
    }
}

/// Stacks a store keeps for the calls it makes, so that a call does not allocate and free one,
/// which for a small function costs more than the call itself.
final class ExecutionStackPool: Sendable {
    let slotCount: Int
    /// Only one stack uses the slots at a time: they are in the pool or in that stack.
    private struct Slots: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<StackSlot>
    }
    private let free = PlatformMutex<[Slots]>([])
    /// Stacks beyond this many are freed. Calls nest only when a host function calls back in.
    private static let capacity = 2

    init(engine: Engine) {
        slotCount = ExecutionStack.slotCount(engine: engine)
    }

    func take() -> UnsafeMutablePointer<StackSlot>? {
        free.withLock { $0.popLast()?.pointer }
    }

    /// Keeps `slots` for a later call, or returns `false` if the pool is full.
    func give(_ slots: UnsafeMutablePointer<StackSlot>) -> Bool {
        free.withLock { free in
            guard free.count < Self.capacity else { return false }
            free.append(Slots(pointer: slots))
            return true
        }
    }

    deinit {
        free.withLock { free in
            for slots in free { slots.pointer.deallocate() }
        }
    }
}
