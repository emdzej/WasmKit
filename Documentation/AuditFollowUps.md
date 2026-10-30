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

### 1. Component Model resources are unsupported

- **Where:** `Sources/WasmParser/ComponentParser.swift` (rejects `own`/`borrow`) and the
  `.unsupportedCoreFunction` placeholders in
  `Sources/WasmKit/Execution/ComponentModel/ComponentLoader.swift`.
- **Fix:** add per-instance handle tables, `own`/`borrow` lifting and lowering in
  `Lift+Lower.swift`, and `resource.new`/`drop`/`rep` with destructors.
- **Tests:** `Vendor/component-model/test/{wasmtime,wasm-tools}/resources.wast`.

### 2. Component import function types are not checked

- **Where:** `ComponentLoader.validateImports`.
- **Problem:** only the kind of import is compared, not the function signature.
- **Fix:** check the provided component function type against the declared one, using
  component-type subtyping.

### 3. Runtime export names compare by Unicode equivalence

- **Where:** `InstanceEntity.exports` (`[String: InternalExternalValue]`) and the public export
  lookups.
- **Problem:** `$"\u{c5}"` and `$"A\u{30a}"` are different names to the spec but collide in the
  runtime. `names.wast` is skipped for this reason (`Sources/WASTRunner/TestCase.swift`).
- **Fix:** the WAT parser already keys names by code points (`IdentifierKey` in
  `Sources/WAT/NameMapping.swift`). Do the same in the runtime, then re-enable `names.wast`.

### 4. WIT overlay generator misses some Swift keywords

- **Where:** `Sources/WITOverlayGenerator`. `SwiftName.makeName` is used for most names, but not
  for:
  - type names from `ConvertCase.pascalCase`: `record self` emits `struct Self`
    (`TypeDefinition.swift`, `DefinitionMapping.swift`, `SignatureTranslation.swift`);
  - function names: `init` emits `Impl.init(...)` (`GuestExportInterface.swift:46`,
    `HostExportFunction.swift`);
  - member access: a field `self` emits `result.self` (`StaticCanonicalLowering.swift`,
    `StaticCanonicalLifting.swift`).
- **Fix:** escape after case conversion everywhere. Test by type-checking the generated Swift.
- **Also:** WIT names are not validated as kebab-case, so `%--` yields an empty Swift identifier.

### 5. GC type canonicalization ignores recursion groups

- **Where:** `Sources/WasmKit/TypeCanonicalization.swift` and `TypeMatching.swift`.
- **Problem:** finality and supertypes are ignored too. Types in `(rec (type $a (func)) (type $b (func)))`
  become identical.
- **Fix:** implement iso-recursive canonicalization, or reject non-trivial rec groups and `sub`
  declarations until GC execution exists. Mind the tests in `Tests/WasmKitTests/ExtraSuite/gc`.

### 6. Smaller items

- **Shared memory growth:** `SharedMemoryStorage.grow` turns a resource-limiter error into `-1`,
  and calls the limiter while holding `growLock`. The other memory backends propagate the error.
- **Unwritten host results:** a raw host function that leaves a reference or `v128` result
  unwritten. Result slots start as `.i32(0)` (`Execution.swift`, `Function.swift`).
- **Embedded randomness:** `random_get` under Embedded Swift deliberately calls `fatalError` when
  no `RandomBufferGenerator` was injected (`Sources/WASI/RandomBufferGenerator.swift`). Consider
  `ENOSYS` instead, which means changing the protocol to throw.
- **memfs exclusive create:** `MemoryFileSystem` checks `CREAT|EXCL` and creates in separate steps,
  so two threads can race. memfs also ignores `APPEND`, lists no `.`/`..` in readdir, and opens
  `"file/"` as a regular file.
- **`poll_oneoff`:** a memfs file or a directory makes the whole call fail with `EBADF`. Regular
  files should be reported as ready, and an error should go in that subscription's event
  (`Sources/WASI/Poll.swift`).
- **Possible dead code:** `WasmFunctionEntity.ensureCompiled` in `Function.swift` may duplicate
  the `EntityHandle` version. Confirm which overload each call site resolves to before removing it.

## Performance

### 7. SIMD still dispatches through one handler

- **Where:** `Sources/WasmKit/Execution/Instructions/SIMDCore.swift`.
- **Problem:** every SIMD instruction decodes `SIMDOpcode` and switches on it, then switches again
  per lane. Phase 4 removed the per-operation allocations, which made SIMD 2.5× faster.
- **Fix:** generate one instruction per operation in `Utilities/Sources/VMGen.swift` and
  `VMSpec`, working on `SIMD16<UInt8>`, `SIMD4<Float>` and so on via `V128Storage`.

### 8. WASI I/O

- **Vectored I/O:** `Sources/WASI/Platform/File.swift` makes one syscall per buffer. Use
  `readv`/`writev`/`preadv`/`pwritev` behind `GuestBuffers.transfer`, keeping its semantics:
  stop after a short transfer, and report the bytes already moved rather than a later error.
- **readdir:** `Directory.swift`'s `HostDirectoryIterator` reopens the directory and skips
  `cookie` entries on every `fd_readdir`, which is quadratic. Cache the open stream per fd, keyed
  by cookie.
- **Opening under the lock:** `path_open` holds the global `fdTable` lock while opening, so
  opening a FIFO blocks every other guest thread. Open outside the lock and reserve the slot first.

### 9. Component calls allocate a stack each

- **Where:** `ComponentFunction.invoke` in `ComponentInstance.swift` allocates a 512 KiB
  `ExecutionStack` per call. (`realloc` inside one call already reuses one.)
- **Fix:** keep a stack per store, or pass one in.

## Notes

- **Nesting limit:** components may nest 32 deep (`maxComponentNestingDepth` in
  `ParsedComponentBuilder.swift`). In a debug build, a 512 KiB test-thread stack overflowed
  somewhere between 40 and 60 levels.
- **Component test coverage:** `Tests/WATTests/ComponentTests.swift` runs only a subset of
  `Vendor/component-model/test`. Most of the remaining files fail on text-format encoding
  differences from wasm-tools (resources, aliases, type exports), not on runtime behaviour.
  Running every file is a quick way to measure progress.
