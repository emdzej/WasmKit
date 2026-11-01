import Testing
import WAT
import WasmParser

@testable import WasmKit

/// The garbage collector frees the structs and arrays no root reaches, and keeps the rest: see
/// `GCHeap`. The spec testsuite allocates too little to start a collection, so these allocate
/// enough garbage to start several.
@Suite
struct GCTests {
    static let features = WasmFeatureSet.default.union([.gc, .functionReferences])

    /// Instantiates `wat`, which may import `host.f`, a function returning nothing.
    static func instantiate(_ wat: String) throws -> (Store, Instance) {
        let module = try parseWasm(bytes: wat2wasm(wat, features: features), features: features)
        let store = Store(engine: Engine(configuration: EngineConfiguration(features: features)))
        return (store, try module.instantiate(store: store))
    }

    /// A function that allocates `n` unreachable structs, enough to start collections.
    static let churn = """
          (func $churn (export "churn") (param $n i32)
            (loop $l
              (drop (struct.new $box (local.get $n)))
              (br_if $l (local.tee $n (i32.sub (local.get $n) (i32.const 1))))))
        """

    @Test
    func unreachableObjectsAreFreed() throws {
        let (store, instance) = try Self.instantiate(
            """
            (module
              (type $box (struct (field i32)))
              \(Self.churn))
            """)
        try instance.exports[function: "churn"]!([.i32(200_000)])
        // 200 000 boxes take 8 MB with their headers; a collection starts every MB or so.
        #expect(store.gcHeap.objectCount < 100_000)
    }

    @Test
    func objectsReachableFromGlobalsSurvive() throws {
        let (_, instance) = try Self.instantiate(
            """
            (module
              (type $box (struct (field i32)))
              (type $list (struct (field i32) (field (ref null $list))))
              (global $head (mut (ref null $list)) (ref.null $list))
              \(Self.churn)
              (func (export "build") (param $n i32)
                (loop $l
                  (global.set $head (struct.new $list (local.get $n) (global.get $head)))
                  (br_if $l (local.tee $n (i32.sub (local.get $n) (i32.const 1))))))
              (func (export "sum") (result i32)
                (local $node (ref null $list)) (local $sum i32)
                (local.set $node (global.get $head))
                (block $done
                  (loop $l
                    (br_if $done (ref.is_null (local.get $node)))
                    (local.set $sum (i32.add (local.get $sum) (struct.get $list 0 (local.get $node))))
                    (local.set $node (struct.get $list 1 (local.get $node)))
                    (br $l)))
                (local.get $sum)))
            """)
        try instance.exports[function: "build"]!([.i32(1000)])
        try instance.exports[function: "churn"]!([.i32(200_000)])
        #expect(try instance.exports[function: "sum"]!() == [.i32(500_500)])
    }

    @Test
    func objectsReachableFromTablesSurvive() throws {
        let (_, instance) = try Self.instantiate(
            """
            (module
              (type $box (struct (field i32)))
              (table $t 1 anyref)
              \(Self.churn)
              (func (export "store") (table.set $t (i32.const 0) (struct.new $box (i32.const 42))))
              (func (export "load") (result i32)
                (struct.get $box 0 (ref.cast (ref $box) (table.get $t (i32.const 0))))))
            """)
        try instance.exports[function: "store"]!()
        try instance.exports[function: "churn"]!([.i32(200_000)])
        #expect(try instance.exports[function: "load"]!() == [.i32(42)])
    }

    @Test
    func objectsTheHostHoldsSurvive() throws {
        let (_, instance) = try Self.instantiate(
            """
            (module
              (type $box (struct (field i32)))
              \(Self.churn)
              (func (export "make") (result anyref) (struct.new $box (i32.const 7)))
              (func (export "read") (param anyref) (result i32)
                (struct.get $box 0 (ref.cast (ref $box) (local.get 0)))))
            """)
        let box = try instance.exports[function: "make"]!()
        try instance.exports[function: "churn"]!([.i32(200_000)])
        #expect(try instance.exports[function: "read"]!(box) == [.i32(7)])
    }

    /// An object only a local of a function that is still running refers to.
    @Test
    func objectsOnTheStackSurvive() throws {
        let (_, instance) = try Self.instantiate(
            """
            (module
              (type $box (struct (field i32)))
              \(Self.churn)
              (func (export "f") (result i32)
                (local $b (ref null $box))
                (local.set $b (struct.new $box (i32.const 9)))
                (call $churn (i32.const 200000))
                (struct.get $box 0 (local.get $b))))
            """)
        #expect(try instance.exports[function: "f"]!() == [.i32(9)])
    }

    /// Fields of reference type are traced: the arrays only the outer array refers to survive.
    @Test
    func fieldsAreTraced() throws {
        let (_, instance) = try Self.instantiate(
            """
            (module
              (type $box (struct (field i32)))
              (type $row (array (mut i32)))
              (type $grid (array (mut (ref null $row))))
              (global $g (mut (ref null $grid)) (ref.null $grid))
              \(Self.churn)
              (func (export "build")
                (local $i i32)
                (global.set $g (array.new_default $grid (i32.const 100)))
                (loop $l
                  (array.set $grid (global.get $g) (local.get $i) (array.new $row (local.get $i) (i32.const 10)))
                  (br_if $l (i32.lt_u (local.tee $i (i32.add (local.get $i) (i32.const 1))) (i32.const 100)))))
              (func (export "read") (param i32) (result i32)
                (array.get $row (array.get $grid (global.get $g) (local.get 0)) (i32.const 9))))
            """)
        try instance.exports[function: "build"]!()
        try instance.exports[function: "churn"]!([.i32(200_000)])
        #expect(try instance.exports[function: "read"]!([.i32(37)]) == [.i32(37)])
    }

    /// Creating or filling an array costs fuel by its size, like a bulk memory operation does.
    @Test
    func bulkArrayOperationsChargeFuel() throws {
        let wat = """
            (module
              (type $a (array (mut i64)))
              (func (export "new") (drop (array.new_default $a (i32.const 1000000))))
              (func (export "small") (drop (array.new_default $a (i32.const 10)))))
            """
        let module = try parseWasm(bytes: wat2wasm(wat, features: Self.features), features: Self.features)
        let store = Store(engine: Engine(configuration: EngineConfiguration(features: Self.features, fuelMetering: true)))
        store.fuel = Fuel(remaining: 10_000)
        let instance = try module.instantiate(store: store)
        try instance.exports[function: "small"]!()
        // 8 MB of elements, at one unit per 64 bytes.
        #expect {
            try instance.exports[function: "new"]!()
        } throws: { error in
            "\(error)".contains("out of fuel")
        }
    }
}
