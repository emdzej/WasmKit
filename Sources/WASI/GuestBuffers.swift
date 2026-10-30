import WasmTypes

/// A vector of guest buffers (WASI iovecs), resolved against guest memory on
/// demand.
///
/// File implementations receive this instead of a `GuestMemory` so that
/// ``WASIFile`` stays free of generic requirements. Embedded Swift forbids a
/// protocol used as an existential from carrying generic methods, and
/// ``FdEntry`` stores files as `any WASIFile`, so the concrete memory type is
/// erased here -- at the WASI call boundary, where it is still statically
/// known -- rather than threaded through the file protocol.
///
/// ``transfer(_:)`` resolves each buffer inside its own guest-memory access
/// scope, one at a time. ``transferBatches(batchSize:_:)`` resolves a batch of
/// them in one scope, for a single `readv`/`writev` call.
@_spi(WASIPlatform) public struct GuestBuffers {
    /// The number of buffers in the vector.
    public let count: Int

    private let access: (Int, (UnsafeMutableRawBufferPointer) throws -> Int) throws -> Int
    private let accessBatch: (Range<Int>, ([UnsafeMutableRawBufferPointer]) throws -> Int) throws -> Int

    init<M: GuestMemory>(iovs: UnsafeGuestBufferPointer<WASIAbi.IOVec>, memory: M) {
        self.count = Int(iovs.count)
        self.access = { index, body in
            let iovec = try iovs.read(at: UInt32(index), in: memory)
            return try iovec.withHostBufferPointer(in: memory) { try body($0) }
        }
        // Guest-memory access scopes do not nest, so a batch is one scope over the span from
        // its lowest buffer to the end of its highest. If each buffer is in bounds, so is that.
        self.accessBatch = { range, body in
            var iovecs: [WASIAbi.IOVec] = []
            iovecs.reserveCapacity(range.count)
            for index in range {
                iovecs.append(try iovs.read(at: UInt32(index), in: memory))
            }
            guard let lowest = iovecs.map(\.buffer.offset).min() else { return try body([]) }
            let end = iovecs.map { UInt64($0.buffer.offset) + UInt64($0.length) }.max()!
            // Wider than a 32-bit host's address space: no memory there is that large.
            guard let span = Int(exactly: end - UInt64(lowest)) else {
                throw GuestMemoryError(offset: UInt64(lowest), count: end - UInt64(lowest))
            }
            return try UnsafeGuestRawPointer(offset: lowest).withHostPointer(in: memory, count: span) { base in
                try body(
                    iovecs.map {
                        let start = Int($0.buffer.offset - lowest)
                        return UnsafeMutableRawBufferPointer(rebasing: base[start..<(start + Int($0.length))])
                    })
            }
        }
    }

    /// Calls `body` with the host buffer backing the buffer at `index`.
    ///
    /// - Parameter body: Returns the number of bytes it transferred.
    /// - Returns: Whatever `body` returned.
    /// Runs vectored I/O over the buffers in order, with the result `readv` and `writev` give.
    ///
    /// - Stops after a buffer that `body` did not fill completely, as the next buffer would
    ///   otherwise block or leave a gap.
    /// - Once some bytes have moved, an error from a later buffer ends the transfer instead of
    ///   discarding the count.
    /// - The total never exceeds `UInt32.max`, the largest count the ABI can return: a buffer
    ///   that would cross it is shortened.
    ///
    /// - Parameter body: Transfers bytes for one buffer and returns how many it moved.
    /// - Returns: The total number of bytes transferred.
    public func transfer(_ body: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> UInt32 {
        var total: UInt32 = 0
        for index in 0..<count where total < .max {
            let remaining = Int(UInt32.max - total)
            do {
                var requested = 0
                let transferred = try access(index) { buffer in
                    let limited = UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(remaining))
                    requested = limited.count
                    return try body(limited)
                }
                total += UInt32(transferred)
                guard transferred == requested else { break }
            } catch {
                guard total == 0 else { break }
                throw error
            }
        }
        return total
    }

    /// Runs vectored I/O over the buffers in batches of up to `batchSize`, with `transfer`'s
    /// results: `body` moves bytes for a batch, as `readv` or `writev` would, and returns how
    /// many it moved.
    public func transferBatches(
        batchSize: Int = 64, _ body: ([UnsafeMutableRawBufferPointer]) throws -> Int
    ) throws -> UInt32 {
        var total: UInt32 = 0
        var start = 0
        while start < count, total < .max {
            let end = min(count, start + batchSize)
            do {
                var requested = 0
                let transferred = try accessBatch(start..<end) { buffers in
                    // Shortened so that the total cannot pass `UInt32.max`.
                    var limit = Int(UInt32.max - total)
                    let batch = buffers.map { buffer in
                        let limited = UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(limit))
                        limit -= limited.count
                        return limited
                    }
                    requested = batch.reduce(0) { $0 + $1.count }
                    return try body(batch)
                }
                total += UInt32(transferred)
                guard transferred == requested else { break }
            } catch {
                guard total == 0 else { break }
                throw error
            }
            start = end
        }
        return total
    }

    @discardableResult
    public func withHostBuffer(
        at index: Int,
        _ body: (UnsafeMutableRawBufferPointer) throws -> Int
    ) throws -> Int {
        try access(index, body)
    }
}
