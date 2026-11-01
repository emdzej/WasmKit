import Foundation
import Testing
import WASTRunner
import WasmKit

@Suite struct WASTRunnerTests {
    private static let script = """
        (module
          (func (export "answer") (result i32) (i32.const 42))
        )
        (assert_return (invoke "answer") (i32.const 42))
        (assert_return (invoke "answer") (i32.const 7))
        """

    @Test func evaluateTalliesPassingAndFailingAssertions() throws {
        try withScript(Self.script) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter())

            // The module directive counts as a pass alongside the one passing assertion.
            #expect(outcome.passed == 2)
            #expect(outcome.failed == 1)
            #expect(outcome.failures.count == 1)
            #expect(outcome.failures.first?.reason.contains("result mismatch") == true)
        }
    }

    @Test func runReportsAFailingAssertionAsAnError() throws {
        try withScript(Self.script) { script in
            #expect(throws: (any Error).self) {
                try SpectestRunner(configuration: EngineConfiguration())
                    .run(test: script, reporter: NullSpectestProgressReporter())
            }
        }
    }

    /// A module that fails to parse on line 3, used by the assertion on line 4.
    private static let unparsableModuleScript = """
        (module (func (export "a") (result i32) (i32.const 1)))
        (assert_return (invoke "a") (i32.const 1))
        (module (func (export "b") (result i32) (no.such.instruction)))
        (assert_return (invoke "b") (i32.const 2))
        (module (func (export "c") (result i32) (i32.const 3)))
        (assert_return (invoke "c") (i32.const 3))
        """

    @Test func aDirectiveThatFailsToParseDoesNotEndTheScript() throws {
        try withScript(Self.unparsableModuleScript) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter())

            #expect(outcome.passed == 4)
            #expect(outcome.failures.map { $0.0.computeLineAndColumn().line } == [3, 4])
        }
    }

    @Test func skippingAModuleSkipsTheDirectivesThatUseIt() throws {
        try withScript(Self.unparsableModuleScript) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter(), skip: [3: "unsupported"])

            #expect(outcome.passed == 4)
            #expect(outcome.skipped == 2)
            #expect(outcome.failures.isEmpty)
        }
    }

    @Test func skippingADefinitionSkipsItsInstances() throws {
        let script = """
            (module (func (export "a") (result i32) (i32.const 1)))
            (module definition $M (func (export "m") (result i32) (no.such.instruction)))
            (assert_return (invoke "a") (i32.const 1))
            (module instance $I $M)
            (assert_return (invoke $I "m") (i32.const 2))
            """
        try withScript(script) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter(), skip: [2: "unsupported"])

            // The assertion on line 3 still runs against the module on line 1.
            #expect(outcome.passed == 2)
            #expect(outcome.skipped == 3)
            #expect(outcome.failures.isEmpty)
        }
    }

    /// A host value is the same value as the external one of the same number, which an
    /// `externref` passes through.
    @Test func passesRefHostArgument() throws {
        let script = """
            (module (func (export "f") (param externref) (result externref) (local.get 0)))
            (assert_return (invoke "f" (ref.host 1)) (ref.host 1))
            (assert_return (invoke "f" (ref.host 1)) (ref.extern 1))
            """
        try withScript(script) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter())
            // The module and both assertions.
            #expect(outcome.passed == 3)
            #expect(outcome.failures.isEmpty)
        }
    }

    /// Assertions about a module must fail when the module links and instantiates fine.
    @Test func moduleAssertionsFailWhenNothingFails() throws {
        let script = """
            (assert_unlinkable (module (func)) "unknown import")
            (assert_trap (module (func $s) (start $s)) "unreachable")
            """
        try withScript(script) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter())
            #expect(outcome.passed == 0)
            #expect(outcome.failures.count == 2)
        }
    }

    @Test func floatResultsAreComparedByBitPattern() throws {
        let script = """
            (module
              (func (export "pos_zero") (result f32) (f32.const 0))
              (func (export "nan_payload") (result f32) (f32.const nan:0x1))
              (func (export "nan_payload_f64") (result f64) (f64.const nan:0x1))
              (func (export "v_nan_payload") (result v128) (v128.const f32x4 nan:0x1 0 0 0))
              (func (export "v_arith") (result v128) (v128.const f32x4 nan:0x400001 0 0 0)))
            (assert_return (invoke "pos_zero") (f32.const -0))
            (assert_return (invoke "nan_payload") (f32.const nan:0x200000))
            (assert_return (invoke "nan_payload") (f32.const nan:canonical))
            (assert_return (invoke "nan_payload") (f32.const nan:arithmetic))
            (assert_return (invoke "nan_payload_f64") (f64.const nan:arithmetic))
            (assert_return (invoke "v_nan_payload") (v128.const f32x4 nan:arithmetic 0 0 0))
            (assert_return (invoke "v_arith") (v128.const f32x4 nan:canonical 0 0 0))
            (assert_return (invoke "v_arith") (v128.const f32x4 nan:arithmetic 0 0 0))
            """
        try withScript(script) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter())
            // Only the module and the final arithmetic-NaN lane match.
            #expect(outcome.passed == 2)
            #expect(outcome.failures.map { $0.0.computeLineAndColumn().line } == Array(7...13))
        }
    }

    @Test func eitherAcceptsPlainConstants() throws {
        let script = """
            (module (func (export "two") (result i32) (i32.const 2)))
            (assert_return (invoke "two") (either (i32.const 1) (i32.const 2)))
            (assert_return (invoke "two") (either (i32.const 1) (i32.const 3)))
            """
        try withScript(script) { script in
            let outcome = try SpectestRunner(configuration: EngineConfiguration())
                .evaluate(test: script, reporter: NullSpectestProgressReporter())
            #expect(outcome.passed == 2)
            #expect(outcome.failures.map { $0.0.computeLineAndColumn().line } == [3])
        }
    }

    /// Keeps the script out of `ExtraSuite`, which `SpectestTests` scans and would fail on it.
    private func withScript(_ text: String, _ body: (TestCase) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wast-runner-\(UUID().uuidString).wast")
        try Data(text.utf8).write(to: url)
        do {
            let script = try #require(TestCase.load(include: [], exclude: [], in: [url.path]).first)
            try body(script)
        } catch {
            try FileManager.default.removeItem(at: url)
            throw error
        }
        try FileManager.default.removeItem(at: url)
    }
}
