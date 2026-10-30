import WasmTypes

extension GuestPointee {
    static func readFromGuest<M: GuestMemory>(_ pointer: inout UnsafeGuestRawPointer, in memory: M) throws -> Self {
        pointer = pointer.alignedUp(toMultipleOf: Self.alignInGuest)
        let value = try readFromGuest(pointer, in: memory)
        pointer = pointer.advanced(by: sizeInGuest)
        return value
    }

    static func writeToGuest<M: GuestMemory>(at pointer: inout UnsafeGuestRawPointer, in memory: M, value: Self) throws {
        pointer = pointer.alignedUp(toMultipleOf: Self.alignInGuest)
        try writeToGuest(at: pointer, in: memory, value: value)
        pointer = pointer.advanced(by: sizeInGuest)
    }
}
