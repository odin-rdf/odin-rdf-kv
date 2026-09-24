package kv_tests

import "core:testing"

import kv "../kv"

PAGE :: kv.DEFAULT_PAGE_SIZE
MAP_SIZE :: 1 << 20

fill_page :: proc(buf: []byte, seed: byte) {
	for &b, i in buf {
		b = seed + byte(i)
	}
}

// The design relies on writes made with pwrite being visible through the
// read-only shared mapping, including pages already faulted in and pages
// beyond the end of the file at the time it was mapped.
@(test)
test_pwrite_visible_through_map :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "coherence.db")
	path := temp_dir_file(dir, "coherence.db")

	fd, err := kv.os_open(path, create = true)
	testing.expect_value(t, err, kv.Error.None)
	defer kv.os_close(fd)

	testing.expect_value(t, kv.os_truncate(fd, 2 * PAGE), kv.Error.None)
	base, map_err := kv.os_map_reserve(fd, MAP_SIZE, kv.MIN_CHUNK_SIZE)
	testing.expect_value(t, map_err, kv.Error.None)
	testing.expect_value(t, uintptr(base) % kv.MIN_CHUNK_SIZE, 0)
	defer kv.os_unmap(base, MAP_SIZE)
	testing.expect_value(t, kv.os_advise_random(base, MAP_SIZE), kv.Error.None)

	page: [PAGE]byte

	// A page inside the original file.
	fill_page(page[:], 1)
	testing.expect_value(t, kv.os_pwrite(fd, page[:], PAGE), kv.Error.None)
	testing.expect(t, string(base[PAGE:2 * PAGE]) == string(page[:]), "first write not visible through map")

	// Rewriting a page that has already been read through the map.
	fill_page(page[:], 7)
	testing.expect_value(t, kv.os_pwrite(fd, page[:], PAGE), kv.Error.None)
	testing.expect(t, string(base[PAGE:2 * PAGE]) == string(page[:]), "rewrite not visible through map")

	// Growing the file after mapping: the new page is visible at its offset.
	testing.expect_value(t, kv.os_truncate(fd, 3 * PAGE), kv.Error.None)
	fill_page(page[:], 42)
	testing.expect_value(t, kv.os_pwrite(fd, page[:], 2 * PAGE), kv.Error.None)
	testing.expect(t, string(base[2 * PAGE:3 * PAGE]) == string(page[:]), "write past original EOF not visible")

	testing.expect_value(t, kv.os_sync(fd), kv.Error.None)

	size, size_err := kv.os_file_size(fd)
	testing.expect_value(t, size_err, kv.Error.None)
	testing.expect_value(t, size, 3 * PAGE)

	readback: [PAGE]byte
	testing.expect_value(t, kv.os_pread(fd, readback[:], 2 * PAGE), kv.Error.None)
	testing.expect(t, readback == page, "pread returned different bytes")

	// Reading past the end of the file is an error, not a short read.
	testing.expect_value(t, kv.os_pread(fd, readback[:], 3 * PAGE), kv.Error.Io)
}

@(test)
test_open_takes_exclusive_lock :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "lock.db")
	path := temp_dir_file(dir, "lock.db")

	fd, err := kv.os_open(path, create = true)
	testing.expect_value(t, err, kv.Error.None)

	// A second handle in the same process is refused while the first is open.
	_, err2 := kv.os_open(path, create = false)
	testing.expect_value(t, err2, kv.Error.Locked)

	kv.os_close(fd)

	fd3, err3 := kv.os_open(path, create = false)
	testing.expect_value(t, err3, kv.Error.None)
	kv.os_close(fd3)
}

@(test)
test_open_missing_file_without_create :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir)

	_, err := kv.os_open(temp_dir_file(dir, "missing.db"), create = false)
	testing.expect_value(t, err, kv.Error.Io)
}
