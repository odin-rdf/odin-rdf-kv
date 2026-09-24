package kv_tests

import "core:bytes"
import "core:math/rand"
import "core:slice"
import "core:testing"

import kv "../kv"

// A value of `n` bytes whose content depends on `seed`, so a wrong or
// truncated value is detected.
patterned :: proc(n: int, seed: u32) -> []byte {
	v := make([]byte, n, context.temp_allocator)
	for &b, i in v {
		b = byte(u32(i) * 2654435761 + seed)
	}
	return v
}

// Whether `key` is stored with its value in an overflow run.
is_overflow :: proc(txn: ^kv.Txn, key: []byte) -> bool {
	path: kv.Path
	exact, err := kv.tree_search(txn, key, &path)
	if err != .None || !exact {
		return false
	}
	e := kv.path_leaf(&path)
	_, _, bigdata := kv.leaf_value(kv.page_ptr(txn, e.pgno), e.idx)
	return bigdata
}

@(test)
test_overflow_threshold_boundary :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	// With a 1-byte key, the largest inline value makes the node exactly
	// overflow_threshold bytes.
	at := kv.overflow_threshold(env.page_size) - kv.leaf_node_size(1, 0, false)
	Case :: struct {
		key:      string,
		size:     int,
		overflow: bool,
	}
	cases := []Case{{"a", at - 1, false}, {"b", at, false}, {"c", at + 1, true}, {"d", 3 * at, true}}
	for c in cases {
		value := patterned(c.size, u32(c.size))
		testing.expect_value(t, kv.put(&txn, transmute([]byte)c.key, value), kv.Error.None)
		testing.expectf(t, is_overflow(&txn, transmute([]byte)c.key) == c.overflow, "%s (%d bytes): overflow should be %v", c.key, c.size, c.overflow)
		got, err := kv.get(&txn, transmute([]byte)c.key)
		testing.expect_value(t, err, kv.Error.None)
		testing.expect(t, bytes.equal(got, value), "wrong value")
	}
	testing.expect_value(t, txn.snapshot.entries, u64(len(cases)))
	expect_tree_ok(t, &txn)
}

@(test)
test_overflow_run_sizes :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	ps := env.page_size

	// A value filling n pages exactly (after the header) needs n pages;
	// one more byte needs n + 1.
	kv.put(&txn, transmute([]byte)string("root"), nil)
	for n in 1 ..= 4 {
		for extra in 0 ..= 1 {
			size := n * ps - kv.PAGE_HEADER_SIZE + extra
			if !kv.leaf_needs_overflow(ps, 2, size) {
				continue
			}
			key := []byte{byte(n), byte(extra)}
			before := txn.snapshot.last_pgno
			testing.expect_value(t, kv.put(&txn, key, patterned(size, u32(n))), kv.Error.None)

			path: kv.Path
			kv.tree_search(&txn, key, &path)
			e := kv.path_leaf(&path)
			_, first, _ := kv.leaf_value(kv.page_ptr(&txn, e.pgno), e.idx)
			testing.expect_value(t, kv.page_header(kv.page_ptr(&txn, first)).overflow_count, u32le(n + extra))
			testing.expect_value(t, kv.overflow_pages(ps, size), n + extra)
			testing.expect(t, txn.snapshot.last_pgno - before >= kv.Pgno(n + extra), "run not allocated")

			got, err := kv.get(&txn, key)
			testing.expect_value(t, err, kv.Error.None)
			testing.expect(t, bytes.equal(got, patterned(size, u32(n))), "wrong value")
		}
	}
	expect_tree_ok(t, &txn)
}

@(test)
test_overflow_10mb_value :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	size := 10 << 20
	value := patterned(size, 7)
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), value), kv.Error.None)
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("small"), transmute([]byte)string("x")), kv.Error.None)

	got, err := kv.get(&txn, transmute([]byte)string("big"))
	testing.expect_value(t, err, kv.Error.None)
	testing.expect_value(t, len(got), size)
	testing.expect(t, bytes.equal(got, value), "10 MB value differs")
	// Overflow values are 16-byte aligned.
	testing.expect_value(t, uintptr(raw_data(got)) % 16, 0)
	testing.expect_value(t, int(txn.snapshot.last_pgno) >= kv.overflow_pages(env.page_size, size), true)
	expect_tree_ok(t, &txn)
}

@(test)
test_overflow_overwrite :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	ps := env.page_size
	key := transmute([]byte)string("key")

	run_of :: proc(txn: ^kv.Txn, key: []byte) -> kv.Pgno {
		path: kv.Path
		kv.tree_search(txn, key, &path)
		e := kv.path_leaf(&path)
		_, first, _ := kv.leaf_value(kv.page_ptr(txn, e.pgno), e.idx)
		return first
	}

	sizes := []int{3 * ps, 10, 2 * ps, 5 * ps, 5 * ps, 0}
	prev_run := kv.Pgno(0)
	prev_size := 0
	for size, i in sizes {
		value := patterned(size, u32(i))
		testing.expect_value(t, kv.put(&txn, key, value), kv.Error.None)
		got, err := kv.get(&txn, key)
		testing.expect(t, err == .None && bytes.equal(got, value), "wrong value after overwrite")
		testing.expect_value(t, txn.snapshot.entries, 1)

		// A replaced run written by this transaction is dropped: out of the
		// dirty map, its pages on the loose list.
		if prev_run != 0 {
			testing.expect(t, prev_run not_in txn.write.dirty, "replaced run still dirty")
			for p in 0 ..< kv.overflow_pages(ps, prev_size) {
				testing.expect(t, slice.contains(txn.write.loose[:], prev_run + kv.Pgno(p)), "replaced run page not loose")
			}
		}
		prev_run, prev_size = 0, 0
		if kv.leaf_needs_overflow(ps, len(key), size) {
			prev_run, prev_size = run_of(&txn, key), size
		}
		expect_tree_ok(t, &txn)
	}
	// Nothing committed was replaced.
	testing.expect_value(t, len(txn.write.freed), 0)
}

@(test)
test_overflow_mixed_vs_oracle :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	oracle := make(map[u64][]byte, context.temp_allocator)
	for i in 0 ..< 3_000 {
		id := rand.uint64() % 500
		size: int
		switch rand.int_max(4) {
		case 0:
			size = rand.int_max(5 * env.page_size)
		case 1:
			size = kv.overflow_threshold(env.page_size) - 20 + rand.int_max(40)
		case:
			size = rand.int_max(50)
		}
		key: [8]byte
		value := patterned(size, u32(i))
		if err := kv.put(&txn, u64_key(&key, id), value); err != .None {
			testing.expectf(t, false, "put failed: %v", err)
			return
		}
		oracle[id] = value
	}

	testing.expect_value(t, txn.snapshot.entries, u64(len(oracle)))
	expect_tree_ok(t, &txn)
	for id, value in oracle {
		key: [8]byte
		got, err := kv.get(&txn, u64_key(&key, id))
		if err != .None || !bytes.equal(got, value) {
			testing.expectf(t, false, "key %d: %v", id, err)
			return
		}
	}
}

@(test)
test_overflow_map_full :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB), kv.Options{map_size = 64 * 1024})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("a"), transmute([]byte)string("small")), kv.Error.None)
	before := txn.snapshot
	// Larger than the whole map.
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("b"), patterned(100 * 1024, 1)), kv.Error.Map_Full)
	testing.expect_value(t, txn.snapshot, before)
	testing.expect_value(t, txn.err, kv.Error.None)
	// A value that does fit still works.
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("b"), patterned(20 * 1024, 1)), kv.Error.None)
	expect_tree_ok(t, &txn)
}

@(test)
test_overflow_corruption_detected :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	key := transmute([]byte)string("key")
	kv.put(&txn, key, patterned(3 * env.page_size, 1))
	path: kv.Path
	kv.tree_search(&txn, key, &path)
	e := kv.path_leaf(&path)
	_, first, _ := kv.leaf_value(kv.page_ptr(&txn, e.pgno), e.idx)
	// The run was written straight to the file (KV-I-0004 D5), and is read
	// through the read-only map: damage it in the file.
	testing.expect(t, first in txn.write.spilled, "the run is not in the file")
	buf: Page_Buf
	page := read_page(t, env, first, &buf)
	h := kv.page_header(page)

	h.overflow_count += 1
	write_page(t, env, first, page)
	_, err := kv.get(&txn, key)
	testing.expect_value(t, err, kv.Error.Corrupted)
	h.overflow_count -= 1

	h.flags = kv.PAGE_LEAF
	write_page(t, env, first, page)
	_, err = kv.get(&txn, key)
	testing.expect_value(t, err, kv.Error.Corrupted)
	h.flags = kv.PAGE_OVERFLOW
	write_page(t, env, first, page)

	_, err = kv.get(&txn, key)
	testing.expect_value(t, err, kv.Error.None)
}
