/// A namespace for the canonical lifting operations used by host side.
public enum CanonicalLifting {
    /// Lifts a pair of a pointer and a length to a Swift Array value with the given element type.
    ///
    /// - Parameters:
    ///   - pointer: A pointer to a guest memory region that contains the byte representation of the array value.
    ///   - length: A length of the array value.
    ///   - elementSize: A byte size of an element of the array value in lowered representation.
    ///   - loadElement: A closure that loads an element from the given pointer.
    ///   - memoryBase: A base address of the guest memory region. Can be `nil` if length is zero.
    /// - Returns: A lifted Swift Array value with the given element type.
    public static func liftList<Element>(
        pointer: UInt32, length: UInt32, elementSize: UInt32,
        loadElement: (UnsafeGuestRawPointer) throws -> Element,
        context: CanonicalCallContext
    ) throws -> [Element] {
        // The pointer and length come from the guest: check the whole list is inside the
        // memory before reserving room for it or loading any element.
        let byteLength = UInt64(length) * UInt64(elementSize)
        guard UInt64(pointer) + byteLength <= UInt64(context.guestMemory.byteCount) else {
            throw CanonicalABIError(description: "list of \(length) elements at \(pointer) is out of bounds")
        }
        var elements = [Element]()
        elements.reserveCapacity(Int(length))
        let guestPointer = UnsafeGuestRawPointer(offset: pointer)
        for i in 0..<length {
            let element = try loadElement(guestPointer.advanced(by: i &* elementSize))
            elements.append(element)
        }
        return elements
    }
}
