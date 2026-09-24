#+build darwin, linux
package kv

// Platform layer shared by macOS and Linux. The rest of the package goes
// through these procedures instead of calling core:sys/posix directly.

import "core:c"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

// flock(2) is not part of POSIX, so core:sys/posix doesn't bind it. Unlike
// fcntl record locks, flock locks belong to the open file description, so a
// second open of the same file in the same process conflicts as well.
@(private = "file")
foreign libc {
	flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

// Same values on Darwin and Linux.
@(private = "file") LOCK_EX :: 2
@(private = "file") LOCK_NB :: 4

// Opens the database file for reading and writing, creating it if `create`
// is set, and takes an exclusive lock on it. Returns `.Locked` if another
// handle already holds the lock.
os_open :: proc(path: string, create: bool) -> (fd: posix.FD, err: Error) {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	flags := posix.O_Flags{.RDWR, .CLOEXEC}
	if create {
		flags += {.CREAT}
	}
	fd = posix.open(cpath, flags, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd == -1 {
		return -1, .Io
	}

	if flock(c.int(fd), LOCK_EX | LOCK_NB) != 0 {
		errno := posix.errno()
		posix.close(fd)
		return -1, .Locked if errno == .EWOULDBLOCK else .Io
	}
	return fd, .None
}

// Closes the file, which also releases the lock.
os_close :: proc(fd: posix.FD) {
	posix.close(fd)
}

os_file_size :: proc(fd: posix.FD) -> (size: i64, err: Error) {
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return 0, .Io
	}
	return i64(st.st_size), .None
}

os_truncate :: proc(fd: posix.FD, size: i64) -> Error {
	for {
		if posix.ftruncate(fd, posix.off_t(size)) == .OK {
			return .None
		}
		if posix.errno() != .EINTR {
			return .Io
		}
	}
}

// Reads exactly `len(buf)` bytes at `offset`. Reading past the end of the
// file is an error.
os_pread :: proc(fd: posix.FD, buf: []byte, offset: i64) -> Error {
	buf, offset := buf, offset
	for len(buf) > 0 {
		n := posix.pread(fd, raw_data(buf), c.size_t(len(buf)), posix.off_t(offset))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return .Io
		}
		if n == 0 {
			return .Io
		}
		buf = buf[n:]
		offset += i64(n)
	}
	return .None
}

// Writes all of `buf` at `offset`.
os_pwrite :: proc(fd: posix.FD, buf: []byte, offset: i64) -> Error {
	buf, offset := buf, offset
	for len(buf) > 0 {
		n := posix.pwrite(fd, raw_data(buf), c.size_t(len(buf)), posix.off_t(offset))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return .Io
		}
		buf = buf[n:]
		offset += i64(n)
	}
	return .None
}

// Reserves `map_size` bytes of address space as a read-only shared mapping
// of the file, at an address aligned to `align` (a power of two, a multiple
// of the OS page size). The mapping may extend past the end of the file;
// only pages inside the file may be touched. The alignment keeps each chunk
// of the map (KV-I-0004 D7) aligned in the address space, which Linux's
// fault-around window (64 KiB, aligned by address; KV-T-0019) needs to
// stay inside one chunk: mmap alone only aligns to the OS page.
os_map_reserve :: proc(fd: posix.FD, map_size, align: int) -> (base: [^]byte, err: Error) {
	// Reserve enough to find an aligned start, map the file over it there,
	// and give back the slack on either side.
	span := map_size + align
	r := posix.mmap(nil, c.size_t(span), {}, {.PRIVATE, .ANONYMOUS}, -1, 0)
	if r == posix.MAP_FAILED {
		return nil, .Io
	}
	lo := uintptr(r)
	start := (lo + uintptr(align) - 1) &~ uintptr(align - 1)
	p := posix.mmap(rawptr(start), c.size_t(map_size), {.READ}, {.SHARED, .FIXED}, fd, 0)
	if p == posix.MAP_FAILED {
		posix.munmap(r, c.size_t(span))
		return nil, .Io
	}
	if start > lo {
		posix.munmap(r, c.size_t(start - lo))
	}
	if tail := lo + uintptr(span) - (start + uintptr(map_size)); tail > 0 {
		posix.munmap(rawptr(start + uintptr(map_size)), c.size_t(tail))
	}
	return ([^]byte)(p), .None
}

os_unmap :: proc(base: [^]byte, map_size: int) {
	posix.munmap(base, c.size_t(map_size))
}

// Disables kernel readahead on the mapping, so that residency tracks the
// pages actually touched.
os_advise_random :: proc(base: [^]byte, map_size: int) -> Error {
	if posix.posix_madvise(base, c.size_t(map_size), .RANDOM) != .NONE {
		return .Io
	}
	return .None
}

// The OS's page size, the unit memory is protected and released in. 16 KiB
// on Apple Silicon, whatever the database's page size.
os_page_size :: proc() -> int {
	return int(posix.sysconf(._PAGESIZE))
}

// Reserves `size` bytes of private anonymous address space for the
// dirty-page pool: inaccessible, and backed by no memory until committed.
os_pool_reserve :: proc(size: int) -> (base: [^]byte, err: Error) {
	p := posix.mmap(nil, c.size_t(size), {}, {.PRIVATE, .ANONYMOUS}, -1, 0)
	if p == posix.MAP_FAILED {
		return nil, .Out_Of_Memory
	}
	return ([^]byte)(p), .None
}

// Makes a reserved range of the pool readable and writable. Its pages are
// zero, and take memory as they are first written. `addr` and `size` are
// multiples of the OS page size.
os_pool_commit :: proc(addr: rawptr, size: int) -> Error {
	if posix.mprotect(addr, c.size_t(size), {.READ, .WRITE}) != .OK {
		return .Out_Of_Memory
	}
	return .None
}
