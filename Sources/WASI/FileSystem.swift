import WasmTypes

/// The requested access mode for an opened file.
@_spi(WASIPlatform) public struct FileAccessMode: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = FileAccessMode(rawValue: 1)
    public static let write = FileAccessMode(rawValue: 1 << 1)
}

/// A resource installed in the WASI file descriptor table.
///
/// This protocol (and its refinements ``WASIFile``/``WASIDir``) is the
/// platform-independent boundary of the WASI host implementation: all
/// requirements are expressed in `WASIAbi` types, so implementations can be
/// backed by anything from host file descriptors to in-memory data or
/// device drivers on embedded systems. Implementations report failures by
/// throwing `WASIAbi.Errno`.
@_spi(WASIPlatform) public protocol WASIEntry: Sendable {
    /// Whether this entry wraps a borrowed file descriptor that should not be
    /// closed when the WASI instance is torn down (e.g. process stdio).
    var isBorrowed: Bool { get }
    func attributes() throws -> WASIAbi.Filestat
    func fileType() throws -> WASIAbi.FileType
    func status() throws -> WASIAbi.Fdflags
    func setTimes(
        atim: WASIAbi.Timestamp, mtim: WASIAbi.Timestamp,
        fstFlags: WASIAbi.FstFlags
    ) throws
    func advise(
        offset: WASIAbi.FileSize, length: WASIAbi.FileSize, advice: WASIAbi.Advice
    ) throws
    func close() throws

    /// The host file descriptor backing this entry, if it has one.
    ///
    /// `poll_oneoff` can only wait on real descriptors; entries without one
    /// (in-memory files, devices) report `nil`.
    var hostFileDescriptor: CInt? { get }
}

extension WASIEntry {
    @_spi(WASIPlatform) public var isBorrowed: Bool { false }
    @_spi(WASIPlatform) public var hostFileDescriptor: CInt? { nil }
}

/// A file-like resource (regular file, stdio stream, device, ...) exposed
/// to WASI guests.
@_spi(WASIPlatform) public protocol WASIFile: WASIEntry {
    func fdStat() throws -> WASIAbi.FdStat
    func setFdStatFlags(_ flags: WASIAbi.Fdflags) throws
    func setFilestatSize(_ size: WASIAbi.FileSize) throws
    func sync() throws
    func datasync() throws

    func tell() throws -> WASIAbi.FileSize
    func seek(offset: WASIAbi.FileDelta, whence: WASIAbi.Whence) throws -> WASIAbi.FileSize

    func write(vectored buffers: GuestBuffers) throws -> WASIAbi.Size
    func pwrite(vectored buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size
    func read(into buffers: GuestBuffers) throws -> WASIAbi.Size
    func pread(into buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size
}

/// A directory-like resource exposed to WASI guests.
@_spi(WASIPlatform) public protocol WASIDir: WASIEntry {
    typealias ReaddirElement = WASIReaddirElement

    var preopenPath: String? { get }

    func readlink(atPath path: String) throws -> [UInt8]

    func createDirectory(atPath path: String) throws
    func removeDirectory(atPath path: String) throws
    func removeFile(atPath path: String) throws
    func symlink(from sourcePath: String, to destPath: String) throws
    func rename(from sourcePath: String, toDir newDir: any WASIDir, to destPath: String) throws
    func readEntries(cookie: WASIAbi.DirCookie) throws -> WASIReaddirEntries
    func attributes(path: String, symlinkFollow: Bool) throws -> WASIAbi.Filestat
    func setFilestatTimes(
        path: String,
        atim: WASIAbi.Timestamp, mtim: WASIAbi.Timestamp,
        fstFlags: WASIAbi.FstFlags, symlinkFollow: Bool
    ) throws
}

/// A single directory entry.
@_spi(WASIPlatform) public typealias WASIReaddirElement = (dirent: WASIAbi.Dirent, name: String)

/// A type-erased iterator over directory entries.
///
/// Concrete rather than an associated type so that ``WASIDir`` carries no
/// generic requirements. ``FdEntry`` stores directories as `any WASIDir`, and
/// Embedded Swift cannot specialise a generic method reached through an
/// existential.
@_spi(WASIPlatform) public struct WASIReaddirEntries {
    private final class Box<I: WASIReaddirIterator> where I.Element == WASIReaddirElement {
        var iterator: I
        init(_ iterator: I) { self.iterator = iterator }
    }

    private let nextEntry: () -> Result<WASIReaddirElement, any Error>?
    private let closeIterator: () -> Void

    public init<I: WASIReaddirIterator>(_ iterator: I) where I.Element == WASIReaddirElement {
        let box = Box(iterator)
        self.nextEntry = { box.iterator.next() }
        self.closeIterator = { box.iterator.close() }
    }

    public mutating func next() -> Result<WASIReaddirElement, any Error>? { nextEntry() }

    /// Closes the iterator and releases any owned resources.
    ///
    /// Callers must invoke this exactly once after iteration completes.
    public mutating func close() { closeIterator() }
}

/// An iterator over directory entries produced by ``WASIDir/readEntries(cookie:)``.
@_spi(WASIPlatform) public protocol WASIReaddirIterator {
    associatedtype Element
    mutating func next() -> Result<Element, any Error>?
    /// Closes the iterator and releases any owned resources.
    ///
    /// Callers must invoke this exactly once after iteration completes.
    mutating func close()
}

/// A file descriptor table entry: either a file or a directory resource.
@_spi(WASIPlatform) public enum FdEntry: Sendable {
    case file(any WASIFile)
    case directory(any WASIDir)

    func asEntry() -> any WASIEntry {
        switch self {
        case .file(let entry):
            return entry
        case .directory(let directory):
            return directory
        }
    }

    func asFile() -> (any WASIFile)? {
        if case .file(let entry) = self {
            return entry
        }
        return nil
    }
}

/// A file descriptor table slot: an entry and the WASI calls still using it.
///
/// A call holds its slot from lookup until its I/O returns, so a concurrent
/// `fd_close` or `fd_renumber` from another guest thread cannot close the
/// resource underneath it. Closing a host descriptor mid-call would let the
/// host reuse its number, and the in-flight call would then act on whatever
/// the host opened next. Instead, removal from the table only retires the
/// slot, and the resource is closed when its last user releases it.
final class FdSlot: Sendable {
    let entry: FdEntry
    // Guarded by the `FdTable` lock; see `WASIImplementation.fdTable` for why
    // this is `nonisolated(unsafe)`.
    nonisolated(unsafe) fileprivate var users = 0
    nonisolated(unsafe) fileprivate var isRetired = false

    fileprivate init(_ entry: FdEntry) {
        self.entry = entry
    }
}

/// A table that maps file descriptor to actual resource in host environment
///
/// Every method must be called with the table's lock held, including those
/// that only touch an ``FdSlot``.
struct FdTable {
    private var map: [WASIAbi.Fd: FdSlot]
    private var nextFd: WASIAbi.Fd

    init() {
        self.map = [:]
        // 0, 1 and 2 are reserved for stdio
        self.nextFd = 3
    }

    /// Inserts a resource as the given file descriptor
    subscript(_ fd: WASIAbi.Fd) -> FdEntry? {
        get { self.map[fd]?.entry }
        set { self.map[fd] = newValue.map(FdSlot.init) }
    }

    /// Whether another descriptor can be installed, i.e. the table is below capacity.
    var hasCapacity: Bool {
        map.count < WASIAbi.Fd.max
    }

    /// Inserts an entry and returns the corresponding file descriptor
    mutating func push(_ entry: FdEntry) throws -> WASIAbi.Fd {
        guard hasCapacity else {
            throw WASIAbi.Errno.ENFILE
        }
        // Find a free fd
        while true {
            let fd = self.nextFd
            // Wrapping to find fd again from 0 after overflow
            self.nextFd &+= 1
            if self.map[fd] != nil {
                continue
            }
            self.map[fd] = FdSlot(entry)
            return fd
        }
    }

    /// Marks the slot at `fd` as in use until a matching ``release(_:)``.
    func acquire(_ fd: WASIAbi.Fd) -> FdSlot? {
        guard let slot = map[fd] else { return nil }
        slot.users += 1
        return slot
    }

    /// Ends a use begun by ``acquire(_:)``. Returns the entry to close when
    /// this was the last use of a slot already removed from the table.
    func release(_ slot: FdSlot) -> FdEntry? {
        slot.users -= 1
        return slot.users == 0 && slot.isRetired ? slot.entry : nil
    }

    /// Removes `fd` from the table. Returns the entry to close now, or `nil`
    /// when it is borrowed or still in use, in which case the last
    /// ``release(_:)`` returns it instead.
    mutating func remove(_ fd: WASIAbi.Fd) throws(WASIAbi.Errno) -> FdEntry? {
        guard let slot = map.removeValue(forKey: fd) else {
            throw WASIAbi.Errno.EBADF
        }
        return retire(slot)
    }

    /// Moves the slot at `fd` to `toFd`, removing the slot `toFd` held.
    /// Returns the displaced entry to close now, as ``remove(_:)`` does.
    mutating func renumber(_ fd: WASIAbi.Fd, to toFd: WASIAbi.Fd) throws(WASIAbi.Errno) -> FdEntry? {
        guard let slot = map[fd], let displaced = map[toFd] else {
            throw WASIAbi.Errno.EBADF
        }
        // Renumbering a descriptor onto itself leaves it in place; clearing
        // the source would otherwise destroy the entry it just installed.
        guard fd != toFd else { return nil }
        // In-flight calls that looked up `fd` keep using the same slot, which
        // stays open under its new number.
        map[toFd] = slot
        map[fd] = nil
        return retire(displaced)
    }

    /// A borrowed entry (e.g. process stdio) wraps a resource the embedder
    /// owns and outlives the guest, so it is never closed.
    private func retire(_ slot: FdSlot) -> FdEntry? {
        guard !slot.entry.asEntry().isBorrowed else { return nil }
        slot.isRetired = true
        return slot.users == 0 ? slot.entry : nil
    }

    /// Closes all owned file descriptors, skipping borrowed ones (e.g. stdio).
    /// One still in use by a call is closed when that call releases it.
    mutating func closeAll() throws {
        var firstError: (any Error)?
        for (_, slot) in map {
            guard let entry = retire(slot) else { continue }
            do {
                try entry.asEntry().close()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        map = map.filter { $0.value.entry.asEntry().isBorrowed }
        if let firstError { throw firstError }
    }
}

/// Content of a file that can be retrieved from the file system.
public enum FileContent: Sendable {
    case bytes([UInt8])
    /// A caller-owned platform file descriptor. The file system borrows it:
    /// the caller is responsible for keeping it valid and closing it.
    case handle(CInt)
}

/// Protocol for file system implementations used by WASI.
///
/// The built-in implementations are ``MemoryFileSystem`` and the host file
/// system used by `FileSystemOptions.host()`. Custom implementations can be
/// injected with `FileSystemOptions.custom(_:)` to run WASI guests on
/// platforms without a usable host file system (e.g. embedded targets).
/// All requirements are expressed in `WASIAbi` and standard Swift types;
/// implementations report failures by throwing `WASIAbi.Errno`.
@_spi(WASIPlatform) public protocol FileSystemImplementation: ~Copyable, Sendable {
    /// Preopens a directory and returns a WASIDir implementation.
    func preopenDirectory(guestPath: String, hostPath: String) throws -> any WASIDir

    /// Opens a file or directory from a directory file descriptor.
    func openAt(
        dirFd: any WASIDir,
        path: String,
        oflags: WASIAbi.Oflags,
        fsRightsBase: WASIAbi.Rights,
        fsRightsInheriting: WASIAbi.Rights,
        fdflags: WASIAbi.Fdflags,
        symlinkFollow: Bool
    ) throws -> FdEntry
}
