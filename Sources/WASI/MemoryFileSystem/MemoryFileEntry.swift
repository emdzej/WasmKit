import WasmTypes

/// A `WASIFile` for regular files.
///
/// Holds the file node by reference, so an fd opened before the file is unlinked
/// keeps working until its last close. Content is synchronized by the node; only
/// the per-fd `position` lives here.
final class MemoryFileEntry: WASIFile {
    let fileNode: MemoryFileNode
    let fileSystem: MemoryFileSystem
    let accessMode: FileAccessMode
    // See `WASIImplementation.fdTable` for why this is a `nonisolated(unsafe) var`.
    nonisolated(unsafe) var position: PlatformMutex<Int>
    /// The descriptor's flags. Only `APPEND` changes what memfs does: every write then goes to
    /// the end of the file.
    nonisolated(unsafe) var flags: PlatformMutex<WASIAbi.Fdflags>

    init(
        fileNode: MemoryFileNode, fileSystem: MemoryFileSystem, accessMode: FileAccessMode, position: Int = 0,
        flags: WASIAbi.Fdflags = []
    ) {
        self.fileNode = fileNode
        self.fileSystem = fileSystem
        self.accessMode = accessMode
        self.position = PlatformMutex(position)
        self.flags = PlatformMutex(flags)
    }

    // MARK: - WASIEntry

    func attributes() throws -> WASIAbi.Filestat {
        let timestamps = fileNode.timestamps
        return WASIAbi.Filestat(
            dev: 0, ino: 0, filetype: .REGULAR_FILE,
            nlink: 1, size: WASIAbi.FileSize(try fileNode.size),
            atim: timestamps.atim, mtim: timestamps.mtim, ctim: timestamps.ctim
        )
    }

    func fileType() throws -> WASIAbi.FileType {
        return .REGULAR_FILE
    }

    func status() throws -> WASIAbi.Fdflags {
        flags.withLock { $0 }
    }

    func setTimes(
        atim: WASIAbi.Timestamp, mtim: WASIAbi.Timestamp,
        fstFlags: WASIAbi.FstFlags
    ) throws {
        let now = WASIAbi.Timestamp.currentWallClock()
        let newAtim: WASIAbi.Timestamp?
        if fstFlags.contains(.ATIM) {
            newAtim = atim
        } else if fstFlags.contains(.ATIM_NOW) {
            newAtim = now
        } else {
            newAtim = nil
        }

        let newMtim: WASIAbi.Timestamp?
        if fstFlags.contains(.MTIM) {
            newMtim = mtim
        } else if fstFlags.contains(.MTIM_NOW) {
            newMtim = now
        } else {
            newMtim = nil
        }

        fileNode.setTimes(atim: newAtim, mtim: newMtim)
    }

    func advise(
        offset: WASIAbi.FileSize, length: WASIAbi.FileSize, advice: WASIAbi.Advice
    ) throws {
        // No-op for memory filesystem
    }

    func close() throws {
        // No-op: the node is ARC-owned, so there is nothing to release here.
    }

    // MARK: - WASIFile

    func fdStat() throws -> WASIAbi.FdStat {
        var fsRightsBase: WASIAbi.Rights = []
        if accessMode.contains(.read) {
            fsRightsBase.insert(.FD_READ)
            fsRightsBase.insert(.FD_SEEK)
            fsRightsBase.insert(.FD_TELL)
        }
        if accessMode.contains(.write) {
            fsRightsBase.insert(.FD_WRITE)
        }

        return WASIAbi.FdStat(
            fsFileType: .REGULAR_FILE,
            fsFlags: try status(),
            fsRightsBase: fsRightsBase,
            fsRightsInheriting: []
        )
    }

    func setFdStatFlags(_ flags: WASIAbi.Fdflags) throws {
        self.flags.withLock { $0 = flags }
    }

    func setFilestatSize(_ size: WASIAbi.FileSize) throws {
        try fileNode.setFilestatSize(size)
    }

    func sync() throws {
        if let handle = fileNode.handle {
            try handle.sync()
        }
    }

    func datasync() throws {
        if let handle = fileNode.handle {
            try handle.datasync()
        }
    }

    func tell() throws -> WASIAbi.FileSize {
        position.withLock { WASIAbi.FileSize($0) }
    }

    func seek(offset: WASIAbi.FileDelta, whence: WASIAbi.Whence) throws -> WASIAbi.FileSize {
        try position.withLock { pos -> WASIAbi.FileSize in
            let prep = fileNode.seekPrep()

            // Reads and writes use `pos` with `pread`/`pwrite`, even on a host handle, and never
            // move the handle's own offset, which other entries share. So seeking is computed
            // from `pos` here as well; only `END` asks the host for the size.
            let base: Int
            switch whence {
            case .SET: base = 0
            case .CUR: base = pos
            case .END:
                if let handle = prep.handle {
                    guard let size = Int(exactly: try handle.attributes().size) else { throw WASIAbi.Errno.EOVERFLOW }
                    base = size
                } else {
                    base = prep.byteCount
                }
            }
            // The delta is signed and guest-chosen, so the sum can run off
            // either end of the range a position is expressed in.
            guard let delta = Int(exactly: offset) else {
                throw WASIAbi.Errno.EINVAL
            }
            let (newPosition, overflow) = base.addingReportingOverflow(delta)
            guard !overflow, newPosition >= 0 else {
                throw WASIAbi.Errno.EINVAL
            }
            pos = newPosition
            return WASIAbi.FileSize(newPosition)
        }
    }

    func write(vectored buffers: GuestBuffers) throws -> WASIAbi.Size {
        guard accessMode.contains(.write) else {
            throw WASIAbi.Errno.EBADF
        }
        let append = try status().contains(.APPEND)
        return try position.withLock { pos in
            let result = try fileNode.write(vectored: buffers, position: pos, append: append)
            pos = result.newPosition
            return result.count
        }
    }

    func pwrite(vectored buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size {
        guard accessMode.contains(.write) else {
            throw WASIAbi.Errno.EBADF
        }
        guard let offset = Int(exactly: offset) else {
            throw WASIAbi.Errno.EINVAL
        }
        return try fileNode.pwrite(vectored: buffers, offset: offset)
    }

    func read(into buffers: GuestBuffers) throws -> WASIAbi.Size {
        guard accessMode.contains(.read) else {
            throw WASIAbi.Errno.EBADF
        }
        return try position.withLock { pos in
            let result = try fileNode.read(into: buffers, position: pos)
            pos = result.newPosition
            return result.count
        }
    }

    func pread(into buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size {
        guard accessMode.contains(.read) else {
            throw WASIAbi.Errno.EBADF
        }
        guard let offset = Int(exactly: offset) else {
            throw WASIAbi.Errno.EINVAL
        }
        return try fileNode.pread(into: buffers, offset: offset)
    }
}
