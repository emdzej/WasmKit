class SourcePrinter {
    var contents: String = ""
    var indentLevel: Int = 0

    init(header: String = "") {
        self.contents = header
    }

    func write<S: StringProtocol>(line: S) {
        contents += "\n" + String(repeating: " ", count: indentLevel * 4)
        contents += line
    }

    func write(multiline: String) {
        for line in multiline.split(separator: "\n") {
            write(line: line)
        }
    }

    func indent() {
        indentLevel += 1
    }

    func unindent() {
        indentLevel -= 1
    }

    func indent(_ body: () throws -> Void) rethrows {
        indentLevel += 1
        try body()
        indentLevel -= 1
    }
}

final class SwiftFunctionBuilder {
    private var variables: Set<String> = []

    /// A new variable name based on `name`, which may be an escaped identifier.
    func variable(_ name: String) -> String {
        // A name built from an escaped one, such as "`self`Lowered", drops the backticks.
        var name = name.replacingOccurrences(of: "`", with: "")
        if SwiftName.keywordSet.contains(name) { name += "_" }
        if variables.insert(name).inserted {
            return name
        }
        var suffixedName: String
        var suffix = 1
        repeat {
            suffixedName = name + suffix.description
            suffix += 1
        } while !variables.insert(suffixedName).inserted
        return suffixedName
    }
}
