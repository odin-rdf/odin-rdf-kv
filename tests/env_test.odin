package kv_tests

import "core:testing"

import kv "../kv"

DB :: "test.db"

make_meta :: proc(txn_id: u64, entries: u64 = 0, page_size := kv.DEFAULT_PAGE_SIZE, last_pgno: u64 = 1) -> kv.Meta {
	return kv.Meta {
		magic     = kv.MAGIC,
		version   = kv.VERSION,
		page_size = u32le(page_size),
		txn_id    = u64le(txn_id),
		entries   = u64le(entries),
		last_pgno = u64le(last_pgno),
	}
}

// Opens the database, writes the given meta pages, and closes it again.
write_metas :: proc(t: ^testing.T, path: string, meta0, meta1: kv.Meta, options := kv.Options{}) {
	env, err := kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, kv.meta_write(env, 0, meta0), kv.Error.None)
	testing.expect_value(t, kv.meta_write(env, 1, meta1), kv.Error.None)
	kv.env_close(env)
}

// Flips one byte of the `entries` field of a meta page, which invalidates its
// checksum. The database must be closed.
corrupt_meta :: proc(t: ^testing.T, path: string, slot: int, page_size := kv.DEFAULT_PAGE_SIZE) {
	offset := i64(slot * page_size + kv.META_OFFSET + int(offset_of(kv.Meta, entries)))
	fd, err := kv.os_open(path, create = false)
	testing.expect_value(t, err, kv.Error.None)
	defer kv.os_close(fd)

	b: [1]byte
	testing.expect_value(t, kv.os_pread(fd, b[:], offset), kv.Error.None)
	b[0] ~= 0xFF
	testing.expect_value(t, kv.os_pwrite(fd, b[:], offset), kv.Error.None)
}

// Opens the database and returns its snapshot, or fails the test.
reopen_snapshot :: proc(t: ^testing.T, path: string) -> (snap: kv.Snapshot, page_size: int) {
	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	return kv.env_snapshot(env), env.page_size
}

@(test)
test_env_create_and_reopen :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, env.page_size, kv.DEFAULT_PAGE_SIZE)
	testing.expect(t, env.map_size >= kv.DEFAULT_MAP_SIZE, "map smaller than the default")
	testing.expect_value(t, kv.env_snapshot(env), kv.Snapshot{txn_id = 0, root = 0, depth = 0, last_pgno = 1, entries = 0})

	size, size_err := kv.os_file_size(env.fd)
	testing.expect_value(t, size_err, kv.Error.None)
	testing.expect_value(t, size, 2 * kv.DEFAULT_PAGE_SIZE)

	// Both meta pages were written: each one on its own is enough to open.
	testing.expect_value(t, kv.meta_write(env, 1, make_meta(txn_id = 1, entries = 5)), kv.Error.None)
	kv.env_close(env)

	snap, _ := reopen_snapshot(t, path)
	testing.expect_value(t, snap, kv.Snapshot{txn_id = 1, last_pgno = 1, entries = 5})

	corrupt_meta(t, path, 1)
	snap, _ = reopen_snapshot(t, path)
	testing.expect_value(t, snap, kv.Snapshot{txn_id = 0, last_pgno = 1})
}

@(test)
test_env_highest_txn_wins :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	write_metas(t, path, make_meta(3, entries = 30), make_meta(2, entries = 20))
	snap, _ := reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 3)
	testing.expect_value(t, snap.entries, 30)

	write_metas(t, path, make_meta(4, entries = 40), make_meta(5, entries = 50))
	snap, _ = reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 5)
	testing.expect_value(t, snap.entries, 50)

	// On a tie, page 0 wins.
	write_metas(t, path, make_meta(7, entries = 70), make_meta(7, entries = 71))
	snap, _ = reopen_snapshot(t, path)
	testing.expect_value(t, snap.entries, 70)
}

@(test)
test_env_falls_back_to_other_meta :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	// The newer meta is page 0; damage it.
	write_metas(t, path, make_meta(2, entries = 2), make_meta(1, entries = 1))
	corrupt_meta(t, path, 0)
	snap, _ := reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 1)
	testing.expect_value(t, snap.entries, 1)

	// The newer meta is page 1; damage it.
	write_metas(t, path, make_meta(3, entries = 3), make_meta(4, entries = 4))
	corrupt_meta(t, path, 1)
	snap, _ = reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 3)
	testing.expect_value(t, snap.entries, 3)
}

// With page 0 damaged, the page size needed to find page 1 is unknown and
// has to be probed.
@(test)
test_env_fallback_probes_page_size :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	page_size := 16384
	options := kv.Options{page_size = page_size}
	write_metas(t, path, make_meta(2, page_size = page_size), make_meta(1, entries = 11, page_size = page_size), options)
	corrupt_meta(t, path, 0, page_size)

	snap, opened_page_size := reopen_snapshot(t, path)
	testing.expect_value(t, opened_page_size, page_size)
	testing.expect_value(t, snap.txn_id, 1)
	testing.expect_value(t, snap.entries, 11)
}

@(test)
test_env_both_metas_corrupt :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err == .None {
		kv.env_close(env)
	}
	corrupt_meta(t, path, 0)
	corrupt_meta(t, path, 1)

	_, err = kv.env_open(path)
	testing.expect_value(t, err, kv.Error.Corrupted)
}

@(test)
test_env_bad_magic :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	// Correct checksums, wrong magic.
	bad := make_meta(1)
	bad.magic = 0x1234_5678
	write_metas(t, path, bad, bad)

	_, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.Corrupted)
}

@(test)
test_env_not_a_database :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	fd, err := kv.os_open(path, create = true)
	testing.expect_value(t, err, kv.Error.None)
	garbage: [3 * kv.DEFAULT_PAGE_SIZE]byte
	for &b, i in garbage {
		b = byte(i * 31 + 7)
	}
	testing.expect_value(t, kv.os_pwrite(fd, garbage[:], 0), kv.Error.None)
	kv.os_close(fd)

	_, err = kv.env_open(path)
	testing.expect_value(t, err, kv.Error.Corrupted)
}

@(test)
test_env_truncated_file :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err == .None {
		kv.env_close(env)
	}

	// Cut the file inside page 0's meta: nothing valid is left to read.
	fd, open_err := kv.os_open(path, create = false)
	testing.expect_value(t, open_err, kv.Error.None)
	testing.expect_value(t, kv.os_truncate(fd, kv.META_OFFSET + 8), kv.Error.None)
	kv.os_close(fd)

	_, err = kv.env_open(path)
	testing.expect_value(t, err, kv.Error.Corrupted)
}

@(test)
test_env_meta_beyond_end_of_file :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	// A newer meta that refers to pages the file doesn't have is ignored.
	write_metas(t, path, make_meta(1, entries = 1), make_meta(2, last_pgno = 100))
	snap, _ := reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 1)

	// Including a last_pgno so large that computing its byte offset overflows.
	write_metas(t, path, make_meta(1, entries = 1), make_meta(2, last_pgno = max(u64)))
	snap, _ = reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 1)
}

@(test)
test_env_locked :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}

	_, err2 := kv.env_open(path)
	testing.expect_value(t, err2, kv.Error.Locked)

	// The first handle is unaffected, and the lock is released on close.
	testing.expect_value(t, kv.env_snapshot(env).last_pgno, 1)
	kv.env_close(env)

	env3, err3 := kv.env_open(path)
	testing.expect_value(t, err3, kv.Error.None)
	if err3 == .None {
		kv.env_close(env3)
	}
}

@(test)
test_env_invalid_page_size :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir)

	for size in ([]int{1000, 2048, 6000, 65536}) {
		_, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{page_size = size})
		testing.expectf(t, err == .Invalid_Argument, "page size %d: got %v", size, err)
	}
}

@(test)
test_env_map_covers_file :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err == .None {
		kv.env_close(env)
	}

	fd, open_err := kv.os_open(path, create = false)
	testing.expect_value(t, open_err, kv.Error.None)
	testing.expect_value(t, kv.os_truncate(fd, 1 << 20), kv.Error.None)
	kv.os_close(fd)

	// A map smaller than the file is enlarged to cover it.
	env, err = kv.env_open(path, kv.Options{map_size = 64 * 1024})
	testing.expect_value(t, err, kv.Error.None)
	if err == .None {
		testing.expect(t, env.map_size >= 1 << 20, "map does not cover the file")
		testing.expect_value(t, env.map_size % kv.DEFAULT_CHUNK_SIZE, 0)
		kv.env_close(env)
	}
}

@(test)
test_env_open_directory_fails :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir)

	_, err := kv.env_open(dir.path)
	testing.expect_value(t, err, kv.Error.Io)
}
