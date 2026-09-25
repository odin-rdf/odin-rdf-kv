package kv

import "core:c"
import "core:sys/posix"

// Not exposed by core:sys/posix. See fcntl(2) on macOS.
@(private = "file")
F_FULLFSYNC :: 51

// Flushes the file's data to stable storage. On macOS a plain fsync only
// reaches the drive's cache; F_FULLFSYNC asks the drive to flush it too.
// Under NO_SYNC (test-only) it returns once io_hook has seen it, without the
// system call.
os_sync :: proc(fd: posix.FD) -> Error {
	when IO_HOOK {
		if io_hook != nil {
			io_hook({kind = .Sync, fd = fd}) or_return
		}
	}
	when NO_SYNC {
		return .None
	}
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

// Evicts `size` bytes of the map at `addr`, which is at byte `offset` of the
// file: its pages leave the process, stay in the page cache, and are read
// back from there when next touched. The addresses stay valid throughout,
// including for other threads reading the range. Mapping the same file
// range over itself with MAP_FIXED is the only call that does this on
// macOS: MADV_DONTNEED is a hint there that drops nothing, and
// msync(MS_INVALIDATE) drops the page cache too (measured in KV-T-0019).
// The new mapping has default advice, so MADV_RANDOM is given again.
os_evict :: proc(fd: posix.FD, addr: [^]byte, offset, size: int) -> Error {
	p := posix.mmap(addr, c.size_t(size), {.READ}, {.SHARED, .FIXED}, fd, posix.off_t(offset))
	if p == posix.MAP_FAILED {
		return .Io
	}
	if posix.posix_madvise(addr, c.size_t(size), .RANDOM) != .NONE {
		return .Io
	}
	return .None
}

// Would return the bytes of the range present in this process's page
// tables, but macOS has no per-range source for that: mincore and
// mach_vm_region both report the file's pages in the page cache, whether
// the process maps them or not, and only the process-wide task_info
// resident_size follows the mapping (measured in KV-T-0019). So it returns
// Unsupported (KV-I-0004 D10).
os_resident :: proc(addr: [^]byte, size: int) -> (resident: int, err: Error) {
	return 0, .Unsupported
}
