;; On a 64-bit memory, `index + offset` can overflow: the access traps rather than wrapping
;; to a low address that passes the bounds check.
(module
  (memory i64 1)
  (data (i64.const 0x10) "0123456789abcdef")
  (func (export "v128") (param i64) (result v128) (v128.load offset=0x20 (local.get 0)))
  (func (export "lane") (param i64) (result v128)
    (v128.load32_lane offset=0x20 0 (local.get 0) (v128.const i32x4 0 0 0 0)))
  (func (export "scalar") (param i64) (result i64) (i64.load offset=0x20 (local.get 0))))
(assert_trap (invoke "v128" (i64.const -16)) "out of bounds memory access")
(assert_trap (invoke "lane" (i64.const -16)) "out of bounds memory access")
(assert_trap (invoke "scalar" (i64.const -16)) "out of bounds memory access")

;; A failed `table.grow` returns -1 in the table's address type.
(module
  (table $t i64 1 2 funcref)
  (func (export "grow") (result i64) (table.grow $t (ref.null func) (i64.const 10))))
(assert_return (invoke "grow") (i64.const -1))

;; Unaligned stores work on every host.
(module
  (memory 1)
  (func (export "store") (i32.store offset=1 (i32.const 0) (i32.const 0x04030201))
    (i64.store offset=7 (i32.const 0) (i64.const 0x0807060504030201)))
  (func (export "load") (param i32) (result i32) (i32.load8_u (local.get 0))))
(invoke "store")
(assert_return (invoke "load" (i32.const 1)) (i32.const 1))
(assert_return (invoke "load" (i32.const 4)) (i32.const 4))
(assert_return (invoke "load" (i32.const 7)) (i32.const 1))
(assert_return (invoke "load" (i32.const 14)) (i32.const 8))
