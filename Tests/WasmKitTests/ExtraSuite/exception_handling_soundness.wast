;; A catch clause whose label lies outside an enclosing `try_table` exits that one too: its
;; handlers must not catch a later throw, which would resume in a frame that has returned.
(module
  (tag $t)
  (global $g (mut i32) (i32.const 0))
  (func $f
    (block $x
      (try_table (catch_all $x)
        (try_table (catch_all 1)
          (throw $t))))
    (global.set $g (i32.add (global.get $g) (i32.const 1))))
  (func (export "run")
    (call $f)
    (throw $t))
  (func (export "g") (result i32) (global.get $g)))
(assert_exception (invoke "run"))
(assert_return (invoke "g") (i32.const 1))

;; The same, with the outer label on the enclosing `try_table` itself, and with `catch_ref`.
(module
  (tag $t)
  (global $g (mut i32) (i32.const 0))
  (func $f
    (block $x (result exnref)
      (try_table $outer (catch_all_ref $x)
        (try_table (catch_all $outer)
          (throw $t)))
      (return))
    (drop)
    (global.set $g (i32.add (global.get $g) (i32.const 1))))
  (func (export "run")
    (call $f)
    (call $f)
    (throw $t))
  (func (export "g") (result i32) (global.get $g)))
(assert_exception (invoke "run"))
(assert_return (invoke "g") (i32.const 0))

;; An `exnref` outlives the call that caught it.
(module
  (tag $t (param i32))
  (global $g (mut exnref) (ref.null exn))
  (func (export "catch")
    (block $h (result i32 exnref)
      (try_table (catch_ref $t $h) (throw $t (i32.const 42)))
      unreachable)
    (global.set $g)
    (drop))
  (func (export "rethrow") (result i32)
    (block $h (result i32)
      (try_table (catch $t $h) (throw_ref (global.get $g)))
      unreachable))
  ;; Rethrowing and catching the same exception many times must not grow without bound.
  (func (export "loop") (param $n i32) (result i32)
    (loop $l
      (block $h (result i32 exnref)
        (try_table (catch_ref $t $h) (throw_ref (global.get $g)))
        unreachable)
      (global.set $g)
      (drop)
      (br_if $l (local.tee $n (i32.sub (local.get $n) (i32.const 1)))))
    (call 1)))
(invoke "catch")
(assert_return (invoke "rethrow") (i32.const 42))
(assert_return (invoke "rethrow") (i32.const 42))
(assert_return (invoke "loop" (i32.const 1000)) (i32.const 42))

;; A `v128` payload takes two stack slots.
(module
  (tag $t (param i32 v128 i64))
  (func (export "payload") (result i32 i64 i64 i64)
    (local $v v128) (local $s i64)
    (block $h (result i32 v128 i64)
      (try_table (catch $t $h)
        (throw $t (i32.const 7) (v128.const i64x2 1 2) (i64.const 3)))
      (unreachable))
    (local.set $s)
    (local.set $v)
    (i64x2.extract_lane 0 (local.get $v))
    (i64x2.extract_lane 1 (local.get $v))
    (local.get $s))
  (func (export "uncaught") (throw $t (i32.const 7) (v128.const i64x2 1 2) (i64.const 3))))
(assert_return (invoke "payload") (i32.const 7) (i64.const 1) (i64.const 2) (i64.const 3))
(assert_exception (invoke "uncaught"))
