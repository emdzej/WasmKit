import Testing
import WAT
import WasmParser

@testable import WasmKit

/// Every function entry an interceptor sees is matched by an exit, however the function leaves.
@Suite struct InterceptorBalanceTests {
    final class Recorder: EngineInterceptor {
        var events: [String] = []
        func onEnterFunction(_ function: Function) { events.append("enter") }
        func onExitFunction(_ function: Function) { events.append("exit") }
    }

    private func events(running wat: String, features: WasmFeatureSet = .default) throws -> [String] {
        let recorder = Recorder()
        var configuration = EngineConfiguration()
        configuration.features = features
        let engine = Engine(configuration: configuration, interceptor: recorder)
        let store = Store(engine: engine)
        let module = try parseWasm(bytes: try wat2wasm(wat, features: features), features: features)
        let instance = try module.instantiate(store: store)
        _ = try instance.exports[function: "run"]!()
        return recorder.events
    }

    @Test func aBranchToTheFunctionLabelExits() throws {
        let events = try events(running: #"(module (func (export "run") (br 0)))"#)
        #expect(events == ["enter", "exit"])
    }

    @Test func aTailCallExitsBeforeTheCalleeEnters() throws {
        var features = WasmFeatureSet.default
        features.insert(.tailCall)
        let events = try events(
            running: #"(module (func $g) (func (export "run") (return_call $g)))"#, features: features)
        #expect(events == ["enter", "exit", "enter", "exit"])
    }
}
