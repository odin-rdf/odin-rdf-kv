package kv

import "core:sys/posix"

// Not exposed by core:sys/posix. See fcntl(2) on macOS.
@(private = "file")
F_FULLFSYNC :: 51

// Flushes the file's data to stable storage. On macOS a plain fsync only
// reaches the drive's cache; F_FULLFSYNC asks the drive to flush it too.
os_sync :: proc(fd: posix.FD) -> Error {
	if posix.fcntl(fd, posix.FCNTL_Cmd(F_FULLFSYNC)) != -1 {
		return .None
	}
	// Some filesystems (network and FUSE mounts, for example) don't support
	// F_FULLFSYNC. Fall back to fsync, which reports any real I/O error.
	if posix.fsync(fd) != .OK {
		return .Io
	}
	return .None
}
