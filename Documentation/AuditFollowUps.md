# Audit follow-ups

What remains from the codebase audit after commits `fa0d0ac`..`6552153` (phases 0–5: test
harness, host safety, spec conformance, Component Model canonical ABI, performance, hygiene).
Each item says where the code is, what is wrong, and how it could be fixed. Remove an item when
it is done.

Tests must pass with the default traits and with
`--traits FileSystem,MultiThread,ComponentModel,WasmDebuggingSupport,Disassembler`. The vendored
suites come from `./Vendor/checkout-dependency <name>` (`testsuite`, `wasi-testsuite`,
`wasi-threads`, and `--category component-model`). The encoder comparison needs `wast2json` from
wabt 1.0.42.

## Notes

- **Component imports:** an imported component is checked to import nothing its declared type
  does not and to export everything it does, with the same sorts (`checkComponent` in
  `ComponentLoader.swift`). The types of what it imports and exports are not compared: they are
  only known once it is instantiated.
- **Value import encoding:** the parser reads a value import's type as wasm-tools 1.244 writes
  it, with nothing before it. `Binary.md` has a `0x00` (an `eq` bound) or `0x01` (a type) there
  instead, and the two cannot be told apart, as `0x00` and `0x01` are type indices too. Value
  imports are not standard yet; if wasm-tools moves to `Binary.md`'s form, so should
  `parseValueBound` in `ComponentParser.swift`.
- **GC:** type definitions are canonical iso-recursively, by recursion group, in the engine's
  `TypeRegistry` (`Sources/WasmKit/TypeCanonicalization.swift`). Structs and arrays are
  `GCObject`s in their store's `GCHeap` (`Sources/WasmKit/Execution/GC.swift`), which a
  mark-and-sweep collection frees once no root reaches them. It scans the slots of every stack in
  use conservatively, and reads globals and tables, and fields, precisely; an object the host
  holds an `AnyReference` to stays alive through its reference count. The direct-threaded
  interpreter's accumulator registers are not scanned: the translator hands a value through one
  only to the instruction right after the one producing it (`AccRecords` in `Translator.swift`),
  and no GC instruction reads or writes one, so none is live across an allocation. Not done:
  - The heap of a store is capped at 4 GiB (`GCHeap.byteLimit`) rather than asking the store's
    `ResourceLimiter`, which only has hooks for memories and tables.
  - `Reference.any` is a new case of a public enum, which breaks an exhaustive `switch` over it,
    and an `ExternAddress` must now be below 2^60 rather than 2^63, as the `any` and `extern`
    hierarchies share their values: see `GCBits`.
  - Embedded Swift builds of the collector (`ManagedBuffer`, `isKnownUniquelyReferenced`) are only
    checked by CI.
- **Nesting limits:** components may nest 32 deep (`maxComponentNestingDepth` in
  `ParsedComponentBuilder.swift`), and instantiations 32 deep (`maxInstantiationDepth` in
  `ComponentLoader.swift`), which nesting does not bound: a component can instantiate one defined
  before it in an enclosing component. Both recurse; in a debug build a 512 KiB test-thread stack
  overflowed at 40 to 60 levels of nesting, and at 50 to 70 instantiations. Real components go a
  handful deep, so the limits stay rather than the recursion becoming iterative.
- **Component test coverage:** `ComponentResourceTests.suite` runs every file in
  `Vendor/component-model/test` but `async` from the binaries wasm-tools encodes, apart from
  those its `unsupported` list gives a reason for: Component Model async, and files whose
  `assert_return` values wasm-tools cannot write to JSON. `Tests/WATTests/ComponentTests.swift`
  checks the text format encoder here against wasm-tools on a subset: 30 of the suite's 209
  components encode to the same bytes. Most of the rest do not parse, as the WAT parser has no
  syntax for resources, for `component`, `type` and `core module` imports, or for instance type
  exports other than types, and skips function imports' types.
