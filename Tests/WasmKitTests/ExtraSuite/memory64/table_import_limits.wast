;; Importing a table checks its limits and address type, not only its element type.
(module $M
  (table (export "t") 2 5 funcref)
  (table (export "unbounded") 2 funcref)
  (table (export "t64") i64 2 5 funcref))
(register "M" $M)

(module (import "M" "t" (table 1 funcref)))
(module (import "M" "t" (table 2 5 funcref)))
(module (import "M" "t" (table 0 10 funcref)))
(assert_unlinkable (module (import "M" "t" (table 3 funcref))) "incompatible import type")
(assert_unlinkable (module (import "M" "t" (table 0 4 funcref))) "incompatible import type")
(assert_unlinkable (module (import "M" "unbounded" (table 0 10 funcref))) "incompatible import type")
(assert_unlinkable (module (import "M" "t" (table i64 0 funcref))) "incompatible import type")
(assert_unlinkable (module (import "M" "t64" (table 0 funcref))) "incompatible import type")
(module (import "M" "t64" (table i64 0 funcref)))
(module (import "spectest" "table64" (table i64 10 20 funcref)))
