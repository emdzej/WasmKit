import Foundation
import Testing
import WasmTypes

@_spi(WASIPlatform) @testable import WASI

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The in-memory filesystem, host filesystem and stdio answer the guest the way a host
/// directory and `renameat`, `lseek` or `futimens` would.
@Suite struct WASIBehaviourParityTests {
    private func withMemoryFileSystem(
        _ setUp: (MemoryFileSystem) throws -> Void = { _ in },
        _ body: (WASIImplementation) throws -> Void
    ) throws {
        let fs = try MemoryFileSystem()
        try fs.ensureDirectory(at: "/dir")
        try setUp(fs)
        let bridge = try WASIBridgeToHost(
            fileSystem: .memory(fs).withPreopens([.init(guestPath: "/dir", hostPath: "/dir")]))
        try bridge.runAndClose { try body($0.underlying) }
    }

    @Test func renamingADirectoryIntoItselfIsRefused() throws {
        try withMemoryFileSystem { wasi in
            try wasi.path_create_directory(dirFd: 3, path: "a")
            #expect(throws: WASIAbi.Errno.EINVAL) {
                try wasi.path_rename(oldFd: 3, oldPath: "a", newFd: 3, newPath: "a/b")
            }
            // The tree is intact.
            _ = try wasi.path_filestat_get(dirFd: 3, flags: [], path: "a")
        }
    }

    @Test func renamingChecksTheDestinationType() throws {
        try withMemoryFileSystem({ fs in
            try fs.addFile(at: "/dir/file", content: "x")
            try fs.ensureDirectory(at: "/dir/full/child")
            try fs.ensureDirectory(at: "/dir/empty")
        }) { wasi in
            #expect(throws: WASIAbi.Errno.EISDIR) {
                try wasi.path_rename(oldFd: 3, oldPath: "file", newFd: 3, newPath: "empty")
            }
            #expect(throws: WASIAbi.Errno.ENOTDIR) {
                try wasi.path_rename(oldFd: 3, oldPath: "empty", newFd: 3, newPath: "file")
            }
            #expect(throws: WASIAbi.Errno.ENOTEMPTY) {
                try wasi.path_rename(oldFd: 3, oldPath: "empty", newFd: 3, newPath: "full")
            }
            try wasi.path_rename(oldFd: 3, oldPath: "file", newFd: 3, newPath: "file")
            try wasi.path_rename(oldFd: 3, oldPath: "full", newFd: 3, newPath: "empty")
        }
    }

    #if os(macOS) || os(Linux)
        /// Reads move the entry's own position, which `fd_seek` must report and start from.
        @Test func seekingAHandleBackedFileFollowsReads() throws {
            let directory = try TestSupport.TemporaryDirectory()
            try directory.createFile(at: "f", contents: "0123456789abcdef")
            let handle = open(directory.url.appendingPathComponent("f").path, O_RDONLY)
            #expect(handle >= 0)
            try withMemoryFileSystem({ fs in try fs.addFile(at: "/dir/f", handle: handle) }) { wasi in
                let fd = try wasi.path_open(
                    dirFd: 3, dirFlags: [], path: "f", oflags: [],
                    fsRightsBase: [.FD_READ, .FD_SEEK, .FD_TELL], fsRightsInheriting: [], fdflags: [])
                let memory = TestSupport.TestGuestMemory()
                _ = try wasi.fd_read(fd: fd, iovs: try memory.readIOVecs(sizes: [10]), memory: memory)
                #expect(try wasi.fd_seek(fd: fd, offset: 0, whence: .CUR) == 10)
                #expect(try wasi.fd_seek(fd: fd, offset: -2, whence: .END) == 14)
                let iovs = try memory.readIOVecs(sizes: [2])
                #expect(try wasi.fd_read(fd: fd, iovs: iovs, memory: memory) == 2)
                #expect(try memory.loadIOVecs(iovs) == [Array("ef".utf8)])
            }
        }

        @Test func aDirectoryCanBeRetimed() throws {
            let directory = try TestSupport.TemporaryDirectory()
            try directory.createDir(at: "d")
            let bridge = try WASIBridgeToHost(
                fileSystem: .host().withPreopens([.init(guestPath: "/dir", hostPath: directory.path)]))
            try bridge.runAndClose { bridge in
                let wasi = bridge.underlying
                try wasi.path_filestat_set_times(
                    dirFd: 3, flags: [], path: "d", atim: 1_000_000_000, mtim: 2_000_000_000,
                    fstFlags: [.ATIM, .MTIM])
                #expect(try wasi.path_filestat_get(dirFd: 3, flags: [], path: "d").mtim == 2_000_000_000)
            }
        }
    #endif

    @Test func aPathThatIsNotUTF8IsRefused() throws {
        let memory = TestSupport.TestGuestMemory()
        memory.write([0x61, 0xFF, 0x62], at: 0)
        #expect(throws: WASIAbi.Errno.EILSEQ) { _ = try readString(pointer: 0, length: 3, buffer: memory) }
        memory.write(Array("añb".utf8), at: 16)
        #expect(try readString(pointer: 16, length: 4, buffer: memory) == "añb")
    }

    @Test func stdioStatusFlagsAreLeftAlone() throws {
        let bridge = try WASIBridgeToHost()
        try bridge.runAndClose { bridge in
            #expect(throws: WASIAbi.Errno.ENOTSUP) {
                try bridge.underlying.fd_fdstat_set_flags(fd: 1, flags: .NONBLOCK)
            }
        }
    }
}
