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
/// Each buffer is resolved inside its own guest-memory access scope, one at a
/// time, matching how vectored I/O was performed before the erasure existed.
@_spi(WASIPlatform) public struct GuestBuffers {
    /// The number of buffers in the vector.
    public let count: Int

    private let access: (Int, (UnsafeMutableRawBufferPointer) throws -> Int) throws -> Int

    init<M: GuestMemory>(iovs: UnsafeGuestBufferPointer<WASIAbi.IOVec>, memory: M) {
        self.count = Int(iovs.count)
        self.access = { index, body in
            let iovec = try iovs.read(at: UInt32(index), in: memory)
            return try iovec.withHostBufferPointer(in: memory) { try body($0) }
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

    @discardableResult
    public func withHostBuffer(
        at index: Int,
        _ body: (UnsafeMutableRawBufferPointer) throws -> Int
    ) throws -> Int {
        try access(index, body)
    }
}
