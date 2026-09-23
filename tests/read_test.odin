package kv_tests

import "core:fmt"
import "core:mem"
import "core:sync"
import "core:testing"

import kv "../kv"

// Opens `path` and begins a read transaction, failing the test on error.
open_read :: proc(t: ^testing.T, path: string) -> (env: ^kv.Env, txn: kv.Txn, ok: bool) {
	err: kv.Error
	env, err = kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return nil, {}, false
	}
	txn, err = kv.txn_begin(env)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		kv.env_close(env)
		return nil, {}, false
	}
	return env, txn, true
}

// Expects every entry to be found with its value, and the odd keys between
// them (and around them) to be absent.
expect_even_entries :: proc(t: ^testing.T, txn: ^kv.Txn, n: int, loc := #caller_location) {
	for i in 0 ..< n {
		key: [8]byte
		value, err := kv.get(txn, u64_key(&key, u64(2 * i)))
		if err != .None || string(value) != fmt.tprintf("v%d", i) {
			testing.expectf(t, false, "key %d: got %q, %v", 2 * i, string(value), err, loc = loc)
			return
		}
		_, miss := kv.get(txn, u64_key(&key, u64(2 * i + 1)))
		if miss != .Not_Found {
			testing.expectf(t, false, "absent key %d: got %v", 2 * i + 1, miss, loc = loc)
			return
		}
	}
}

@(test)
test_get_empty_database :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_read(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	_, err := kv.get(&txn, transmute([]byte)string("anything"))
	testing.expect_value(t, err, kv.Error.Not_Found)
	_, err = kv.get(&txn, nil)
	testing.expect_value(t, err, kv.Error.Not_Found)
}

@(test)
test_get_single_leaf :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	tree := build_tree_file(t, path, even_entries(10))
	testing.expect_value(t, tree.depth, 1)

	env, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, txn.snapshot.entries, 10)
	testing.expect_value(t, txn.snapshot.root, tree.root)
	expect_even_entries(t, &txn, 10)

	// Before the first key and after the last.
	key: [8]byte
	_, err := kv.get(&txn, nil)
	testing.expect_value(t, err, kv.Error.Not_Found)
	_, err = kv.get(&txn, u64_key(&key, max(u64)))
	testing.expect_value(t, err, kv.Error.Not_Found)
	// A prefix of an existing key.
	_, err = kv.get(&txn, u64_key(&key, 4)[:7])
	testing.expect_value(t, err, kv.Error.Not_Found)
}

@(test)
test_get_multi_level :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	n := 50_000
	tree := build_tree_file(t, path, even_entries(n))
	testing.expectf(t, tree.depth >= 3, "expected at least 3 levels, got %d", tree.depth)

	env, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	expect_even_entries(t, &txn, n)
	key: [8]byte
	_, err := kv.get(&txn, u64_key(&key, max(u64)))
	testing.expect_value(t, err, kv.Error.Not_Found)
}

// Maximum-size keys give the minimum fan-out of 4, so the tree is deep.
@(test)
test_get_max_size_keys :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	max_key := kv.max_key_size(kv.DEFAULT_PAGE_SIZE)
	value_len := kv.overflow_threshold(kv.DEFAULT_PAGE_SIZE) - kv.leaf_node_size(max_key, 0, false)
	n := 300
	entries := make([]Entry, n, context.temp_allocator)
	for &e, i in entries {
		key := make([]byte, max_key, context.temp_allocator)
		for &b in key {
			b = 'k'
		}
		// Distinguish keys at the very end, after a long shared prefix.
		u64_key((^[8]byte)(&key[max_key - 8]), u64(i))
		value := make([]byte, value_len, context.temp_allocator)
		value[0] = byte(i)
		e = {key, value}
	}
	tree := build_tree_file(t, path, entries)
	testing.expectf(t, tree.depth >= 4, "expected a deep tree, got depth %d", tree.depth)

	env, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	for e, i in entries {
		value, err := kv.get(&txn, e.key)
		testing.expect_value(t, err, kv.Error.None)
		testing.expect(t, len(value) == value_len && value[0] == byte(i), "wrong value")
	}
}

@(test)
test_get_zero_copy_no_alloc :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	n := 5_000
	build_tree_file(t, path, even_entries(n))

	env, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	map_start := uintptr(env.map_base)
	map_end := map_start + uintptr(env.map_size)
	outside := 0
	found := 0
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&track)
		for i in 0 ..< 2 * n {
			key: [8]byte
			value, err := kv.get(&txn, u64_key(&key, u64(i)))
			if err == .None {
				found += 1
				p := uintptr(raw_data(value))
				if p < map_start || p + uintptr(len(value)) > map_end {
					outside += 1
				}
			}
		}
	}
	testing.expect_value(t, found, n)
	testing.expect_value(t, outside, 0)
	testing.expect_value(t, track.total_allocation_count, 0)
}

@(test)
test_read_txn_lifecycle :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	a, err_a := kv.txn_begin(env)
	b, err_b := kv.txn_begin(env)
	testing.expect(t, err_a == .None && err_b == .None, "txn_begin failed")
	testing.expect_value(t, sync.atomic_load(&env.active_txns), 2)
	testing.expect(t, a.read_only && !a.done, "fresh transaction state")

	gen := a.gen
	kv.txn_abort(&a)
	kv.txn_abort(&a)
	testing.expect(t, a.done && a.gen == gen + 1, "abort must end the transaction once")
	testing.expect_value(t, sync.atomic_load(&env.active_txns), 1)

	kv.txn_abort(&b)
	testing.expect_value(t, sync.atomic_load(&env.active_txns), 0)

	// Aborting a zero-value transaction (e.g. after a failed begin) is safe.
	z: kv.Txn
	kv.txn_abort(&z)
}

@(test)
test_tree_corruption_detected :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	n := 2_000
	key: [8]byte

	// The meta claims one level more than the tree has.
	{
		tree := build_tree_file(t, path, even_entries(n))
		env, err := kv.env_open(path)
		testing.expect_value(t, err, kv.Error.None)
		meta := kv.Meta {
			magic = kv.MAGIC, version = kv.VERSION, page_size = u32le(env.page_size),
			txn_id = 2, root = u64le(tree.root), depth = u32le(tree.depth + 1),
			entries = u64le(n), last_pgno = u64le(tree.last_pgno),
		}
		testing.expect_value(t, kv.meta_write(env, 0, meta), kv.Error.None)
		kv.env_close(env)

		env2, txn, ok := open_read(t, path)
		if ok {
			_, err = kv.get(&txn, u64_key(&key, 0))
			testing.expect_value(t, err, kv.Error.Corrupted)
			kv.txn_abort(&txn)
			kv.env_close(env2)
		}
	}

	// A branch points far past the end of the database (but inside the map).
	// Following it would touch unbacked memory and crash with SIGBUS.
	{
		tree := build_tree_file(t, path, even_entries(n), txn_id = 3)
		env, txn, ok := open_read(t, path)
		if ok {
			buf: Page_Buf
			root := read_page(t, env, tree.root, &buf)
			kv.branch_set_child(root, 1, tree.last_pgno + 1000)
			write_page(t, env, tree.root, root)

			// Keys under slot 0 are still reachable, keys under slot 1 aren't.
			_, err := kv.get(&txn, u64_key(&key, 0))
			testing.expect_value(t, err, kv.Error.None)
			first_key_1 := kv.node_key(root, 1)
			_, err = kv.get(&txn, first_key_1)
			testing.expect_value(t, err, kv.Error.Corrupted)
			kv.txn_abort(&txn)
			kv.env_close(env)
		}
	}

	// A page records the wrong page number.
	{
		tree := build_tree_file(t, path, even_entries(n), txn_id = 5)
		env, txn, ok := open_read(t, path)
		if ok {
			buf: Page_Buf
			root := read_page(t, env, tree.root, &buf)
			kv.page_header(root).pgno += 1
			write_page(t, env, tree.root, root)

			_, err := kv.get(&txn, u64_key(&key, 0))
			testing.expect_value(t, err, kv.Error.Corrupted)
			kv.txn_abort(&txn)
			kv.env_close(env)
		}
	}
}
