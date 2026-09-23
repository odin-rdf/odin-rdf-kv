package kv_tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:testing"

import kv "../kv"

// The number encoded in an 8-byte big-endian key, or max(u64) for anything
// else.
key_u64 :: proc(key: []byte) -> u64 {
	v, ok := endian.get_u64(key, .Big)
	return v if ok && len(key) == 8 else max(u64)
}

// Builds even_entries(n) at `path` and begins a read transaction on it.
open_even_tree :: proc(t: ^testing.T, path: string, n: int) -> (env: ^kv.Env, txn: kv.Txn, ok: bool) {
	build_tree_file(t, path, even_entries(n))
	return open_read(t, path)
}

@(test)
test_cursor_full_scans :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	n := 20_000
	env, txn, ok := open_even_tree(t, temp_dir_file(dir, DB), n)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	testing.expect(t, txn.snapshot.depth >= 2, "want several leaves")

	c := kv.cursor_open(&txn)
	count := 0
	for key, value, err := kv.cursor_first(&c); err == .None; key, value, err = kv.cursor_next(&c) {
		if key_u64(key) != u64(2 * count) || string(value) != fmt.tprintf("v%d", count) {
			testing.expectf(t, false, "forward item %d: key %d value %q", count, key_u64(key), string(value))
			return
		}
		count += 1
	}
	testing.expect_value(t, count, n)

	count = 0
	for key, _, err := kv.cursor_last(&c); err == .None; key, _, err = kv.cursor_prev(&c) {
		if key_u64(key) != u64(2 * (n - 1 - count)) {
			testing.expectf(t, false, "backward item %d: key %d", count, key_u64(key))
			return
		}
		count += 1
	}
	testing.expect_value(t, count, n)
}

@(test)
test_cursor_seek :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	n := 5_000
	env, txn, ok := open_even_tree(t, temp_dir_file(dir, DB), n)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	c := kv.cursor_open(&txn)

	for target in u64(0) ..< u64(2 * n) {
		kb: [8]byte
		key, _, err := kv.cursor_seek(&c, u64_key(&kb, target))
		// Existing keys are found exactly; odd ones land on the next even key.
		want := target if target % 2 == 0 else target + 1
		if want >= u64(2 * n) {
			testing.expect_value(t, err, kv.Error.Not_Found)
			continue
		}
		if err != .None || key_u64(key) != want {
			testing.expectf(t, false, "seek %d: got %d, %v", target, key_u64(key), err)
			return
		}
	}

	// Before the first key: lands on it.
	key, _, err := kv.cursor_seek(&c, nil)
	testing.expect(t, err == .None && key_u64(key) == 0, "seek before first")

	// After the last key: Not_Found, then prev gives the last key.
	kb: [8]byte
	_, _, err = kv.cursor_seek(&c, u64_key(&kb, max(u64)))
	testing.expect_value(t, err, kv.Error.Not_Found)
	_, _, err = kv.cursor_next(&c)
	testing.expect_value(t, err, kv.Error.Not_Found)
	key, _, err = kv.cursor_prev(&c)
	testing.expect(t, err == .None && key_u64(key) == u64(2 * (n - 1)), "prev after seeking past the end")
}

@(test)
test_cursor_range_scan :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_even_tree(t, temp_dir_file(dir, DB), 10_000)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	// [1001, 3000): the even keys 1002 .. 2998.
	sb, eb: [8]byte
	start, end := u64_key(&sb, 1001), u64_key(&eb, 3000)
	c := kv.cursor_open(&txn)
	want := u64(1002)
	for key, _, err := kv.cursor_seek(&c, start); err == .None; key, _, err = kv.cursor_next(&c) {
		if bytes.compare(key, end) >= 0 {
			break
		}
		if key_u64(key) != want {
			testing.expectf(t, false, "range scan: got %d, want %d", key_u64(key), want)
			return
		}
		want += 2
	}
	testing.expect_value(t, want, 3000)
}

// A random walk of next/prev steps, checked against the sorted key list,
// across leaf and branch boundaries and off both ends.
@(test)
test_cursor_random_walk :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	n := 3_000
	env, txn, ok := open_even_tree(t, temp_dir_file(dir, DB), n)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	c := kv.cursor_open(&txn)
	// Model position: -1 before the first key, n past the last, else index.
	pos := 0
	kv.cursor_first(&c)
	for step in 0 ..< 20_000 {
		// Head for the ends now and then, so both edges get exercised.
		forward := rand.int_max(2) == 0
		if step % 5_000 < 400 {
			forward = step % 10_000 < 5_000
		}
		move := kv.cursor_next if forward else kv.cursor_prev
		key, _, err := move(&c)
		if forward {
			pos = min(pos + 1, n)
		} else {
			pos = max(pos - 1, -1)
		}

		if pos < 0 || pos >= n {
			if err != .Not_Found {
				testing.expectf(t, false, "step %d: expected Not_Found at position %d, got %v", step, pos, err)
				return
			}
			continue
		}
		if err != .None || key_u64(key) != u64(2 * pos) {
			testing.expectf(t, false, "step %d: at %d got key %d, %v", step, pos, key_u64(key), err)
			return
		}
	}
}

@(test)
test_cursor_edge_states :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_even_tree(t, temp_dir_file(dir, DB), 3)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	// A fresh cursor: next is first, prev is last.
	c := kv.cursor_open(&txn)
	key, _, err := kv.cursor_next(&c)
	testing.expect(t, err == .None && key_u64(key) == 0, "fresh next")
	c = kv.cursor_open(&txn)
	key, _, err = kv.cursor_prev(&c)
	testing.expect(t, err == .None && key_u64(key) == 4, "fresh prev")

	// Off the start, and back.
	kv.cursor_first(&c)
	_, _, err = kv.cursor_prev(&c)
	testing.expect_value(t, err, kv.Error.Not_Found)
	_, _, err = kv.cursor_prev(&c)
	testing.expect_value(t, err, kv.Error.Not_Found)
	key, _, err = kv.cursor_next(&c)
	testing.expect(t, err == .None && key_u64(key) == 0, "next after running off the start")

	// Off the end, and back.
	kv.cursor_last(&c)
	_, _, err = kv.cursor_next(&c)
	testing.expect_value(t, err, kv.Error.Not_Found)
	key, _, err = kv.cursor_prev(&c)
	testing.expect(t, err == .None && key_u64(key) == 4, "prev after running off the end")
}

@(test)
test_cursor_empty_and_single :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	{
		env, txn, ok := open_read(t, path)
		if !ok {
			return
		}
		c := kv.cursor_open(&txn)
		_, _, e1 := kv.cursor_first(&c)
		_, _, e2 := kv.cursor_last(&c)
		_, _, e3 := kv.cursor_next(&c)
		_, _, e4 := kv.cursor_prev(&c)
		_, _, e5 := kv.cursor_seek(&c, nil)
		testing.expect(t, e1 == .Not_Found && e2 == .Not_Found && e3 == .Not_Found && e4 == .Not_Found && e5 == .Not_Found, "empty tree")
		kv.txn_abort(&txn)
		kv.env_close(env)
	}

	env, txn, ok := open_even_tree(t, path, 1)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	c := kv.cursor_open(&txn)
	key, value, err := kv.cursor_first(&c)
	testing.expect(t, err == .None && key_u64(key) == 0 && string(value) == "v0", "single first")
	_, _, err = kv.cursor_next(&c)
	testing.expect_value(t, err, kv.Error.Not_Found)
	key, _, err = kv.cursor_last(&c)
	testing.expect(t, err == .None && key_u64(key) == 0, "single last")
	_, _, err = kv.cursor_prev(&c)
	testing.expect_value(t, err, kv.Error.Not_Found)
}

// Maximum-size keys make a deep tree with a fan-out of 4, so steps cross
// several branch levels at once.
@(test)
test_cursor_deep_tree :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	max_key := kv.max_key_size(env.page_size)
	n := 300
	key := make([]byte, max_key, context.temp_allocator)
	for i in 0 ..< n {
		u64_key((^[8]byte)(&key[max_key - 8]), u64(i))
		kv.put(&txn, key, nil)
	}
	testing.expectf(t, txn.snapshot.depth >= 4, "want a deep tree, got %d", txn.snapshot.depth)

	c := kv.cursor_open(&txn)
	i := 0
	for k, _, err := kv.cursor_first(&c); err == .None; k, _, err = kv.cursor_next(&c) {
		testing.expect_value(t, key_u64(k[max_key - 8:]), u64(i))
		i += 1
	}
	testing.expect_value(t, i, n)
	for k, _, err := kv.cursor_last(&c); err == .None; k, _, err = kv.cursor_prev(&c) {
		i -= 1
		testing.expect_value(t, key_u64(k[max_key - 8:]), u64(i))
	}
	testing.expect_value(t, i, 0)
}

@(test)
test_cursor_in_write_txn :: proc(t: ^testing.T) {
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
	defer kv.txn_abort(&txn)

	// Fill in the odd keys, one of them with an overflow value.
	big := patterned(3 * env.page_size, 3)
	for i in 0 ..< n {
		kb: [8]byte
		value := big if i == 500 else transmute([]byte)string("odd")
		kv.put(&txn, u64_key(&kb, u64(2 * i + 1)), value)
	}

	c := kv.cursor_open(&txn)
	count := 0
	for key, value, err := kv.cursor_first(&c); err == .None; key, value, err = kv.cursor_next(&c) {
		if key_u64(key) != u64(count) {
			testing.expectf(t, false, "item %d: key %d", count, key_u64(key))
			return
		}
		if count == 1001 {
			testing.expect(t, bytes.equal(value, big), "overflow value through cursor")
		}
		count += 1
	}
	testing.expect_value(t, count, 2 * n)

	// A put makes the cursor stale; repositioning makes it usable again.
	testing.expect(t, !kv.cursor_stale(&c), "fresh cursor reported stale")
	kb: [8]byte
	kv.put(&txn, u64_key(&kb, 5_000_000), nil)
	testing.expect(t, kv.cursor_stale(&c), "cursor not stale after put")
	key, _, err := kv.cursor_last(&c)
	testing.expect(t, err == .None && key_u64(key) == 5_000_000, "last after put")
	testing.expect(t, !kv.cursor_stale(&c), "repositioned cursor still stale")
}

@(test)
test_cursor_no_alloc :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_even_tree(t, temp_dir_file(dir, DB), 5_000)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	count := 0
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&track)
		c := kv.cursor_open(&txn)
		for _, _, err := kv.cursor_first(&c); err == .None; _, _, err = kv.cursor_next(&c) {
			count += 1
		}
		for _, _, err := kv.cursor_last(&c); err == .None; _, _, err = kv.cursor_prev(&c) {
			count += 1
		}
		kb: [8]byte
		for i in 0 ..< 1_000 {
			kv.cursor_seek(&c, u64_key(&kb, u64(i * 7)))
		}
	}
	testing.expect_value(t, count, 10_000)
	testing.expect_value(t, track.total_allocation_count, 0)
}
