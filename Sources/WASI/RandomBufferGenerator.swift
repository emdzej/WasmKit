import SwiftShims  // For swift_stdlib_random

/// A type that provides random bytes.
///
/// This type is similar to `RandomNumberGenerator` in Swift standard library,
/// but it provides a way to fill a buffer with random bytes instead of a single
/// random number.
public protocol RandomBufferGenerator: Sendable {

    /// Fills the buffer with random bytes.
    ///
    /// - Parameter buffer: The destination buffer to fill with random bytes.
    /// - Throws: A `WASIAbi.Errno` to return to the guest from `random_get`, such as `ENOSYS`
    ///   when there is no source of entropy. Any other error traps.
    mutating func fill(buffer: UnsafeMutableBufferPointer<UInt8>) throws
}

extension RandomBufferGenerator where Self: RandomNumberGenerator {
    public mutating func fill(buffer: UnsafeMutableBufferPointer<UInt8>) {
        // The buffer is filled with 8 bytes at once.
        let count = buffer.count / 8
        for i in 0..<count {
            let random = self.next()
            withUnsafeBytes(of: random) { randomBytes in
                let startOffset = i * 8
                let destination = UnsafeMutableBufferPointer(rebasing: buffer[startOffset..<(startOffset + 8)])
                UnsafeMutableRawBufferPointer(destination).copyMemory(from: randomBytes)
            }
        }

        // If the buffer size is not a multiple of 8, fill the remaining bytes.
        let remaining = buffer.count % 8
        if remaining > 0 {
            let random = self.next()
            withUnsafeBytes(of: random) { randomBytes in
                let startOffset = count * 8
                let destination = UnsafeMutableBufferPointer(rebasing: buffer[startOffset..<(startOffset + remaining)])
                UnsafeMutableRawBufferPointer(destination).copyMemory(
                    from: UnsafeRawBufferPointer(start: randomBytes.baseAddress, count: remaining)
                )
            }
        }
    }
}

extension SystemRandomNumberGenerator: RandomBufferGenerator {
    public mutating func fill(buffer: UnsafeMutableBufferPointer<UInt8>) throws {
        guard let baseAddress = buffer.baseAddress else { return }
        #if $Embedded
            // Bare-metal targets have no `swift_stdlib_random`, and
            // `SystemRandomNumberGenerator.next()` bottoms out in the same
            // symbol, so there is nothing to fall back to. Refuse rather than
            // hand a guest predictable bytes it believes are random: the guest
            // gets `ENOSYS` from `random_get`.
            //
            // Supply a generator backed by the SoC's hardware RNG via
            // `WASIBridgeToHost.init` to give guests randomness.
            throw WASIAbi.Errno.ENOSYS
        #else
            // Directly call underlying C function of SystemRandomNumberGenerator
            swift_stdlib_random(baseAddress, Int(buffer.count))
        #endif
    }
}
