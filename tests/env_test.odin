package kv_tests

import "core:fmt"
import "core:slice"
import "core:strings"
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

// Writes `img` as the file at `path`, failing the test if it can't.
@(private = "file")
env_file_write :: proc(t: ^testing.T, path: string, img: []byte) -> bool {
	return testing.expectf(t, image_write(path, img), "writing %s", path)
}

// Opens `path`, which must return Corrupted and leave the file as `img`.
@(private = "file")
expect_refused :: proc(t: ^testing.T, path: string, img: []byte, what: string, options := kv.Options{}) {
	env, err := kv.env_open(path, options)
	if err == .None {
		kv.env_close(env)
	}
	testing.expectf(t, err == .Corrupted, "%s: env_open returned %v, want Corrupted", what, err)
	b, ok := baseline_take(path, context.temp_allocator)
	testing.expectf(t, ok && slice.equal(b.bytes, img), "%s: the refused file was changed", what)
}

// KV-I-0005 D6: a file of exactly two zero pages, at the page size this
// open would use, is a creation that crashed before either meta page
// reached it, and opens as a new database.
@(test)
test_env_new_file_all_zero :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := strings.clone(temp_dir_file(dir, DB), context.temp_allocator)

	for ps in ([]int{kv.DEFAULT_PAGE_SIZE, 16384}) {
		options := kv.Options{page_size = ps}
		if !env_file_write(t, path, make([]byte, 2 * ps, context.temp_allocator)) {
			return
		}
		env, err := kv.env_open(path, options)
		if !testing.expectf(t, err == .None, "page size %d: env_open: %v", ps, err) {
			continue
		}
		testing.expect_value(t, env.page_size, ps)
		testing.expect_value(t, kv.env_snapshot(env), kv.Snapshot{txn_id = 0, last_pgno = 1})

		txn, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("key"), transmute([]byte)string("value")), kv.Error.None)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		kv.env_close(env)

		env, err = kv.env_open(path, options)
		if !testing.expectf(t, err == .None, "page size %d: reopen: %v", ps, err) {
			continue
		}
		snap := kv.env_snapshot(env)
		testing.expect_value(t, snap.txn_id, 1)
		testing.expect_value(t, snap.entries, 1)
		reader, _ := kv.txn_begin(env)
		value, get_err := kv.get(&reader, transmute([]byte)string("key"))
		testing.expect_value(t, get_err, kv.Error.None)
		testing.expect_value(t, string(value), "value")
		kv.txn_abort(&reader)
		kv.env_close(env)
	}
}

// The D6 rule is narrow: anything without a valid meta page that isn't
// exactly two zero pages at this open's page size stays Corrupted, and is
// left as it was.
@(test)
test_env_new_file_rule_is_narrow :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := strings.clone(temp_dir_file(dir, DB), context.temp_allocator)
	ps := kv.DEFAULT_PAGE_SIZE

	// One nonzero byte, past the meta pages' prefixes and inside one.
	for offset in ([]int{2 * ps - 1, ps - 1, kv.META_OFFSET, ps + kv.META_OFFSET + 3}) {
		img := make([]byte, 2 * ps, context.temp_allocator)
		img[offset] = 1
		if env_file_write(t, path, img) {
			expect_refused(t, path, img, fmt.tprintf("two pages, byte %d nonzero", offset))
		}
	}

	// Three zero pages, one zero page, and a zero file of two pages at
	// another page size than this open's (both ways).
	cases := []struct {
		size:      int,
		page_size: int,
	}{{3 * ps, 0}, {ps, 0}, {2 * 8192, 0}, {2 * ps, 8192}}
	for c in cases {
		img := make([]byte, c.size, context.temp_allocator)
		if env_file_write(t, path, img) {
			expect_refused(t, path, img, fmt.tprintf("%d zero bytes opened at page size %d", c.size, c.page_size), {page_size = c.page_size})
		}
	}

	// What a power loss during creation can leave with a meta write torn
	// (KV-T-0029): slot 0 holding a prefix of its meta page, slot 1 zero.
	// No valid meta page, not all zero: refused, like any other damage.
	// Whether it should open is the owner's open question (KV-T-0038).
	fresh := strings.clone(temp_dir_file(dir, "fresh"), context.temp_allocator)
	defer file_remove(fresh)
	env, err := kv.env_open(fresh)
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	kv.env_close(env)
	b, ok := baseline_take(fresh, context.temp_allocator)
	if !testing.expect(t, ok && len(b.bytes) == 2 * ps, "reading a new database") {
		return
	}
	img := make([]byte, 2 * ps, context.temp_allocator)
	copy(img[:40], b.bytes[:40])
	if env_file_write(t, path, img) {
		expect_refused(t, path, img, "slot 0 torn to 40 bytes, slot 1 zero")
	}
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
