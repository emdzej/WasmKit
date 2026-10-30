import Foundation
import Testing
import WasmTypes

@testable import WasmParser

/// Sizes and counts in a binary are untrusted: they must not make the parser reserve memory
/// out of proportion to the input, nor let a body overrun its declared size.
@Suite struct UntrustedSizeTests {
    private static func module(_ sections: [(id: UInt8, content: [UInt8])]) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
        for section in sections {
            bytes += [section.id] + unsignedLEB128(section.content.count) + section.content
        }
        return bytes
    }

    private static func unsignedLEB128(_ value: Int) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private static func codes(_ body: [UInt8]) throws -> [Code] {
        let bytes = module([
            (id: 1, content: [0x01, 0x60, 0x00, 0x00]),
            (id: 3, content: [0x01, 0x00]),
            (id: 10, content: [0x01] + unsignedLEB128(body.count) + body),
        ])
        var parser = Parser(bytes: bytes)
        while let payload = try parser.parseNext() {
            if case .codeSection(let codes) = payload { return codes }
        }
        return []
    }

    /// Six bytes declare 99998 locals; the parser keeps the declaration, not 99998 entries.
    @Test func localsAreKeptAsDeclared() throws {
        let code = try #require(try Self.codes([0x02, 0x9E, 0x8D, 0x06, 0x7F, 0x01, 0x7E, 0x0B]).first)
        #expect(
            code.localDeclarations == [
                Code.LocalDeclaration(count: 99_998, type: .i32),
                Code.LocalDeclaration(count: 1, type: .i64),
            ])
        #expect(code.locals.count == 99_999)
        #expect(code.locals.last == .i64)
    }

    /// A body whose local declarations run past its declared size is malformed; it used to come
    /// out as an empty body that only eager compilation rejected.
    @Test func localsPastTheBodySizeAreRejected() throws {
        let bytes = Self.module([
            (id: 1, content: [0x01, 0x60, 0x00, 0x00]),
            (id: 3, content: [0x01, 0x00]),
            // One body of size 0, followed by the byte its locals count would have been.
            (id: 10, content: [0x01, 0x00, 0x00]),
        ])
        var parser = Parser(bytes: bytes)
        #expect(throws: WasmParserError.self) {
            while try parser.parseNext() != nil {}
        }
    }

    #if FileSystem && !os(WASI)
        /// A 16-byte file whose custom section claims 1 GiB: the read must fail once the file
        /// runs out, without first reserving the claimed size.
        @Test func aClaimedSectionSizeIsNotReservedUpFront() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("untrusted-size-\(UUID().uuidString).wasm")
            try Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x80, 0x04, 0x01, 0x61])
                .write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            var parser = try Parser(filePath: url.path)
            #expect(throws: WasmParserError.self) {
                while try parser.parseNext() != nil {}
            }
        }

        @Test func aFileIsReadToItsEndInChunks() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunked-read-\(UUID().uuidString).bin")
            let contents = (0..<(FileIO.readChunkSize * 2 + 17)).map { UInt8(truncatingIfNeeded: $0) }
            try Data(contents).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let fd = try FileIO.openForReading(path: url.path)
            defer { FileIO.closeFile(fd) }
            #expect(try FileIO.readBytes(fd, upToCount: contents.count + 100) == contents)
        }
    #endif
}
