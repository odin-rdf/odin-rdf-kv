package kv_tests

import "core:math/rand"
import "core:mem"
import "core:testing"

import kv "../kv"

// Every read-path operation on a populated database, including overflow
// values, allocates nothing and returns slices into the map.
@(test)
test_reads_allocate_nothing :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	KEYS :: 3_000
	ks := key_space_make(KEYS)
	value_buf := make([]byte, MODEL_MAX_VALUE, context.temp_allocator)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	{
		txn, _ := kv.txn_begin(env, read_only = false)
		for id in 0 ..< KEYS {
			// Every tenth value in an overflow run.
			size := 2 * env.page_size if id % 10 == 0 else 30
			kv.put(&txn, ks.keys[id], model_value(id, {true, 1, size}, value_buf))
		}
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	}

	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	map_start := uintptr(env.map_base)
	map_end := map_start + uintptr(env.map_size)
	in_map :: proc(s: []byte, start, end: uintptr) -> bool {
		p := uintptr(raw_data(s))
		return len(s) == 0 || (p >= start && p + uintptr(len(s)) <= end)
	}
	outside, found, scanned := 0, 0, 0
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&track)

		for _ in 0 ..< 10_000 {
			value, get_err := kv.get(&txn, ks.keys[rand.int_max(KEYS)])
			if get_err == .None {
				found += 1
				outside += 0 if in_map(value, map_start, map_end) else 1
			}
		}
		c := kv.cursor_open(&txn)
		for key, value, e := kv.cursor_first(&c); e == .None; key, value, e = kv.cursor_next(&c) {
			scanned += 1
			outside += 0 if in_map(key, map_start, map_end) && in_map(value, map_start, map_end) else 1
		}
		for _, _, e := kv.cursor_last(&c); e == .None; _, _, e = kv.cursor_prev(&c) {
			scanned += 1
		}
		for _ in 0 ..< 1_000 {
			kv.cursor_seek(&c, ks.keys[rand.int_max(KEYS)])
			kv.cursor_next(&c)
			kv.cursor_prev(&c)
		}
	}
	testing.expect_value(t, found, 10_000)
	testing.expect_value(t, scanned, 2 * KEYS)
	testing.expect_value(t, outside, 0)
	testing.expect_value(t, track.total_allocation_count, 0)
}
