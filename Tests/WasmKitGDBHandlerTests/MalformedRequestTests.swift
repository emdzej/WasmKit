#if WasmDebuggingSupport

    import GDBRemoteProtocol
    import Testing

    @testable import WasmKitGDBHandler

    /// A malformed or unsupported request gets a reply the host can handle; it must neither
    /// stop the server nor end the session.
    @Suite
    struct MalformedRequestTests {
        static let wat = """
            (module (func (export "_start")))
            """

        private static func isError(_ response: GDBTargetResponse) -> Bool {
            if case .error = response.kind { return true }
            return false
        }

        @Test(arguments: [
            // Below the code space, past it, and not fitting an address at all.
            ",10,1", ",ffffffffffffffff,1", ",10000000000000000,1", ",zz,1", "",
        ])
        func aBreakpointAddressOutsideTheCodeIsRefused(arguments: String) throws {
            try withHandler(debugging: Self.wat) { handler in
                let insert = try handler.handle(command: .init(kind: .insertSoftwareBreakpoint, arguments: arguments))
                let remove = try handler.handle(command: .init(kind: .removeSoftwareBreakpoint, arguments: arguments))
                #expect(Self.isError(insert))
                #expect(Self.isError(remove))
            }
        }

        @Test func aMalformedReadIsRefused() throws {
            try withHandler(debugging: Self.wat) { handler in
                let response = try handler.handle(command: .init(kind: .readMemory, arguments: "nonsense"))
                #expect(Self.isError(response))
            }
        }

        @Test func anUnsupportedTransferGetsAnEmptyReply() throws {
            try withHandler(debugging: Self.wat) { handler in
                let response = try handler.handle(command: .init(kind: .transfer, arguments: "features:read:target.xml:0,fff"))
                guard case .empty = response.kind else {
                    Issue.record("expected an empty reply, got \(response.kind)")
                    return
                }
            }
        }
    }

#endif
