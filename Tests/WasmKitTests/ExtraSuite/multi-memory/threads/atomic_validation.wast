;; Atomic accesses must be naturally aligned exactly.
(assert_invalid
  (module (memory 1 1 shared) (func (drop (i32.atomic.load align=1 (i32.const 0)))))
  "alignment")
(assert_invalid
  (module (memory 1 1 shared) (func (drop (i32.atomic.rmw.add align=2 (i32.const 0) (i32.const 0)))))
  "alignment")
(assert_invalid
  (module (memory 1 1 shared) (func (drop (memory.atomic.notify align=8 (i32.const 0) (i32.const 0)))))
  "alignment")
(module (memory 1 1 shared)
  (func (drop (i32.atomic.load align=4 (i32.const 0))))
  (func (drop (i64.atomic.rmw.add align=8 (i32.const 0) (i64.const 0)))))

;; Valid atomics after `unreachable` validate against the polymorphic stack.
(module (memory 1 1 shared)
  (func (result i32) unreachable i32.atomic.rmw.add)
  (func (result i64) unreachable i64.atomic.rmw.cmpxchg)
  (func (result i32) unreachable memory.atomic.wait32)
  (func (result i32) unreachable memory.atomic.notify))

;; `memory.atomic.notify` checks alignment and bounds like the other atomics, though it reads
;; no memory.
(module
  (memory 1 1 shared)
  (func (export "notify") (param i32) (result i32) (memory.atomic.notify (local.get 0) (i32.const 0))))
(assert_trap (invoke "notify" (i32.const 1)) "unaligned atomic")
(assert_trap (invoke "notify" (i32.const 65536)) "out of bounds")
(assert_return (invoke "notify" (i32.const 65532)) (i32.const 0))
