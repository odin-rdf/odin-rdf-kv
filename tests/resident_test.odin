package kv_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:testing"

import kv "../kv"

/*
The OS residency check (KV-I-0004 D10, KV-T-0024): env_resident_check
against the resident estimate. On Linux it reads /proc/self/pagemap, and
after reads it is at most the estimate (plus a small tolerance), and after
env_sweep(env, 0) it is 0. On macOS it returns Unsupported, and the same
two checks are made against the process's file-backed resident size
(task_info `external`) above a baseline taken after env_open.

Databases come from chunk_db_create: RESIDENT_KEYS keys of RESIDENT_VAL
bytes, about 20 MB in 64 KiB chunks, large enough that the macOS figures
stand out from what the rest of the process does meanwhile.
*/

@(private = "file")
RESIDENT_KEYS :: 10_000

@(private = "file")
RESIDENT_VAL :: 1_000

// How far the Linux check may exceed the estimate: a chunk. The estimate
// counts whole chunks and the OS pages, so without held slices read after
// an eviction (Q4) the check is never above it at all.
@(private = "file")
LINUX_TOLERANCE :: CHUNK_TEST_SIZE

// How far the process's file-backed resident size may move on macOS for
// reasons other than this map: the other tests run on other threads of the
// same process and map their own databases, so each check is tried a few
// times before it fails.
@(private = "file")
DARWIN_TOLERANCE :: 1 << 20

@(private = "file")
DARWIN_ATTEMPTS :: 5

// Reads every page of the tree, and every value's bytes, through a cursor.
@(private = "file")
scan_all :: proc(env: ^kv.Env) -> (sum: int) {
	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)
	c := kv.cursor_open(&txn)
	for _, v, err := kv.cursor_first(&c); err == .None; _, v, err = kv.cursor_next(&c) {
		sum += int(v[0]) + int(v[len(v) - 1])
	}
	return sum
}

// The bytes of the pages the tree uses (pages 2 to last_pgno).
@(private = "file")
tree_bytes :: proc(env: ^kv.Env) -> int {
	return (int(kv.env_snapshot(env).last_pgno) - 1) * env.page_size
}

@(test)
test_resident_check :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	path := temp_dir_file(dir, DB)
	env, ok := chunk_db_create(t, path, RESIDENT_KEYS, RESIDENT_VAL)
	if !ok {
		return
	}
	when ODIN_OS == .Linux {
		resident_check_linux(t, env)
		kv.env_close(env)
		resident_check_linux_budget(t, path)
	} else {
		resident_check_darwin(t, env)
		kv.env_close(env)
	}
}

// env_resident_check, which must succeed, is at most the estimate plus
// LINUX_TOLERANCE.
@(private = "file")
check_linux :: proc(t: ^testing.T, env: ^kv.Env, what: string, loc := #caller_location) -> (resident: int, ok: bool) {
	err: kv.Error
	resident, err = kv.env_resident_check(env)
	if !testing.expect_value(t, err, kv.Error.None, loc = loc) {
		return 0, false
	}
	estimate := kv.env_stats(env).resident_chunks * env.chunks.size
	ok = testing.expectf(t, resident <= estimate + LINUX_TOLERANCE, "%s: the OS holds %d bytes of the map, the estimate is %d", what, resident, estimate, loc = loc)
	return resident, ok
}

// env_resident_check, which must succeed, is 0.
@(private = "file")
expect_none_resident :: proc(t: ^testing.T, env: ^kv.Env, what: string, loc := #caller_location) -> bool {
	resident, err := kv.env_resident_check(env)
	return testing.expect_value(t, err, kv.Error.None, loc = loc) && testing.expectf(t, resident == 0, "%s: the OS holds %d bytes of the map", what, resident, loc = loc)
}

// Linux: env_resident_check after open, after a full scan, and after
// env_sweep(env, 0).
@(private = "file")
resident_check_linux :: proc(t: ^testing.T, env: ^kv.Env) {
	// After open: the meta pages' chunk.
	check_linux(t, env, "after open")

	// A full scan: every page of the tree is present, and counted.
	scan_all(env)
	if resident, ok := check_linux(t, env, "after a full scan"); ok {
		testing.expectf(t, resident >= tree_bytes(env), "after a full scan the OS holds %d bytes of the map, the tree is %d", resident, tree_bytes(env))
	}

	// Sleep: nothing of the map is left in the process.
	kv.env_sweep(env, 0)
	expect_none_resident(t, env, "after env_sweep(env, 0)")
}

/*
Linux, with a budget of 32 chunks: requests of one random get, whose transactions' ends
evict, then a sleep. After a transaction that evicted only at its end, the
check is within the estimate. One whose reads passed the hard watermark
and evicted inline is not checked strictly: when every chunk is
referenced, CLOCK's second turn can evict the chunk the current operation
has just marked, and the operation then reads its page back in uncounted
(KV-I-0004 Q4; measured, not corrected). Those are counted and logged.
*/
@(private = "file")
resident_check_linux_budget :: proc(t: ^testing.T, path: string) {
	env, err := kv.env_open(path, kv.Options{chunk_size = CHUNK_TEST_SIZE, mapped_budget = 32 * CHUNK_TEST_SIZE})
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)
	checked, excess := 0, 0
	for n in 0 ..< 400 {
		inline := kv.env_stats(env).inline_evictions
		txn, _ := kv.txn_begin(env)
		kv.get(&txn, transmute([]byte)fmt.tprintf("key%06d", rand.int_max(RESIDENT_KEYS)))
		kv.txn_abort(&txn)
		if kv.env_stats(env).inline_evictions == inline {
			checked += 1
			if _, ok := check_linux(t, env, fmt.tprintf("after request %d", n)); !ok {
				break
			}
		} else if resident, _ := kv.env_resident_check(env); resident > kv.env_stats(env).resident_chunks * env.chunks.size {
			excess += 1
		}
	}
	s := kv.env_stats(env)
	log.infof("%d of 400 requests checked; %d evicted inline, of which %d left the OS above the estimate (Q4)", checked, 400 - checked, excess)
	testing.expectf(t, checked >= 200, "only %d requests without an inline eviction", checked)
	testing.expect(t, s.txn_end_evictions > 0, "no eviction at a transaction's end")
	kv.env_sweep(env, 0)
	expect_none_resident(t, env, "after env_sweep(env, 0)")
}

/*
macOS: env_resident_check is Unsupported. The process's file-backed resident
size (task_info `external`) above a baseline taken after env_open grows by
at most the estimate during a full scan (and by at least half the tree, so
that the check sees the map at all), and is back at the baseline after
env_sweep(env, 0). `external` rather than the whole resident size, which
also carries malloc's retained pages and, under -sanitize:thread, the
sanitizer's shadow of every byte read (three times the file); the whole
resident size is logged beside it. Both are process-wide, and the other
tests run on other threads of the same process (mapping their own
databases), so each attempt starts from the same state (chunk 0 resident,
or nothing) and a disturbed one is tried again.
*/
@(private = "file")
resident_check_darwin :: proc(t: ^testing.T, env: ^kv.Env) {
	resident, err := kv.env_resident_check(env)
	testing.expect_value(t, err, kv.Error.Unsupported)
	testing.expect_value(t, resident, 0)

	grew, estimate, slept: int
	for attempt in 1 ..= DARWIN_ATTEMPTS {
		baseline, baseline_rss := process_file_resident(), platform_residency(nil, 0).rss
		scan_all(env)
		grew = process_file_resident() - baseline
		grew_rss := platform_residency(nil, 0).rss - baseline_rss
		estimate = kv.env_stats(env).resident_chunks * env.chunks.size
		kv.env_sweep(env, 0)
		slept = process_file_resident() - baseline
		if grew <= estimate + DARWIN_TOLERANCE && grew >= tree_bytes(env) / 2 && slept <= DARWIN_TOLERANCE {
			log.infof("attempt %d: file-backed resident size +%d bytes after a full scan (estimate %d; whole resident size +%d), %+d after env_sweep(env, 0)", attempt, grew, estimate, grew_rss, slept)
			return
		}
		log.warnf("attempt %d: file-backed resident size +%d bytes after a full scan (estimate %d, tree %d; whole resident size +%d), %+d after env_sweep(env, 0)", attempt, grew, estimate, tree_bytes(env), grew_rss, slept)
	}
	testing.expectf(t, grew <= estimate + DARWIN_TOLERANCE, "after a full scan the file-backed resident size grew by %d bytes, the estimate is %d", grew, estimate)
	testing.expectf(t, grew >= tree_bytes(env) / 2, "after a full scan the file-backed resident size grew by only %d bytes, the tree is %d", grew, tree_bytes(env))
	testing.expectf(t, slept <= DARWIN_TOLERANCE, "after env_sweep(env, 0) the file-backed resident size is %d bytes above the baseline", slept)
}
