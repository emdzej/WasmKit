import Testing
import WasmTypes

@_spi(WASIPlatform) @testable import WASI

@Suite struct WASICapabilityTests {
    private typealias Capability = WASICapability<TestSupport.TestGuestMemory>

    /// The bridge asserts it was closed before deallocation.
    private func withBridge<T>(_ body: (WASIBridgeToHost) throws -> T) throws -> T {
        let bridge = try WASIBridgeToHost(fileSystem: .memory(MemoryFileSystem()))
        return try withThrowing {
            try body(bridge)
        } defer: {
            try bridge.close()
        }
    }

    private func functions(
        _ capabilities: [Capability],
        stubUnlinked: Bool
    ) throws -> [String: WASIHostFunction<TestSupport.TestGuestMemory>] {
        try withBridge { $0.hostFunctions(capabilities: capabilities, stubUnlinked: stubUnlinked) }
    }

    /// Names every preview1 function, so a new one cannot be added to a
    /// capability without also being given a signature for stubbing.
    @Test func everyCapabilityFunctionHasASignature() throws {
        let all = try functions(Capability.all, stubUnlinked: false)
        let known = Set(preview1Signatures.map(\.name))
        #expect(Set(all.keys).subtracting(known).isEmpty)
    }

    @Test func stubbingFillsInEveryDeclaredImport() throws {
        let subset = try functions([.stdio], stubUnlinked: true)
        #expect(Set(subset.keys) == Set(preview1Signatures.map(\.name)))
    }

    @Test func aSubsetLinksOnlyWhatItAsksFor() throws {
        let subset = try functions([.clocks, .random], stubUnlinked: false)
        #expect(Set(subset.keys) == ["clock_res_get", "clock_time_get", "random_get"])
    }

    @Test func stubsReportENOSYSRatherThanTrapping() throws {
        let subset = try functions([.random], stubUnlinked: true)
        let stub = try #require(subset["sock_recv"])
        let result = try stub.implementation(TestSupport.TestGuestMemory(), [])
        #expect(result == [.i32(UInt32(WASIAbi.Errno.ENOSYS.rawValue))])
    }

    /// A generator with no entropy to give, as on a bare-metal target without one injected.
    struct NoEntropy: RandomBufferGenerator {
        func fill(buffer: UnsafeMutableBufferPointer<UInt8>) throws {
            throw WASIAbi.Errno.ENOSYS
        }
    }

    @Test func randomGetReturnsTheGeneratorsErrno() throws {
        let bridge = try WASIBridgeToHost(fileSystem: .memory(MemoryFileSystem()), randomGenerator: NoEntropy())
        defer { try? bridge.close() }
        let functions: [String: WASIHostFunction<TestSupport.TestGuestMemory>] = bridge.hostFunctions(
            capabilities: [Capability.random], stubUnlinked: false)
        let randomGet = try #require(functions["random_get"])
        let result = try randomGet.implementation(TestSupport.TestGuestMemory(), [.i32(0x100), .i32(4)])
        #expect(result == [.i32(UInt32(WASIAbi.Errno.ENOSYS.rawValue))])
    }

    /// `all` must stay in sync with the capabilities that exist.
    @Test func allCoversEveryImplementedFunction() throws {
        let all = try functions(Capability.all, stubUnlinked: false)
        // The four unimplemented preview1 entries only ever exist as stubs.
        let stubOnly: Set<String> = ["proc_raise", "sock_accept", "sock_recv", "sock_send"]
        #expect(Set(preview1Signatures.map(\.name)).subtracting(all.keys) == stubOnly)
    }
}
