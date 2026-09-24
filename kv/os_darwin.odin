package kv

import "core:c"
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

// Releases a committed range of the dirty-page pool: its memory leaves the
// process at once, and the range is reserved but inaccessible again.
// Anonymous memory mapped over it with MAP_FIXED is the only call that drops
// both the resident size and the footprint at once on macOS; MADV_FREE and
// MADV_DONTNEED drop neither, and MADV_FREE_REUSABLE only the footprint
// (measured in KV-T-0019).
os_pool_release :: proc(addr: rawptr, size: int) -> Error {
	p := posix.mmap(addr, c.size_t(size), {}, {.PRIVATE, .ANONYMOUS, .FIXED}, -1, 0)
	if p == posix.MAP_FAILED {
		return .Io
	}
	return .None
}
