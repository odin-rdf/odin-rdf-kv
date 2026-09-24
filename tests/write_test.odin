package kv_tests

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:sync"
import "core:testing"

import kv "../kv"

// Opens `path` and begins a write transaction, failing the test on error.
open_write :: proc(t: ^testing.T, path: string, options := kv.Options{}) -> (env: ^kv.Env, txn: kv.Txn, ok: bool) {
	err: kv.Error
	env, err = kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return nil, {}, false
	}
	txn, err = kv.txn_begin(env, read_only = false)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		kv.env_close(env)
		return nil, {}, false
	}
	return env, txn, true
}

expect_tree_ok :: proc(t: ^testing.T, txn: ^kv.Txn, loc := #caller_location) -> bool {
	ok, reason := kv.tree_check(txn)
	testing.expectf(t, ok, "tree_check failed: %s", reason, loc = loc)
	return ok
}

expect_space_ok :: proc(t: ^testing.T, txn: ^kv.Txn, loc := #caller_location) -> bool {
	ok, reason := kv.space_check(txn)
	testing.expectf(t, ok, "space_check failed: %s", reason, loc = loc)
	return ok
}

@(test)
test_put_first_key_creates_root_leaf :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("hello"), transmute([]byte)string("world")), kv.Error.None)
	testing.expect_value(t, txn.snapshot.depth, 1)
	testing.expect_value(t, txn.snapshot.entries, 1)
	testing.expect_value(t, txn.snapshot.root, 2)

	value, err := kv.get(&txn, transmute([]byte)string("hello"))
	testing.expect_value(t, err, kv.Error.None)
	testing.expect_value(t, string(value), "world")

	// The dirty page is page-aligned, as the design requires.
	testing.expect_value(t, uintptr(raw_data(kv.page_ptr(&txn, txn.snapshot.root))) % uintptr(env.page_size), 0)
	expect_tree_ok(t, &txn)
}

Insert_Order :: enum {
	Ascending,
	Descending,
	Random,
}

@(test)
test_put_many_in_every_order :: proc(t: ^testing.T) {
	n := 50_000
	for order in Insert_Order {
		dir := temp_dir_create(t)
		defer temp_dir_destroy(&dir, DB)

		env, txn, ok := open_write(t, temp_dir_file(dir, DB))
		if !ok {
			return
		}
		defer kv.env_close(env)
		defer kv.txn_abort(&txn)

		keys := make([]u64, n, context.temp_allocator)
		for &k, i in keys {
			k = u64(i)
		}
		switch order {
		case .Ascending:
		case .Descending:
			slice.reverse(keys)
		case .Random:
			rand.shuffle(keys)
		}

		for k, i in keys {
			key: [8]byte
			err := kv.put(&txn, u64_key(&key, k), transmute([]byte)fmt.tprintf("v%d", k))
			if err != .None {
				testing.expectf(t, false, "%v: put %d failed: %v", order, k, err)
				return
			}
			if (i + 1) % 5_000 == 0 && !expect_tree_ok(t, &txn) {
				return
			}
		}

		testing.expect_value(t, txn.snapshot.entries, u64(n))
		testing.expectf(t, txn.snapshot.depth >= 3, "%v: expected at least 3 levels, got %d", order, txn.snapshot.depth)
		for k in 0 ..< n {
			key: [8]byte
			value, err := kv.get(&txn, u64_key(&key, u64(k)))
			if err != .None || string(value) != fmt.tprintf("v%d", k) {
				testing.expectf(t, false, "%v: get %d: %q, %v", order, k, string(value), err)
				return
			}
		}
		key: [8]byte
		_, err := kv.get(&txn, u64_key(&key, u64(n)))
		testing.expect_value(t, err, kv.Error.Not_Found)
		free_all(context.temp_allocator)
	}
}

@(test)
test_put_overwrite :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	n := 2_000
	short: [10]byte
	for i in 0 ..< n {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(i)), short[:])
	}
	// Equal size (in place), larger, smaller, and empty values.
	big: [300]byte
	for &b in big {
		b = 0xBB
	}
	sizes := []int{10, 300, 3, 0}
	for i in 0 ..< n {
		key: [8]byte
		size := sizes[i % len(sizes)]
		testing.expect_value(t, kv.put(&txn, u64_key(&key, u64(i)), big[:size]), kv.Error.None)
	}
	testing.expect_value(t, txn.snapshot.entries, u64(n))
	expect_tree_ok(t, &txn)

	for i in 0 ..< n {
		key: [8]byte
		value, err := kv.get(&txn, u64_key(&key, u64(i)))
		testing.expect_value(t, err, kv.Error.None)
		testing.expect(t, bytes.equal(value, big[:sizes[i % len(sizes)]]), "wrong value after overwrite")
	}
}

@(test)
test_put_max_size_keys :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	max_key := kv.max_key_size(env.page_size)
	value_len := kv.overflow_threshold(env.page_size) - kv.leaf_node_size(max_key, 0, false)
	value := make([]byte, value_len, context.temp_allocator)
	n := 400
	ids := make([]u64, n, context.temp_allocator)
	for &id, i in ids {
		id = u64(i)
	}
	rand.shuffle(ids)

	key := make([]byte, max_key, context.temp_allocator)
	for id in ids {
		u64_key((^[8]byte)(&key[max_key - 8]), id)
		testing.expect_value(t, kv.put(&txn, key, value), kv.Error.None)
	}
	testing.expect_value(t, txn.snapshot.entries, u64(n))
	testing.expectf(t, txn.snapshot.depth >= 4, "expected a deep tree, got depth %d", txn.snapshot.depth)
	expect_tree_ok(t, &txn)

	for id in ids {
		u64_key((^[8]byte)(&key[max_key - 8]), id)
		got, err := kv.get(&txn, key)
		testing.expect(t, err == .None && len(got) == value_len, "max-size key lost")
	}
}

@(test)
test_put_empty_key_and_value :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("b"), transmute([]byte)string("x")), kv.Error.None)
	testing.expect_value(t, kv.put(&txn, nil, nil), kv.Error.None)
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("a"), nil), kv.Error.None)

	value, err := kv.get(&txn, nil)
	testing.expect(t, err == .None && len(value) == 0, "empty key")
	value, err = kv.get(&txn, transmute([]byte)string("a"))
	testing.expect(t, err == .None && len(value) == 0, "empty value")
	testing.expect_value(t, txn.snapshot.entries, 3)
	expect_tree_ok(t, &txn)
}

@(test)
test_put_errors :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	too_long := make([]byte, kv.max_key_size(env.page_size) + 1, context.temp_allocator)
	testing.expect_value(t, kv.put(&txn, too_long, nil), kv.Error.Key_Too_Large)
	testing.expect_value(t, kv.put(&txn, too_long[:len(too_long) - 1], nil), kv.Error.None)

	// Argument errors don't poison the transaction.
	testing.expect_value(t, txn.err, kv.Error.None)
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("k"), transmute([]byte)string("v")), kv.Error.None)

	reader, err := kv.txn_begin(env)
	testing.expect_value(t, err, kv.Error.None)
	testing.expect_value(t, kv.put(&reader, transmute([]byte)string("k"), nil), kv.Error.Txn_Read_Only)
	kv.txn_abort(&reader)
}

@(test)
test_abort_discards_changes :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	n := 1_000
	build_tree_file(t, path, even_entries(n))

	env, txn, ok := open_write(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	before := kv.env_snapshot(env)

	// The writer lock is held for the whole write transaction.
	testing.expect(t, !sync.mutex_try_lock(&env.writer_mutex), "writer lock not held")

	for i in 0 ..< n {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(2 * i + 1)), transmute([]byte)string("new"))
		kv.put(&txn, u64_key(&key, u64(2 * i)), transmute([]byte)string("changed"))
	}
	testing.expect_value(t, txn.snapshot.entries, u64(2 * n))
	kv.txn_abort(&txn)

	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, sync.mutex_try_lock(&env.writer_mutex), "writer lock not released")
	sync.mutex_unlock(&env.writer_mutex)

	reader, err := kv.txn_begin(env)
	testing.expect_value(t, err, kv.Error.None)
	defer kv.txn_abort(&reader)
	expect_even_entries(t, &reader, n)
}

@(test)
test_copy_on_write_leaves_committed_pages_alone :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	n := 3_000
	tree := build_tree_file(t, path, even_entries(n))

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	// A reader that began before the writer.
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)

	committed_size := (int(tree.last_pgno) + 1) * env.page_size
	committed := slice.clone(env.map_base[:committed_size], context.temp_allocator)

	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	for _ in 0 ..< 2 * n {
		key: [8]byte
		testing.expect_value(t, kv.put(&txn, u64_key(&key, rand.uint64() % u64(4 * n)), transmute([]byte)string("w")), kv.Error.None)
	}
	expect_tree_ok(t, &txn)

	testing.expect(t, bytes.equal(env.map_base[:committed_size], committed), "a committed page was modified")
	testing.expect(t, txn.snapshot.root != tree.root, "root was not copied")
	testing.expect(t, slice.contains(txn.write.freed[:], tree.root), "old root not recorded as freed")
	testing.expect(t, txn.snapshot.last_pgno > tree.last_pgno, "no new pages allocated")

	// The earlier reader still sees exactly the committed tree.
	expect_even_entries(t, &reader, n)
}

@(test)
test_map_full_leaves_txn_usable :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// 64 KiB: 16 pages of 4 KiB, two of them meta pages.
	env, txn, ok := open_write(t, temp_dir_file(dir, DB), kv.Options{map_size = 64 * 1024})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	value: [100]byte
	stored := 0
	err: kv.Error
	for i in 0 ..< 10_000 {
		key: [8]byte
		err = kv.put(&txn, u64_key(&key, u64(i)), value[:])
		if err != .None {
			break
		}
		stored += 1
	}
	testing.expect_value(t, err, kv.Error.Map_Full)
	testing.expect(t, stored > 100, "map filled suspiciously early")
	testing.expect(t, (int(txn.snapshot.last_pgno) + 1) * env.page_size <= env.map_size, "allocated past the map")

	// Nothing was left half-done: the tree is intact and still usable.
	testing.expect_value(t, txn.err, kv.Error.None)
	testing.expect_value(t, txn.snapshot.entries, u64(stored))
	expect_tree_ok(t, &txn)
	for i in 0 ..< stored {
		key: [8]byte
		_, get_err := kv.get(&txn, u64_key(&key, u64(i)))
		if get_err != .None {
			testing.expectf(t, false, "key %d lost after Map_Full", i)
			break
		}
	}
}

// Random puts over a small key space, so many are overwrites, with value
// sizes up to the overflow threshold, checked against an in-memory map.
@(test)
test_put_random_vs_oracle :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	oracle := make(map[string][]byte, context.temp_allocator)
	threshold := kv.overflow_threshold(env.page_size)
	key_buf, value_buf: [kv.MAX_PAGE_SIZE / 4]byte

	for _ in 0 ..< 20_000 {
		key_len := 1 + rand.int_max(40)
		k := key_buf[:key_len]
		for &b in k {
			b = 'a' + byte(rand.int_max(4))
		}
		max_value := threshold - kv.leaf_node_size(key_len, 0, false)
		v := value_buf[:rand.int_max(max_value + 1) if rand.int_max(10) == 0 else rand.int_max(60)]
		random_bytes(v)

		if err := kv.put(&txn, k, v); err != .None {
			testing.expectf(t, false, "put failed: %v", err)
			return
		}
		oracle[string(slice.clone(k, context.temp_allocator))] = slice.clone(v, context.temp_allocator)
	}

	testing.expect_value(t, txn.snapshot.entries, u64(len(oracle)))
	expect_tree_ok(t, &txn)
	for k, v in oracle {
		got, err := kv.get(&txn, transmute([]byte)k)
		if err != .None || !bytes.equal(got, v) {
			testing.expectf(t, false, "key %q: %v", k, err)
			return
		}
	}
}
