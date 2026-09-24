package kv_tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

import kv "../kv"

// Value length for shape tests: a node plus its slot takes 218 bytes, so 18
// fill a leaf, 4 or fewer are under a quarter, and a leaf of 5 merges with
// one of up to 13.
SHAPE_VAL :: 200

// `count` entries with 8-byte big-endian keys from, from + 1, ... and values
// of `val_len` bytes, each filled with the key's low byte. Allocated with
// the temp allocator.
sized_entries :: proc(from, count: int, val_len := SHAPE_VAL) -> []Entry {
	entries := make([]Entry, count, context.temp_allocator)
	for &e, i in entries {
		key := make([]byte, 8, context.temp_allocator)
		endian.put_u64(key, .Big, u64(from + i))
		value := make([]byte, val_len, context.temp_allocator)
		slice.fill(value, byte(from + i))
		e = {key, value}
	}
	return entries
}

// Builds a tree of the given shape (see build_tree_shape) and begins a
// write transaction on it.
open_shape :: proc(t: ^testing.T, path: string, leaves: [][]Entry, levels: [][]int) -> (env: ^kv.Env, txn: kv.Txn, ok: bool) {
	build_tree_shape(t, path, leaves, levels)
	return open_write(t, path)
}

// Checks that keys 0 ..< n are all present with their SHAPE_VAL-byte
// values, except those in `gone`, and that nothing else is.
expect_shape_keys :: proc(t: ^testing.T, txn: ^kv.Txn, n: int, gone: ..int, loc := #caller_location) {
	present := 0
	for k in 0 ..< n {
		key: [8]byte
		value, err := kv.get(txn, u64_key(&key, u64(k)))
		if slice.contains(gone, k) {
			testing.expectf(t, err == .Not_Found, "key %d: %v, want Not_Found", k, err, loc = loc)
			continue
		}
		present += 1
		if err != .None || len(value) != SHAPE_VAL || value[0] != byte(k) {
			testing.expectf(t, false, "key %d: %d bytes, %v", k, len(value), err, loc = loc)
		}
	}
	testing.expect_value(t, txn.snapshot.entries, u64(present), loc = loc)
	expect_tree_ok(t, txn, loc)
	expect_space_ok(t, txn, loc)
}

del_u64 :: proc(txn: ^kv.Txn, k: int) -> kv.Error {
	key: [8]byte
	return kv.del(txn, u64_key(&key, u64(k)))
}

// Commits, then checks the new snapshot's tree and space accounting.
commit_ok :: proc(t: ^testing.T, env: ^kv.Env, txn: ^kv.Txn, loc := #caller_location) -> bool {
	err := kv.txn_commit(txn)
	testing.expect_value(t, err, kv.Error.None, loc = loc)
	return err == .None && expect_latest_ok(t, env, loc)
}

root_page :: proc(txn: ^kv.Txn) -> []byte {
	return kv.page_ptr(txn, txn.snapshot.root)
}

// A leaf that stays above a quarter full is left alone: the delete copies
// its path and nothing else.
@(test)
test_del_no_merge :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 18), sized_entries(18, 18), sized_entries(36, 18)}, {{3}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 5), kv.Error.None)
	testing.expect_value(t, len(txn.write.freed), 2)
	testing.expect_value(t, len(txn.write.loose), 0)
	testing.expect_value(t, txn.snapshot.depth, 2)
	testing.expect_value(t, kv.page_num_keys(root_page(&txn)), 3)
	expect_shape_keys(t, &txn, 54, 5)
	commit_ok(t, env, &txn)
}

// An underfull page takes in its right sibling rather than its left one;
// the left one isn't touched.
@(test)
test_del_merges_right_sibling :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	// Leaves 2, 3, 4; root 5.
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 5), sized_entries(5, 3), sized_entries(8, 5)}, {{3}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 6), kv.Error.None)
	root := root_page(&txn)
	testing.expect_value(t, kv.page_num_keys(root), 2)
	testing.expect_value(t, kv.branch_child(root, 0), 2)
	testing.expect(t, slice.contains(txn.write.freed[:], 4), "right sibling not freed")
	testing.expect_value(t, len(txn.write.freed), 3)
	testing.expect_value(t, kv.page_num_keys(kv.page_ptr(&txn, kv.branch_child(root, 1))), 7)
	expect_shape_keys(t, &txn, 13, 6)
	commit_ok(t, env, &txn)
}

// The rightmost child has no right sibling, so it takes in its left one,
// and the left slot is pointed at the merged page.
@(test)
test_del_merges_left_sibling :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 18), sized_entries(18, 5), sized_entries(23, 3)}, {{3}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 24), kv.Error.None)
	root := root_page(&txn)
	testing.expect_value(t, kv.page_num_keys(root), 2)
	merged := kv.branch_child(root, 1)
	testing.expect(t, merged > 5, "merged page should be the copy of the path's leaf")
	testing.expect(t, slice.contains(txn.write.freed[:], 3), "left sibling not freed")
	testing.expect_value(t, kv.page_num_keys(kv.page_ptr(&txn, merged)), 7)
	// The left slot keeps its separator: the left sibling's first key.
	key: [8]byte
	testing.expect(t, bytes.equal(kv.node_key(root, 1), u64_key(&key, 18)), "separator changed")
	expect_shape_keys(t, &txn, 26, 24)
	commit_ok(t, env, &txn)
}

// Neither sibling fits, so the page stays underfull (KV-I-0003 D1).
@(test)
test_del_no_merge_when_siblings_full :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 18), sized_entries(18, 3), sized_entries(21, 18)}, {{3}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 19), kv.Error.None)
	testing.expect_value(t, kv.page_num_keys(root_page(&txn)), 3)
	testing.expect_value(t, len(txn.write.freed), 2)
	expect_shape_keys(t, &txn, 39, 19)
	commit_ok(t, env, &txn)
}

// A leaf merge leaves its parent with one child; the parent takes in its
// right sibling, bringing the root's separator down onto that sibling's
// first slot.
@(test)
test_del_branch_merge :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	leaves := [][]Entry{
		sized_entries(0, 3), sized_entries(3, 3), // under B0
		sized_entries(6, 18), sized_entries(24, 18), sized_entries(42, 18), // under B1
		sized_entries(60, 18), // under B2
	}
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), leaves, {{2, 3, 1}, {3}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 1), kv.Error.None)
	testing.expect_value(t, txn.snapshot.depth, 3)
	root := root_page(&txn)
	testing.expect_value(t, kv.page_num_keys(root), 2)
	key: [8]byte
	testing.expect(t, bytes.equal(kv.node_key(root, 1), u64_key(&key, 60)), "root's second separator should lead to B2")
	b0 := kv.page_ptr(&txn, kv.branch_child(root, 0))
	testing.expect_value(t, kv.page_num_keys(b0), 4)
	want := []u64{0, 6, 24, 42}
	for w, i in want[1:] {
		testing.expect(t, bytes.equal(kv.node_key(b0, i + 1), u64_key(&key, w)), "separator not brought down")
	}
	expect_shape_keys(t, &txn, 78, 1)
	commit_ok(t, env, &txn)
}

// The rightmost branch takes in its left sibling, with the root's separator
// for the path page brought down; the root is left with one child and
// collapses.
@(test)
test_del_branch_merge_left_collapses_root :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	leaves := [][]Entry{
		sized_entries(0, 18), sized_entries(18, 18), sized_entries(36, 18), // under B0
		sized_entries(54, 3), sized_entries(57, 3), // under B1
	}
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), leaves, {{3, 2}, {2}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 55), kv.Error.None)
	testing.expect_value(t, txn.snapshot.depth, 2)
	root := root_page(&txn)
	testing.expect_value(t, kv.page_num_keys(root), 4)
	key: [8]byte
	testing.expect(t, bytes.equal(kv.node_key(root, 3), u64_key(&key, 54)), "separator not brought down")
	expect_shape_keys(t, &txn, 60, 55)
	commit_ok(t, env, &txn)
}

// An emptied first leaf is dropped; the root's new first slot becomes −∞,
// and the leaf after it isn't copied.
@(test)
test_del_drops_empty_first_leaf :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 1), sized_entries(1, 18), sized_entries(19, 18)}, {{3}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 0), kv.Error.None)
	root := root_page(&txn)
	testing.expect_value(t, kv.page_num_keys(root), 2)
	testing.expect_value(t, len(kv.node_key(root, 0)), 0)
	testing.expect_value(t, kv.branch_child(root, 0), 3)
	testing.expect_value(t, len(txn.write.freed), 2)
	expect_shape_keys(t, &txn, 37, 0)
	commit_ok(t, env, &txn)
}

// An emptied leaf whose parent has no other child is dropped, the parent
// with it, and the root, left with one child, collapses.
@(test)
test_del_drops_empty_leaf_under_single_child_parent :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	// Leaves 2 (under B0 = 5), 3 and 4 (under B1 = 6); root 7.
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 1), sized_entries(1, 18), sized_entries(19, 18)}, {{1, 2}, {2}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, del_u64(&txn, 0), kv.Error.None)
	testing.expect_value(t, txn.snapshot.depth, 2)
	testing.expect_value(t, txn.snapshot.root, 6)
	expect_shape_keys(t, &txn, 37, 0)
	commit_ok(t, env, &txn)
}

// Empty pages are dropped up to the root, which then collapses through two
// single-child levels.
@(test)
test_del_collapses_several_levels :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	// Leaves 2, 3, 4; Y0 = 5 over 2, Y1 = 6 over 3 and 4; X0 = 7, X1 = 8;
	// root 9.
	env, txn, ok := open_shape(t, temp_dir_file(dir, DB), {sized_entries(0, 1), sized_entries(1, 18), sized_entries(19, 18)}, {{1, 2}, {1, 1}, {2}})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	testing.expect_value(t, txn.snapshot.depth, 4)

	testing.expect_value(t, del_u64(&txn, 0), kv.Error.None)
	testing.expect_value(t, txn.snapshot.depth, 2)
	testing.expect_value(t, txn.snapshot.root, 6)
	expect_shape_keys(t, &txn, 37, 0)
	commit_ok(t, env, &txn)
}

// Deleting every key, over several commits and in random order, leaves the
// empty tree with every page free, and the tree grows again from there.
@(test)
test_del_last_key :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	env, txn, ok := open_write(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)

	N :: 3000
	value :: proc(k: int) -> []byte {
		// Every 50th value lives in an overflow run.
		n := 5000 if k % 50 == 0 else 1 + k % 90
		v := make([]byte, n, context.temp_allocator)
		slice.fill(v, byte(k))
		return v
	}
	for k in 0 ..< N {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(k)), value(k))
	}
	if !commit_ok(t, env, &txn) {
		return
	}

	order := make([]int, N, context.temp_allocator)
	for &k, i in order {
		k = i
	}
	rand.shuffle(order)
	for batch in 0 ..< 10 {
		txn, _ = kv.txn_begin(env, read_only = false)
		for k in order[batch * N / 10:(batch + 1) * N / 10] {
			if err := del_u64(&txn, k); err != .None {
				testing.expectf(t, false, "del %d: %v", k, err)
				kv.txn_abort(&txn)
				return
			}
		}
		if !expect_tree_ok(t, &txn) || !commit_ok(t, env, &txn) {
			return
		}
	}
	snap := kv.env_snapshot(env)
	testing.expect_value(t, snap.root, 0)
	testing.expect_value(t, snap.depth, 0)
	testing.expect_value(t, snap.entries, 0)

	// The tree grows again from nothing.
	txn, _ = kv.txn_begin(env, read_only = false)
	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 7), value(7)), kv.Error.None)
	got, err := kv.get(&txn, u64_key(&key, 7))
	testing.expect(t, err == .None && bytes.equal(got, value(7)), "get after regrowth")
	commit_ok(t, env, &txn)
}

// A value's overflow run is freed with it: to `freed` if it was committed,
// to `loose` if this transaction wrote it.
@(test)
test_del_overflow_value :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)

	big := make([]byte, 10_000, context.temp_allocator)
	run := kv.overflow_pages(env.page_size, len(big))
	for k in 0 ..< 100 {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(k)), big if k == 50 else {byte(k)})
	}
	if !commit_ok(t, env, &txn) {
		return
	}

	txn, _ = kv.txn_begin(env, read_only = false)
	testing.expect_value(t, del_u64(&txn, 50), kv.Error.None)
	testing.expect_value(t, len(txn.write.freed), int(txn.snapshot.depth) + run)
	testing.expect_value(t, len(txn.write.loose), 0)
	if !commit_ok(t, env, &txn) {
		return
	}

	txn, _ = kv.txn_begin(env, read_only = false)
	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 1000), big), kv.Error.None)
	freed := len(txn.write.freed)
	testing.expect_value(t, del_u64(&txn, 1000), kv.Error.None)
	testing.expect_value(t, len(txn.write.loose), run)
	testing.expect_value(t, len(txn.write.freed), freed)
	commit_ok(t, env, &txn)
}

// A missing key changes nothing: no page is copied and a cursor stays
// valid. A successful delete makes the cursor stale.
@(test)
test_del_not_found_changes_nothing :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	build_tree_file(t, path, even_entries(2000))
	env, txn, ok := open_write(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	c := kv.cursor_open(&txn)
	kv.cursor_first(&c)
	mods := txn.mods
	key: [8]byte
	testing.expect_value(t, kv.del(&txn, u64_key(&key, 7)), kv.Error.Not_Found)
	testing.expect_value(t, kv.del(&txn, u64_key(&key, 1_000_000)), kv.Error.Not_Found)
	testing.expect_value(t, len(txn.write.dirty), 0)
	testing.expect_value(t, txn.mods, mods)
	testing.expect_value(t, txn.err, kv.Error.None)
	testing.expect(t, !kv.cursor_stale(&c), "cursor went stale")
	k, _, err := kv.cursor_next(&c)
	testing.expect(t, err == .None && bytes.equal(k, u64_key(&key, 2)), "cursor_next after a miss")

	testing.expect_value(t, kv.del(&txn, u64_key(&key, 8)), kv.Error.None)
	testing.expect(t, kv.cursor_stale(&c), "cursor should be stale after a delete")
}

@(test)
test_del_read_only :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	build_tree_file(t, path, even_entries(10))
	env, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	key: [8]byte
	testing.expect_value(t, kv.del(&txn, u64_key(&key, 2)), kv.Error.Txn_Read_Only)
}

// A delete needs its path's worth of pages. With none left it returns
// Map_Full and changes nothing; at a full map with reusable pages it
// succeeds until they run out.
@(test)
test_del_map_full :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{map_size = 256 * 1024})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	N :: 300
	txn, _ := kv.txn_begin(env, read_only = false)
	for k in 0 ..< N {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(k)), transmute([]byte)fmt.tprintf("%030d", k))
	}
	if !commit_ok(t, env, &txn) {
		return
	}
	// A reader pins every page while overwrites fill the map.
	{
		reader, _ := kv.txn_begin(env)
		defer kv.txn_abort(&reader)
		full: for round := 1; ; round += 1 {
			txn, _ = kv.txn_begin(env, read_only = false)
			for k in 0 ..< N {
				key: [8]byte
				if kv.put(&txn, u64_key(&key, u64(k)), transmute([]byte)fmt.tprintf("%030d", k + round)) != .None {
					kv.txn_abort(&txn)
					break full
				}
			}
			if kv.txn_commit(&txn) != .None {
				break full
			}
		}
	}

	// Take every page there is, then delete.
	txn, _ = kv.txn_begin(env, read_only = false)
	for {
		if _, _, alloc_err := kv.page_alloc(&txn, 1); alloc_err != .None {
			break
		}
	}
	dirty := len(txn.write.dirty)
	mods := txn.mods
	testing.expect_value(t, del_u64(&txn, 10), kv.Error.Map_Full)
	testing.expect_value(t, len(txn.write.dirty), dirty)
	testing.expect_value(t, txn.mods, mods)
	testing.expect_value(t, txn.err, kv.Error.None)
	kv.txn_abort(&txn)

	// The same with the end of the map used up but reusable pages left:
	// the pages the reader pinned. Runs as long as the room left are only
	// found at the end of the map, whatever the free list holds.
	txn, _ = kv.txn_begin(env, read_only = false)
	for {
		end_room := env.map_size / env.page_size - int(txn.snapshot.last_pgno) - 1
		if end_room == 0 {
			break
		}
		if _, _, alloc_err := kv.page_alloc(&txn, end_room); alloc_err != .None {
			testing.expectf(t, false, "page_alloc(%d): %v", end_room, alloc_err)
			kv.txn_abort(&txn)
			return
		}
	}
	ready := kv.env_stats(env).free_ready
	testing.expect(t, ready >= int(txn.snapshot.depth), "no reusable pages")
	// Deletes succeed while the reusable pages last, then stop cleanly: the
	// pages they free only become reusable after later commits.
	deleted := 0
	for k in 0 ..< N / 2 {
		del_err := del_u64(&txn, 2 * k)
		if del_err == .Map_Full {
			break
		}
		testing.expect_value(t, del_err, kv.Error.None)
		deleted += 1
	}
	testing.expectf(t, deleted > 0, "no delete fit in %d reusable pages", ready)
	testing.expect_value(t, txn.err, kv.Error.None)
	testing.expect_value(t, txn.snapshot.entries, u64(N - deleted))
	// The pages taken above belong to nothing, so the transaction isn't
	// committed.
	expect_tree_ok(t, &txn)
	kv.txn_abort(&txn)
}

// A delete may be given a key that points into the transaction's own
// pages: from a cursor (deleting everything, and a range), or a value
// from get.
@(test)
test_del_key_from_same_txn :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	N :: 3000
	big := make([]byte, 6000, context.temp_allocator)
	for k in 0 ..< N {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(k)), big if k % 100 == 0 else {byte(k)})
	}

	// A value that is another key.
	key, other: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 1), u64_key(&other, 2)), kv.Error.None)
	value, _ := kv.get(&txn, u64_key(&key, 1))
	testing.expect_value(t, kv.del(&txn, value), kv.Error.None)
	_, err := kv.get(&txn, u64_key(&key, 2))
	testing.expect_value(t, err, kv.Error.Not_Found)

	// A range, [1000, 2000), as del's comment shows.
	start, end: [8]byte
	u64_key(&start, 1000)
	u64_key(&end, 2000)
	c := kv.cursor_open(&txn)
	buf: [kv.MAX_KEY_SIZE_ANY]byte
	for k, _, seek_err := kv.cursor_seek(&c, start[:]); seek_err == .None && bytes.compare(k, end[:]) < 0; {
		n := copy(buf[:], k)
		if del_err := kv.del(&txn, k); del_err != .None {
			testing.expectf(t, false, "range del: %v", del_err)
			return
		}
		k, _, seek_err = kv.cursor_seek(&c, buf[:n])
	}
	testing.expect_value(t, txn.snapshot.entries, u64(N - 1 - 1000))
	_, err = kv.get(&txn, u64_key(&key, 999))
	testing.expect_value(t, err, kv.Error.None)
	_, err = kv.get(&txn, u64_key(&key, 2000))
	testing.expect_value(t, err, kv.Error.None)
	expect_tree_ok(t, &txn)
	expect_space_ok(t, &txn)

	// Everything, through cursor_first.
	deleted := 0
	for k, _, first_err := kv.cursor_first(&c); first_err == .None; k, _, first_err = kv.cursor_first(&c) {
		if del_err := kv.del(&txn, k); del_err != .None {
			testing.expectf(t, false, "del: %v", del_err)
			return
		}
		deleted += 1
	}
	testing.expect_value(t, deleted, N - 1 - 1000)
	testing.expect_value(t, txn.snapshot.root, 0)
	expect_tree_ok(t, &txn)
	expect_space_ok(t, &txn)
	commit_ok(t, env, &txn)
}

// Aborting after deletes leaves the database and the free list as they
// were; committed deletes survive a reopen.
@(test)
test_del_abort_and_reopen :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	N :: 2000
	build_tree_shape(t, path, {sized_entries(0, 18)}, {})
	env, txn, ok := open_write(t, path)
	if !ok {
		return
	}
	for k in 18 ..< N {
		key: [8]byte
		value: [SHAPE_VAL]byte
		slice.fill(value[:], byte(k))
		kv.put(&txn, u64_key(&key, u64(k)), value[:])
	}
	if !commit_ok(t, env, &txn) {
		kv.env_close(env)
		return
	}
	// A commit that frees pages, so the free list isn't empty.
	txn, _ = kv.txn_begin(env, read_only = false)
	del_u64(&txn, 0)
	commit_ok(t, env, &txn)

	// A write transaction's begin releases pending pages whatever it does
	// afterwards, so compare against the state after one.
	txn, _ = kv.txn_begin(env, read_only = false)
	kv.txn_abort(&txn)
	before, before_stats := kv.env_snapshot(env), kv.env_stats(env)
	txn, _ = kv.txn_begin(env, read_only = false)
	for k in 1 ..< N {
		if k % 3 != 0 {
			del_u64(&txn, k)
		}
	}
	kv.txn_abort(&txn)
	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect_value(t, kv.env_stats(env), before_stats)
	reader, _ := kv.txn_begin(env)
	expect_shape_keys(t, &reader, N, 0)
	kv.txn_abort(&reader)

	gone := make([dynamic]int, context.temp_allocator)
	append(&gone, 0)
	txn, _ = kv.txn_begin(env, read_only = false)
	for k in 1 ..< N {
		if k % 3 != 0 {
			del_u64(&txn, k)
			append(&gone, k)
		}
	}
	commit_ok(t, env, &txn)
	kv.env_close(env)

	env2, reader2, ok2 := open_read(t, path)
	if !ok2 {
		return
	}
	defer kv.env_close(env2)
	defer kv.txn_abort(&reader2)
	expect_shape_keys(t, &reader2, N, ..gone[:])
}
