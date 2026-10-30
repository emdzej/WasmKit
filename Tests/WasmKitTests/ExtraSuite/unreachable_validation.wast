;; Code after `unreachable` is still validated: a polymorphic stack supplies missing operands,
;; but labels, mutability and result types are checked as in reachable code.
(assert_invalid
  (module (func unreachable (br_table 5 (i32.const 0))))
  "unknown label")
(assert_invalid
  (module (func (block (result i32) (block unreachable (br_table 0 1)))))
  "type mismatch")
(assert_invalid
  (module (global $g i32 (i32.const 0)) (func unreachable (global.set $g)))
  "immutable global")
(assert_invalid
  (module (table 1 funcref) (func unreachable (i32.const 1) (table.grow 0) (i64.eqz) (drop)))
  "type mismatch")
(assert_invalid
  (module (func unreachable (i8x16.shuffle 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) (i64.eqz) (drop)))
  "type mismatch")
(module
  (table 1 funcref)
  (func (result i32) unreachable (i32.const 1) (table.grow 0))
  (func (result v128) unreachable (i8x16.shuffle 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))

;; A function referenced only by an export is declared for `ref.func`.
(module
  (func $f)
  (export "f" (func $f))
  (func (export "g") (result funcref) (ref.func $f)))
(assert_return (invoke "g") (ref.func))

;; An element item may read an `externref` global.
(module
  (global $e externref (ref.null extern))
  (table $t 2 externref)
  (elem (table $t) (i32.const 0) externref (global.get $e))
  (func (export "is_null") (result i32) (ref.is_null (table.get $t (i32.const 0)))))
(assert_return (invoke "is_null") (i32.const 1))

;; A module that fails validation writes nothing into an imported memory: segments are checked
;; before the first one is applied.
(module $M (memory (export "m") 1) (func (export "load") (result i32) (i32.load8_u (i32.const 0))))
(register "M" $M)
(assert_invalid
  (module (import "M" "m" (memory 1)) (data (i32.const 0) "a") (data (i64.const 0) "b"))
  "type mismatch")
(assert_return (invoke $M "load") (i32.const 0))
