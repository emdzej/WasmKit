/// An import or export name, compared as the spec compares names: by their code points.
///
/// `String` compares by Unicode canonical equivalence, so `"\u{C5}"` and `"A\u{30A}"` are equal
/// strings, but they are different names, and a module may export both.
struct ExternalName: Hashable {
    let string: String

    init(_ string: String) {
        self.string = string
    }

    static func == (lhs: ExternalName, rhs: ExternalName) -> Bool {
        lhs.string.utf8.elementsEqual(rhs.string.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var string = string
        string.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
