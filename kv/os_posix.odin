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
// of the file. The mapping may extend past the end of the file; only pages
// inside the file may be touched.
os_map_reserve :: proc(fd: posix.FD, map_size: int) -> (base: [^]byte, err: Error) {
	p := posix.mmap(nil, c.size_t(map_size), {.READ}, {.SHARED}, fd, 0)
	if p == posix.MAP_FAILED {
		return nil, .Io
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
