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

## Correctness

### 1. Smaller items

- **Import type checks:** function, value and core module types are checked
  (`ComponentTypeMatching.swift`). Parameter names may differ unless the loader is created with
  `importTypeChecking: .strict`, as wasmtime's linker allows. Not checked: the types of imported
  values and components, and instance or component exports nested inside an instance import's
  type. `wasmtime/import.wast` and `wasmtime/instance.wast` need exports the test harness's
  `host` instance does not have yet (`ComponentResourceTests.SpectestHost`).

## Notes

- **GC types:** `TypeCanonicalizer` (`Sources/WasmKit/TypeCanonicalization.swift`) identifies a
  type by its function signature, so it rejects recursion groups of several types, types that
  refer to themselves, and non-final types or declared supertypes. GC execution will need
  iso-recursive canonicalization and declared subtyping in `TypeMatching.swift` instead.
- **Nesting limit:** components may nest 32 deep (`maxComponentNestingDepth` in
  `ParsedComponentBuilder.swift`). In a debug build, a 512 KiB test-thread stack overflowed
  somewhere between 40 and 60 levels.
- **Component test coverage:** `Tests/WATTests/ComponentTests.swift` runs only a subset of
  `Vendor/component-model/test`. Most of the remaining files fail on text-format encoding
  differences from wasm-tools (resources, aliases, type exports), not on runtime behaviour.
  Running every file is a quick way to measure progress. The WAT parser has no syntax for
  resources (`resource`, `own`, `borrow`, `canon resource.*`) or for instance type exports other
  than types, so `Tests/WATTests/ComponentResourceTests.swift` runs the two `resources.wast`
  files from the binaries wasm-tools encodes instead.
