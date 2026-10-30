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

### 1. Runtime export names compare by Unicode equivalence

- **Where:** `InstanceEntity.exports` (`[String: InternalExternalValue]`) and the public export
  lookups.
- **Problem:** `$"\u{c5}"` and `$"A\u{30a}"` are different names to the spec but collide in the
  runtime. `names.wast` is skipped for this reason (`Sources/WASTRunner/TestCase.swift`).
- **Fix:** the WAT parser already keys names by code points (`IdentifierKey` in
  `Sources/WAT/NameMapping.swift`). Do the same in the runtime, then re-enable `names.wast`.

### 2. WIT overlay generator misses some Swift keywords

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

### 3. GC type canonicalization ignores recursion groups

- **Where:** `Sources/WasmKit/TypeCanonicalization.swift` and `TypeMatching.swift`.
- **Problem:** finality and supertypes are ignored too. Types in `(rec (type $a (func)) (type $b (func)))`
  become identical.
- **Fix:** implement iso-recursive canonicalization, or reject non-trivial rec groups and `sub`
  declarations until GC execution exists. Mind the tests in `Tests/WasmKitTests/ExtraSuite/gc`.

### 4. Smaller items

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
- **Resource gaps:** a host that owns a guest-defined resource has no way to drop it, so its
  destructor never runs. The spec's reentrance checks (`may_enter`/`may_leave`) are not
  implemented, for resource destructors or otherwise.
- **Import type checks:** function and value types are checked, by structural equality as
  wasm-tools does (`ComponentTypeMatching.swift`), except that parameter names may differ, as
  wasmtime's linker allows. Not checked: the types of imported values,
  components and core modules, and instance or component exports nested inside an instance
  import's type.
- **Possible dead code:** `WasmFunctionEntity.ensureCompiled` in `Function.swift` may duplicate
  the `EntityHandle` version. Confirm which overload each call site resolves to before removing it.

## Performance

### 5. SIMD still dispatches through one handler

- **Where:** `Sources/WasmKit/Execution/Instructions/SIMDCore.swift`.
- **Problem:** every SIMD instruction decodes `SIMDOpcode` and switches on it, then switches again
  per lane. Phase 4 removed the per-operation allocations, which made SIMD 2.5× faster.
- **Fix:** generate one instruction per operation in `Utilities/Sources/VMGen.swift` and
  `VMSpec`, working on `SIMD16<UInt8>`, `SIMD4<Float>` and so on via `V128Storage`.

### 6. WASI I/O

- **Vectored I/O:** `Sources/WASI/Platform/File.swift` makes one syscall per buffer. Use
  `readv`/`writev`/`preadv`/`pwritev` behind `GuestBuffers.transfer`, keeping its semantics:
  stop after a short transfer, and report the bytes already moved rather than a later error.
- **readdir:** `Directory.swift`'s `HostDirectoryIterator` reopens the directory and skips
  `cookie` entries on every `fd_readdir`, which is quadratic. Cache the open stream per fd, keyed
  by cookie.
- **Opening under the lock:** `path_open` holds the global `fdTable` lock while opening, so
  opening a FIFO blocks every other guest thread. Open outside the lock and reserve the slot first.

### 7. Component calls allocate a stack each

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
  Running every file is a quick way to measure progress. The WAT parser has no syntax for
  resources (`resource`, `own`, `borrow`, `canon resource.*`) or for instance type exports other
  than types, so `Tests/WATTests/ComponentResourceTests.swift` runs the two `resources.wast`
  files from the binaries wasm-tools encodes instead.
