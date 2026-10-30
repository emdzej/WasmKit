import Foundation
import Testing
import WasmTypes

@_spi(WASIPlatform) @testable import WASI

/// The guest controls every pointer, length and path it passes to WASI. None of them may stop
/// the host process, write outside the buffer the guest named, or reveal host files outside a
/// preopen.
@Suite struct WASISandboxBoundaryTests {

    // MARK: - Guest pointers

    /// An iovec running past the end of memory is the guest's fault, so it gets `EFAULT`.
    @Test func anOutOfBoundsIovecIsAFault() throws {
        let fs = try MemoryFileSystem()
        try fs.ensureDirectory(at: "/dir")
        try fs.addFile(at: "/dir/a.txt", content: "")
        let bridge = try WASIBridgeToHost(
            fileSystem: .memory(fs).withPreopens([.init(guestPath: "/dir", hostPath: "/dir")]))
        let functions = bridge.hostFunctions(
            capabilities: WASICapability<TestSupport.TestGuestMemory>.all, stubUnlinked: false)
        let fdWrite = try #require(functions["fd_write"])
        try bridge.runAndClose { bridge in
            let fd = try bridge.underlying.path_open(
                dirFd: 3, dirFlags: [], path: "a.txt", oflags: [],
                fsRightsBase: .FD_WRITE, fsRightsInheriting: [], fdflags: [])
            let memory = TestSupport.TestGuestMemory()
            // One iovec at 0: 256 bytes at 0xFFF0, which crosses the end of a 64 KiB memory.
            memory.write([0xF0, 0xFF, 0, 0, 0, 1, 0, 0], at: 0)
            let result = try fdWrite.implementation(memory, [.i32(fd), .i32(0), .i32(1), .i32(16)])
            #expect(result == [.i32(UInt32(WASIAbi.Errno.EFAULT.rawValue))])
        }
    }

    /// Advancing a pointer past the 32-bit address space must not wrap to a low, valid address.
    @Test func aPointerPastTheAddressSpaceDoesNotWrap() throws {
        let memory = TestSupport.TestGuestMemory()
        let pointer = UnsafeGuestRawPointer(offset: .max - 1).advanced(by: 4)
        #expect(pointer.offset == .max)
        #expect(throws: GuestMemoryError.self) { try UInt32.readFromGuest(pointer, in: memory) }
        let element = UnsafeGuestPointer<UInt32>(offset: 8) + .max
        #expect(element.raw.offset == .max)
    }

    @Test func primitivesAtUnalignedAddressesRoundTrip() throws {
        let memory = TestSupport.TestGuestMemory()
        let pointer = UnsafeGuestRawPointer(offset: 3)
        try UInt64.writeToGuest(at: pointer, in: memory, value: 0x0102_0304_0506_0708)
        #expect(memory.read(count: 8, at: 3) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(try UInt64.readFromGuest(pointer, in: memory) == 0x0102_0304_0506_0708)
    }

    // MARK: - Vectored I/O

    /// The ABI returns a `u32` count, which 65537 buffers of 64 KiB overflow.
    @Test func aTransferLargerThanTheABICountSaturates() throws {
        let count = 65537
        let memory = TestSupport.TestGuestMemory(size: 1 << 20)
        let iovs = UnsafeGuestBufferPointer<WASIAbi.IOVec>(baseAddress: .init(offset: 0), count: UInt32(count))
        for index in 0..<UInt32(count) {
            try iovs.write(
                at: index, WASIAbi.IOVec(buffer: .init(offset: 0x8_0000), length: 0x1_0000), to: memory)
        }
        let buffers = GuestBuffers(iovs: iovs, memory: memory)
        #expect(try buffers.transfer { $0.count } == .max)
    }

    @Test func aShortTransferEndsTheVector() throws {
        let memory = TestSupport.TestGuestMemory()
        let buffers = GuestBuffers(iovs: try memory.readIOVecs(sizes: [4, 4]), memory: memory)
        var calls = 0
        #expect(
            try buffers.transfer { _ in
                calls += 1
                return 1
            } == 1)
        #expect(calls == 1)
    }

    @Test func anErrorAfterSomeBytesReportsTheBytes() throws {
        let memory = TestSupport.TestGuestMemory()
        let buffers = GuestBuffers(iovs: try memory.readIOVecs(sizes: [4, 4]), memory: memory)
        var calls = 0
        let total = try buffers.transfer { buffer in
            calls += 1
            guard calls == 1 else { throw WASIAbi.Errno.EAGAIN }
            return buffer.count
        }
        #expect(total == 4)
        #expect(throws: WASIAbi.Errno.EAGAIN) {
            _ = try buffers.transfer { _ in throw WASIAbi.Errno.EAGAIN }
        }
    }

    /// `transferBatches` has `transfer`'s results, a batch of buffers at a time.
    @Test func batchesSaturateAtTheABICount() throws {
        let count = 65537
        let memory = TestSupport.TestGuestMemory(size: 1 << 20)
        let iovs = UnsafeGuestBufferPointer<WASIAbi.IOVec>(baseAddress: .init(offset: 0), count: UInt32(count))
        for index in 0..<UInt32(count) {
            try iovs.write(
                at: index, WASIAbi.IOVec(buffer: .init(offset: 0x8_0000), length: 0x1_0000), to: memory)
        }
        let buffers = GuestBuffers(iovs: iovs, memory: memory)
        #expect(try buffers.transferBatches { $0.reduce(0) { $0 + $1.count } } == .max)
    }

    @Test func buffersAreBatched() throws {
        let memory = TestSupport.TestGuestMemory()
        let buffers = GuestBuffers(iovs: try memory.readIOVecs(sizes: [1, 2, 3, 4, 5]), memory: memory)
        var batches: [[Int]] = []
        let total = try buffers.transferBatches(batchSize: 2) { batch in
            batches.append(batch.map(\.count))
            return batch.reduce(0) { $0 + $1.count }
        }
        #expect(total == 15)
        #expect(batches == [[1, 2], [3, 4], [5]])
    }

    @Test func aShortBatchEndsTheVector() throws {
        let memory = TestSupport.TestGuestMemory()
        let buffers = GuestBuffers(iovs: try memory.readIOVecs(sizes: [4, 4, 4]), memory: memory)
        var calls = 0
        #expect(
            try buffers.transferBatches(batchSize: 2) { _ in
                calls += 1
                return 5
            } == 5)
        #expect(calls == 1)
    }

    @Test func anErrorAfterSomeBatchesReportsTheBytes() throws {
        let memory = TestSupport.TestGuestMemory()
        let buffers = GuestBuffers(iovs: try memory.readIOVecs(sizes: [4, 4]), memory: memory)
        var calls = 0
        let total = try buffers.transferBatches(batchSize: 1) { batch in
            calls += 1
            guard calls == 1 else { throw WASIAbi.Errno.EAGAIN }
            return batch[0].count
        }
        #expect(total == 4)
        #expect(throws: WASIAbi.Errno.EAGAIN) {
            _ = try buffers.transferBatches { _ in throw WASIAbi.Errno.EAGAIN }
        }
    }

    #if !os(Windows)
        /// Vectored reads and writes of a host file, at its position and at an offset.
        @Test func vectoredIOOnAHostFile() throws {
            let directory = try TestSupport.TemporaryDirectory()
            try directory.createFile(at: "file.txt", contents: "")
            let bridge = try WASIBridgeToHost(
                fileSystem: .host().withPreopens([.init(guestPath: "/", hostPath: directory.path)]))
            try bridge.runAndClose { bridge in
                let wasi = bridge.underlying
                let memory = TestSupport.TestGuestMemory()
                let fd = try wasi.path_open(
                    dirFd: 3, dirFlags: [], path: "file.txt", oflags: [],
                    fsRightsBase: [.FD_READ, .FD_WRITE, .FD_SEEK], fsRightsInheriting: [], fdflags: [])
                let pieces = ["abc", "", "defg", "h"].map { Array($0.utf8) }
                #expect(try wasi.fd_write(fileDescriptor: fd, ioVectors: try memory.writeIOVecs(pieces), memory: memory) == 8)
                #expect(try wasi.fd_pwrite(fd: fd, iovs: try memory.writeIOVecs([Array("XY".utf8), Array("Z".utf8)]), offset: 2, memory: memory) == 3)

                _ = try wasi.fd_seek(fd: fd, offset: 0, whence: .SET)
                let readVecs = try memory.readIOVecs(sizes: [2, 0, 5, 10])
                #expect(try wasi.fd_read(fd: fd, iovs: readVecs, memory: memory) == 8)
                #expect(Array(try memory.loadIOVecs(readVecs).joined().prefix(8)) == Array("abXYZfgh".utf8))

                let preadVecs = try memory.readIOVecs(sizes: [1, 2])
                #expect(try wasi.fd_pread(fd: fd, iovs: preadVecs, offset: 5, memory: memory) == 3)
                #expect(try memory.loadIOVecs(preadVecs).joined().map { $0 } == Array("fgh".utf8))
            }
        }
    #endif

    #if os(macOS) || os(Linux)
        /// Opening a FIFO blocks until it has a writer. Other descriptor calls go on meanwhile,
        /// as the open does not hold the descriptor table's lock.
        @Test func aBlockingOpenDoesNotBlockOtherCalls() throws {
            let directory = try TestSupport.TemporaryDirectory()
            let fifoPath = directory.url.appendingPathComponent("fifo").path
            #expect(mkfifo(fifoPath, 0o600) == 0)
            let bridge = try WASIBridgeToHost(
                fileSystem: .host().withPreopens([.init(guestPath: "/", hostPath: directory.path)]))
            try bridge.runAndClose { bridge in
                let wasi = bridge.underlying
                let opened = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = try? wasi.path_open(
                        dirFd: 3, dirFlags: [], path: "fifo", oflags: [], fsRightsBase: [.FD_READ],
                        fsRightsInheriting: [], fdflags: [])
                    opened.signal()
                }
                // Give the open time to block, then use the table from another thread.
                Thread.sleep(forTimeInterval: 0.1)
                let statted = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = try? wasi.fd_fdstat_get(fileDescriptor: 3)
                    statted.signal()
                }
                let stattedMeanwhile = statted.wait(timeout: .now() + 2) == .success
                #expect(stattedMeanwhile)
                #expect(opened.wait(timeout: .now()) == .timedOut)

                // A writer unblocks the open, and with it anything that waited for it.
                let writer = open(fifoPath, O_WRONLY)
                #expect(writer >= 0)
                #expect(opened.wait(timeout: .now() + 5) == .success)
                close(writer)
                if !stattedMeanwhile { _ = statted.wait(timeout: .now() + 5) }
            }
        }
    #endif

    // MARK: - Directory entries

    #if !os(Windows)
        /// Listing a directory through a buffer too small for it, as wasi-libc does: each call
        /// continues from the cookie of the last entry that fit, which the next call either
        /// continues the kept stream at or replays.
        @Test func aDirectoryIsListedAcrossCallsOnce() throws {
            let directory = try TestSupport.TemporaryDirectory()
            let names = (0..<40).map { "file-\($0)-" + String(repeating: "x", count: $0 % 7) }
            for name in names { try directory.createFile(at: name, contents: "") }
            let bridge = try WASIBridgeToHost(
                fileSystem: .host().withPreopens([.init(guestPath: "/", hostPath: directory.path)]))
            try bridge.runAndClose { bridge in
                let wasi = bridge.underlying
                let memory = TestSupport.TestGuestMemory()
                let bufferSize: UInt32 = 100
                let buffer = UnsafeGuestBufferPointer<UInt8>(baseAddress: .init(offset: 0x1000), count: bufferSize)
                var cookie: WASIAbi.DirCookie = 0
                var listed: [String] = []
                var calls = 0
                while true {
                    calls += 1
                    let used = try wasi.fd_readdir(fd: 3, buffer: buffer, cookie: cookie, memory: memory)
                    let bytes = memory.read(count: Int(used), at: 0x1000)
                    var offset = 0
                    // Entries that fit whole: a 24-byte dirent, then the name.
                    while offset + 24 <= bytes.count {
                        let next = bytes[offset..<offset + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                        let nameLength = Int(bytes[offset + 16..<offset + 20].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                        guard offset + 24 + nameLength <= bytes.count else { break }
                        listed.append(String(decoding: bytes[offset + 24..<offset + 24 + nameLength], as: UTF8.self))
                        cookie = next
                        offset += 24 + nameLength
                    }
                    guard used == bufferSize else { break }
                    #expect(calls < 100)
                }
                #expect(listed.sorted() == (names + [".", ".."]).sorted())
            }
        }
    #endif

    @Test func aDirentCutShortStaysInsideItsBuffer() throws {
        let memory = TestSupport.TestGuestMemory()
        memory.write([0xAA, 0xAA], at: 3)
        let dirent = WASIAbi.Dirent(dNext: .max, dIno: .max, dirNameLen: .max, dType: .REGULAR_FILE)
        try WASIAbi.Dirent.writeToGuest(
            unalignedAt: .init(offset: 0), end: .init(offset: 3), in: memory, value: dirent)
        #expect(memory.read(count: 5, at: 0) == [0xFF, 0xFF, 0xFF, 0xAA, 0xAA])
    }

    // MARK: - Timestamps

    @Test func aTimestampPastTheABIRangeSaturates() {
        let time = FileTime(seconds: Int(Int64.max / 2), nanoseconds: 999_999_999)
        #expect(WASIAbi.Timestamp(platformTimeSpec: time) == .max)
    }

    // MARK: - Symlinks

    #if !os(Windows)
        private func withHostDirectory(
            _ body: (WASIImplementation, TestSupport.TemporaryDirectory) throws -> Void
        ) throws {
            let directory = try TestSupport.TemporaryDirectory()
            let bridge = try WASIBridgeToHost(
                fileSystem: .host().withPreopens([.init(guestPath: "/dir", hostPath: directory.path)]))
            try bridge.runAndClose { try body($0.underlying, directory) }
        }

        /// Following a link to a host path would reveal that file's size, inode and times.
        @Test func statFollowingALinkOutOfThePreopenIsRefused() throws {
            try withHostDirectory { wasi, directory in
                try directory.createFile(at: "inside.txt", contents: "12345")
                try directory.createSymlink(at: "escape", to: "/etc/hosts")
                try directory.createSymlink(at: "updown", to: "../escape")
                try directory.createSymlink(at: "inside", to: "inside.txt")
                try directory.createSymlink(at: "chain", to: "inside")
                try directory.createSymlink(at: "loop", to: "loop")
                #expect(throws: WASIAbi.Errno.EPERM) {
                    _ = try wasi.path_filestat_get(dirFd: 3, flags: .SYMLINK_FOLLOW, path: "escape")
                }
                #expect(throws: WASIAbi.Errno.EPERM) {
                    _ = try wasi.path_filestat_get(dirFd: 3, flags: .SYMLINK_FOLLOW, path: "updown")
                }
                #expect(throws: WASIAbi.Errno.ELOOP) {
                    _ = try wasi.path_filestat_get(dirFd: 3, flags: .SYMLINK_FOLLOW, path: "loop")
                }
                // The link itself, and links that stay inside, still work.
                #expect(try wasi.path_filestat_get(dirFd: 3, flags: [], path: "escape").filetype == .SYMBOLIC_LINK)
                #expect(try wasi.path_filestat_get(dirFd: 3, flags: .SYMLINK_FOLLOW, path: "chain").size == 5)
            }
        }

        @Test func anAbsoluteSymlinkTargetIsRefused() throws {
            try withHostDirectory { wasi, _ in
                #expect(throws: WASIAbi.Errno.EPERM) {
                    try wasi.path_symlink(oldPath: "/etc/hosts", dirFd: 3, newPath: "escape")
                }
            }
        }

        /// Lookup flags only govern the final component: `l/f` opens through the link `l`.
        @Test func anIntermediateSymlinkIsFollowedWithoutTheFollowFlag() throws {
            try withHostDirectory { wasi, directory in
                try directory.createDir(at: "d")
                try directory.createFile(at: "d/f", contents: "x")
                try directory.createSymlink(at: "l", to: "d")
                let fd = try wasi.path_open(
                    dirFd: 3, dirFlags: [], path: "l/f", oflags: [],
                    fsRightsBase: .FD_READ, fsRightsInheriting: [], fdflags: [])
                try wasi.fd_close(fd: fd)
            }
        }
    #endif
}
