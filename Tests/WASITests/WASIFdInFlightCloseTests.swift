import Dispatch
import Foundation
import Synchronization
import Testing
import WasmTypes

@_spi(WASIPlatform) @testable import WASI

/// With wasi-threads, one guest thread can close or renumber a descriptor while
/// another is still inside a call on it. Closing the host resource then would
/// let the host reuse its descriptor number, and the in-flight call would act on
/// whatever the host opened next, so the close waits for the call to return.
@Suite struct WASIFdInFlightCloseTests {

    /// An owned file whose `write` blocks until the test lets it finish.
    final class GatedFile: WASIFile, Sendable {
        let closed = Mutex(false)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        /// Whether the file was already closed while a write was in progress.
        let closedDuringWrite = Mutex(false)

        var isClosed: Bool { closed.withLock { $0 } }

        func attributes() throws -> WASIAbi.Filestat {
            WASIAbi.Filestat(dev: 0, ino: 0, filetype: .CHARACTER_DEVICE, nlink: 0, size: 0, atim: 0, mtim: 0, ctim: 0)
        }
        func fileType() throws -> WASIAbi.FileType { .CHARACTER_DEVICE }
        func status() throws -> WASIAbi.Fdflags { [] }
        func setTimes(atim: WASIAbi.Timestamp, mtim: WASIAbi.Timestamp, fstFlags: WASIAbi.FstFlags) throws {}
        func advise(offset: WASIAbi.FileSize, length: WASIAbi.FileSize, advice: WASIAbi.Advice) throws {}
        func close() throws { closed.withLock { $0 = true } }
        func fdStat() throws -> WASIAbi.FdStat {
            WASIAbi.FdStat(fsFileType: .CHARACTER_DEVICE, fsFlags: [], fsRightsBase: .FD_WRITE, fsRightsInheriting: [])
        }
        func setFdStatFlags(_ flags: WASIAbi.Fdflags) throws {}
        func setFilestatSize(_ size: WASIAbi.FileSize) throws { throw WASIAbi.Errno.ENOTSUP }
        func sync() throws {}
        func datasync() throws {}
        func tell() throws -> WASIAbi.FileSize { 0 }
        func seek(offset: WASIAbi.FileDelta, whence: WASIAbi.Whence) throws -> WASIAbi.FileSize {
            throw WASIAbi.Errno.ESPIPE
        }
        func write(vectored buffers: GuestBuffers) throws -> WASIAbi.Size {
            entered.signal()
            proceed.wait()
            if isClosed { closedDuringWrite.withLock { $0 = true } }
            return 7
        }
        func pwrite(vectored buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size { 0 }
        func read(into buffers: GuestBuffers) throws -> WASIAbi.Size { 0 }
        func pread(into buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size { 0 }
    }

    /// Starts `fd_write` on fd 1 on another thread and returns once it is
    /// blocked inside the file, along with a function that lets it finish and
    /// returns its result.
    private func startBlockedWrite(
        _ wasi: WASIImplementation, _ file: GatedFile
    ) -> () -> Result<UInt32, any Error> {
        let result = Mutex<Result<UInt32, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let memory = TestSupport.TestGuestMemory()
            let iovs = UnsafeGuestBufferPointer<WASIAbi.IOVec>(baseAddress: .init(offset: 0), count: 0)
            let outcome = Result { try wasi.fd_write(fileDescriptor: 1, ioVectors: iovs, memory: memory) }
            result.withLock { $0 = outcome }
            finished.signal()
        }
        file.entered.wait()
        return {
            file.proceed.signal()
            finished.wait()
            return result.withLock { $0! }
        }
    }

    private func withGatedStdout(
        _ body: (WASIImplementation, GatedFile) throws -> Void
    ) throws {
        let fs = try MemoryFileSystem()
        try fs.ensureDirectory(at: "/dir")
        try fs.addFile(at: "/dir/a.txt", content: "a")
        let stdout = GatedFile()
        let bridge = try WASIBridgeToHost(
            fileSystem: .memory(fs)
                .withStdio(stdin: GatedFile(), stdout: stdout, stderr: GatedFile())
                .withPreopens([.init(guestPath: "/dir", hostPath: "/dir")])
        )
        try bridge.runAndClose { try body($0.underlying, stdout) }
    }

    @Test func closeWaitsForAnInFlightWrite() throws {
        try withGatedStdout { wasi, stdout in
            let finishWrite = startBlockedWrite(wasi, stdout)

            try wasi.fd_close(fd: 1)
            // The descriptor is gone for the guest at once...
            #expect(throws: WASIAbi.Errno.EBADF) { _ = try wasi.fd_fdstat_get(fileDescriptor: 1) }
            // ...but the resource stays open for the write already using it.
            #expect(!stdout.isClosed)

            #expect(try finishWrite().get() == 7)
            #expect(stdout.closedDuringWrite.withLock { $0 } == false)
            #expect(stdout.isClosed)
        }
    }

    @Test func renumberWaitsForAnInFlightWriteOnTheDisplacedDescriptor() throws {
        try withGatedStdout { wasi, stdout in
            let fd = try wasi.path_open(
                dirFd: 3, dirFlags: [], path: "a.txt", oflags: [],
                fsRightsBase: [.FD_READ], fsRightsInheriting: [], fdflags: [])
            let finishWrite = startBlockedWrite(wasi, stdout)

            try wasi.fd_renumber(fd: fd, to: 1)
            #expect(try wasi.fd_fdstat_get(fileDescriptor: 1).fsFileType == .REGULAR_FILE)
            #expect(!stdout.isClosed)

            #expect(try finishWrite().get() == 7)
            #expect(stdout.closedDuringWrite.withLock { $0 } == false)
            #expect(stdout.isClosed)
        }
    }

    /// The descriptor a call is using can be renumbered under it: the call
    /// keeps the same resource, which is not closed because it is still in the
    /// table under its new number.
    @Test func renumberingTheInFlightDescriptorKeepsItOpen() throws {
        try withGatedStdout { wasi, stdout in
            let finishWrite = startBlockedWrite(wasi, stdout)

            try wasi.fd_renumber(fd: 1, to: 2)
            #expect(try finishWrite().get() == 7)
            #expect(!stdout.isClosed)
            #expect(try wasi.fd_fdstat_get(fileDescriptor: 2).fsFileType == .CHARACTER_DEVICE)
        }
    }

    @Test func teardownWaitsForAnInFlightWrite() throws {
        let fs = try MemoryFileSystem()
        let stdout = GatedFile()
        let bridge = try WASIBridgeToHost(
            fileSystem: .memory(fs).withStdio(stdin: GatedFile(), stdout: stdout, stderr: GatedFile())
        )
        let finishWrite = startBlockedWrite(bridge.underlying, stdout)
        try bridge.close()
        #expect(!stdout.isClosed)
        #expect(try finishWrite().get() == 7)
        #expect(stdout.closedDuringWrite.withLock { $0 } == false)
        #expect(stdout.isClosed)
    }

    #if os(macOS) || os(Linux)
        /// The same for a host descriptor, which is what the host could reuse.
        @Test(.disabled(if: TestSupport.hostPreopensUnavailable, "host preopens are not available on this platform"))
        func closeKeepsAnInFlightHostDescriptorOpen() throws {
            let directory = try TestSupport.TemporaryDirectory()
            try directory.createFile(at: "out.txt", contents: "")
            let bridge = try WASIBridgeToHost(
                fileSystem: .host().withPreopens([.init(guestPath: "/", hostPath: directory.url.path)])
            )
            try bridge.runAndClose { bridge in
                let wasi = bridge.underlying
                let fd = try wasi.path_open(
                    dirFd: 3, dirFlags: [], path: "out.txt", oflags: [],
                    fsRightsBase: [.FD_WRITE], fsRightsInheriting: [], fdflags: [])
                guard case .file(let file) = wasi.fdTable.withLock({ $0[fd] }), let hostFd = file.hostFileDescriptor else {
                    Issue.record("expected a host file at fd \(fd)")
                    return
                }
                // Hold the descriptor as an in-flight call would.
                let slot = try #require(wasi.fdTable.withLock { $0.acquire(fd) })
                try wasi.fd_close(fd: fd)
                #expect(fcntl(hostFd, F_GETFD) != -1)

                let toClose = wasi.fdTable.withLock { $0.release(slot) }
                try #require(toClose).asEntry().close()
                #expect(fcntl(hostFd, F_GETFD) == -1)
            }
        }
    #endif
}
