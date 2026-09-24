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

// Evicts `size` bytes of the map at `addr`: its pages leave the process,
// stay in the page cache, and are read back from there when next touched.
// The addresses stay valid throughout, including for other threads reading
// the range. MADV_DONTNEED drops a shared file mapping's page table entries
// and keeps its advice; madvise is called directly, since glibc's
// posix_madvise ignores it (measured in KV-T-0019). `fd` and `offset` are
// for macOS's method.
os_evict :: proc(fd: posix.FD, addr: [^]byte, offset, size: int) -> Error {
	if madvise(addr, c.size_t(size), MADV_DONTNEED) != 0 {
		return .Io
	}
	return .None
}

/*
Returns the bytes of the `size` bytes at `addr` (both multiples of the OS
page size) that are present in this process's page tables: the pages whose
/proc/self/pagemap entry has the present bit (bit 63), which unprivileged
processes can read. Only the process's own mappings count, not the page
cache: mincore reports the page cache, so it can't be used (measured in
KV-T-0019). Reads the entries in batches into a buffer on the stack, 8
bytes per page, so it allocates nothing. Returns Io if pagemap can't be
read.
*/
os_resident :: proc(addr: [^]byte, size: int) -> (resident: int, err: Error) {
	fd := posix.open("/proc/self/pagemap", {.CLOEXEC})
	if fd == -1 {
		return 0, .Io
	}
	defer posix.close(fd)
	ps := os_page_size()
	entries: [1024]u64
	first, pages := int(uintptr(addr)) / ps, size / ps
	for done := 0; done < pages; {
		n := min(pages - done, len(entries))
		os_pread(fd, ([^]byte)(&entries[0])[:n * size_of(u64)], i64(first + done) * size_of(u64)) or_return
		for e in entries[:n] {
			if e >> 63 != 0 {
				resident += ps
			}
		}
		done += n
	}
	return resident, .None
}
