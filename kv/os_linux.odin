package kv

import "core:c"
import "core:sys/posix"

// Flushes the file's data, and the metadata needed to read it back (such as
// its size), to stable storage.
os_sync :: proc(fd: posix.FD) -> Error {
	if posix.fdatasync(fd) != .OK {
		return .Io
	}
	return .None
}

foreign import libc "system:c"

// Called directly: glibc's posix_madvise ignores POSIX_MADV_DONTNEED.
@(private = "file")
foreign libc {
	madvise :: proc(addr: rawptr, len: c.size_t, advice: c.int) -> c.int ---
}

@(private = "file")
MADV_DONTNEED :: 4

// Releases a committed range of the dirty-page pool: its memory leaves the
// process at once, and the range is reserved but inaccessible again.
// MADV_DONTNEED frees private anonymous pages immediately (MADV_FREE, which
// virtual.decommit uses, only under memory pressure; measured in KV-T-0019).
os_pool_release :: proc(addr: rawptr, size: int) -> Error {
	if madvise(addr, c.size_t(size), MADV_DONTNEED) != 0 {
		return .Io
	}
	if posix.mprotect(addr, c.size_t(size), {}) != .OK {
		return .Io
	}
	return .None
}
