import WasmTypes

protocol FdWASIEntry: WASIEntry {
    var fd: FileDescriptor { get }
}

extension FdWASIEntry {
    var hostFileDescriptor: CInt? { fd.rawValue }
}

protocol FdWASIFile: WASIFile, FdWASIEntry {
    var accessMode: FileAccessMode { get }
}

extension FdWASIFile {
    func fdStat() throws -> WASIAbi.FdStat {
        var fsRightsBase: WASIAbi.Rights = []
        if accessMode.contains(.read) {
            fsRightsBase.insert(.FD_READ)
        }
        if accessMode.contains(.write) {
            fsRightsBase.insert(.FD_WRITE)
        }
        return try WASIAbi.FdStat(
            fsFileType: self.fileType(),
            fsFlags: self.status(),
            fsRightsBase: fsRightsBase, fsRightsInheriting: []
        )
    }

    func sync() throws {
        try fd.sync()
    }

    func datasync() throws {
        try fd.datasync()
    }

    @inlinable
    func write(vectored buffers: GuestBuffers) throws -> WASIAbi.Size {
        guard accessMode.contains(.write) else {
            throw WASIAbi.Errno.EBADF
        }
        // TODO: Use `writev`
        return try buffers.transfer { try fd.write(UnsafeRawBufferPointer($0)) }
    }

    @inlinable
    func pwrite(vectored buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size {
        // TODO: Use `pwritev`
        var currentOffset = try WASIAbi.hostOffset(offset)
        return try buffers.transfer {
            let nwritten = try fd.writeAll(toAbsoluteOffset: currentOffset, $0)
            currentOffset += Int64(nwritten)
            return nwritten
        }
    }

    @inlinable
    func read(into buffers: GuestBuffers) throws -> WASIAbi.Size {
        // `path_open` may omit FD_READ, but `openat` needs an access mode, so
        // the host descriptor underneath is readable even then.
        guard accessMode.contains(.read) else {
            throw WASIAbi.Errno.EBADF
        }
        return try buffers.transfer { try fd.read(into: $0) }
    }

    @inlinable
    func pread(into buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size {
        // TODO: Use `preadv`
        guard accessMode.contains(.read) else {
            throw WASIAbi.Errno.EBADF
        }
        var currentOffset = try WASIAbi.hostOffset(offset)
        return try buffers.transfer {
            let count = try fd.read(fromAbsoluteOffset: currentOffset, into: $0)
            currentOffset += Int64(count)
            return count
        }
    }
}

struct RegularFileEntry: FdWASIFile {
    let fd: FileDescriptor
    let accessMode: FileAccessMode
}

extension FdWASIFile {
    func setFdStatFlags(_ flags: WASIAbi.Fdflags) throws {
        try fd.setStatus(flags.platformOpenOptions)
    }
}

struct StdioFileEntry: FdWASIFile {
    let fd: FileDescriptor
    let accessMode: FileAccessMode

    let isBorrowed: Bool = true

    func attributes() throws -> WASIAbi.Filestat {
        return WASIAbi.Filestat(
            dev: 0, ino: 0, filetype: .CHARACTER_DEVICE,
            nlink: 0, size: 0, atim: 0, mtim: 0, ctim: 0
        )
    }
}
