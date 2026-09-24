package kv_tests

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strconv"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import kv "../kv"

/*
Eviction (KV-I-0004 D8, D9, KV-T-0023): env_sweep, inline eviction at the
hard watermark, and slices held across both. Databases come from
chunk_db_create: EVICT_KEYS keys of EVICT_VAL bytes (about 1,000 pages, 60
chunks of 64 KiB), the value of key i being patterned(EVICT_VAL, i).

Where the platform can say which pages are mapped (Linux, chunks_present),
the tests also check the OS's view: nothing present after env_sweep(env, 0),
and no chunk present that the estimate doesn't count.
*/

@(private = "file")
EVICT_KEYS :: 3_000

@(private = "file")
EVICT_VAL :: 1_000

@(private = "file")
evict_key :: proc(i: int) -> []byte {
	return transmute([]byte)fmt.tprintf("key%06d", i)
}

// Reads a page of each chunk in `chunks` through page_ptr.
@(private = "file")
read_chunks :: proc(txn: ^kv.Txn, chunks: ..int) {
	for c in chunks {
		kv.page_ptr(txn, kv.Pgno(c * CHUNK_PAGES + 1))
	}
}

// The chunks of the file with any page present in the process, or false
// where the OS can't say.
@(private = "file")
os_present :: proc(env: ^kv.Env) -> (present: []bool, ok: bool) {
	file_chunks := (int(env.file_size) + env.chunks.size - 1) / env.chunks.size
	return chunks_present(env.map_base, file_chunks * env.chunks.size, env.chunks.size)
}

// Where the OS can say: every chunk with pages present in the process is
// counted resident (the estimate is never under what it has seen).
@(private = "file")
expect_os_within_estimate :: proc(t: ^testing.T, env: ^kv.Env, loc := #caller_location) -> bool {
	present, ok := os_present(env)
	if !ok {
		return true
	}
	good := true
	for p, i in present {
		if p && sync.atomic_load(&env.chunks.bits[i]) & kv.CHUNK_RESIDENT == 0 {
			good = testing.expectf(t, false, "chunk %d is present but not counted", i, loc = loc)
		}
	}
	return good
}

// Where the OS can say: no page of the map is present in the process.
@(private = "file")
expect_os_empty :: proc(t: ^testing.T, env: ^kv.Env, loc := #caller_location) -> bool {
	present, ok := os_present(env)
	good := true
	for p, i in present {
		if ok && p {
			good = testing.expectf(t, false, "chunk %d still present after env_sweep(env, 0)", i, loc = loc)
		}
	}
	return good
}

// Where the OS can say, the chunks with pages present in the process that
// the estimate doesn't count, otherwise -1: pages read through slices held
// across an eviction (Q4). Logged by the tests that read such slices.
@(private = "file")
log_uncounted :: proc(env: ^kv.Env, loc := #caller_location) {
	present, ok := os_present(env)
	if !ok {
		return
	}
	n := 0
	for p, i in present {
		if p && sync.atomic_load(&env.chunks.bits[i]) & kv.CHUNK_RESIDENT == 0 {
			n += 1
		}
	}
	log.infof("%d chunks present in the process and not counted, %d counted", n, kv.env_stats(env).resident_chunks, location = loc)
}

// Compares held values with what key i was written with.
@(private = "file")
expect_values :: proc(t: ^testing.T, held: [][]byte, loc := #caller_location) -> bool {
	for v, i in held {
		if v != nil && !bytes.equal(v, patterned(EVICT_VAL, u32(i))) {
			return testing.expectf(t, false, "value of key %d changed", i, loc = loc)
		}
	}
	return true
}

@(test)
test_sweep_default_target :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	B :: 8
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = B * CHUNK_TEST_SIZE})
	if !ok {
		return
	}
	defer kv.env_close(env)
	testing.expect_value(t, env.chunks.limit, B)
	testing.expect_value(t, env.chunks.low, 7)
	testing.expect_value(t, env.chunks.high, B + 2)

	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)

	// Within the budget: nothing happens, and no flag is touched.
	testing.expect_value(t, kv.env_sweep(env), 0)
	read_chunks(&txn, 1, 2, 3, 4, 5, 6, 7)
	testing.expect_value(t, kv.env_stats(env).resident_chunks, B)
	testing.expect_value(t, kv.env_sweep(env), 0)
	testing.expect_value(t, len(chunks_with(env, kv.CHUNK_RESIDENT | kv.CHUNK_REFERENCED)), B)

	// Up to the hard watermark, which isn't passed, so no inline eviction;
	// the sweep evicts down to 7/8 B.
	read_chunks(&txn, 8, 9)
	s := kv.env_stats(env)
	testing.expect_value(t, s.resident_chunks, B + 2)
	testing.expect_value(t, s.inline_evictions, 0)
	testing.expect_value(t, kv.env_sweep(env), 3)
	s = kv.env_stats(env)
	testing.expect_value(t, s.resident_chunks, 7)
	testing.expect_value(t, s.evictions, 3)
	testing.expect_value(t, s.sweeps, 1)
	testing.expect_value(t, s.chunk_faults, 10)
	expect_chunks_consistent(t, env)
	expect_os_within_estimate(t, env)

	// A sweep that evicts nothing isn't counted.
	testing.expect_value(t, kv.env_sweep(env), 0)
	testing.expect_value(t, kv.env_stats(env).sweeps, 1)
}

// Without a budget only an explicit target evicts; target 0 empties the
// estimate (and, where the OS can say, the process), and the next reads
// fault back in and count again.
@(test)
test_sweep_to_zero :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL)
	if !ok {
		return
	}
	defer kv.env_close(env)

	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)
	held := make([][]byte, EVICT_KEYS, context.temp_allocator)
	for &v, i in held {
		v, _ = kv.get(&txn, evict_key(i))
	}
	before := kv.env_stats(env).resident_chunks
	testing.expect(t, before > 50, "too few chunks read")
	expect_os_within_estimate(t, env)

	testing.expect_value(t, kv.env_sweep(env), 0)
	testing.expect_value(t, kv.env_sweep(env, 3 * CHUNK_TEST_SIZE + 100), before - 3)
	testing.expect_value(t, kv.env_stats(env).resident_chunks, 3)
	testing.expect_value(t, kv.env_sweep(env, 0), 3)
	s := kv.env_stats(env)
	testing.expect_value(t, s.resident_chunks, 0)
	testing.expect_value(t, s.evictions, before)
	testing.expect_value(t, s.sweeps, 2)
	testing.expect_value(t, len(chunks_with(env, kv.CHUNK_RESIDENT)), 0)
	testing.expect_value(t, len(chunks_with(env, kv.CHUNK_REFERENCED)), 0)
	expect_os_empty(t, env)
	// A remap on macOS must leave the map's advice as it was.
	if random, advice_ok := advice_random(env.map_base, env.map_size); advice_ok {
		testing.expect(t, random, "the map lost MADV_RANDOM")
	}

	// The held slices read the same bytes, faulting them back in uncounted
	// (Q4). Sleeping again drops those pages too, though none is counted.
	expect_values(t, held)
	testing.expect_value(t, kv.env_stats(env).resident_chunks, 0)
	testing.expect_value(t, kv.env_sweep(env, 0), 0)
	expect_os_empty(t, env)
	expect_values(t, held)

	// A get counts again.
	v, _ := kv.get(&txn, evict_key(1234))
	testing.expect(t, bytes.equal(v, patterned(EVICT_VAL, 1234)), "wrong value after eviction")
	s = kv.env_stats(env)
	testing.expect(t, s.resident_chunks > 0, "the read after eviction wasn't counted")
	testing.expect_value(t, s.chunk_faults, before + s.resident_chunks)
	expect_chunks_consistent(t, env)
}

// CLOCK: a chunk read since the hand last passed it survives one pass.
@(test)
test_sweep_spares_referenced :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL)
	if !ok {
		return
	}
	defer kv.env_close(env)
	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)

	read_chunks(&txn, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
	// Every chunk is referenced: the first turn clears the flags, the
	// second evicts until 5 are left, none of them referenced.
	testing.expect_value(t, kv.env_sweep(env, 5 * CHUNK_TEST_SIZE), 6)
	testing.expect_value(t, len(chunks_with(env, kv.CHUNK_REFERENCED)), 0)

	// Read the survivor the hand reaches first: the next sweep must pass
	// it, and spare it.
	x := -1
	for k in 0 ..< env.chunks.end {
		c := (env.chunks.hand + k) % env.chunks.end
		if sync.atomic_load(&env.chunks.bits[c]) & kv.CHUNK_RESIDENT != 0 {
			x = c
			break
		}
	}
	if !testing.expect(t, x >= 0, "no survivor") {
		return
	}
	read_chunks(&txn, x)
	testing.expect_value(t, kv.env_sweep(env, CHUNK_TEST_SIZE), 4)
	expect_resident(t, env, {x})
}

// Slices held across evictions, by env_sweep and inline, keep their bytes;
// so does an overflow value larger than the budget, whose own marking
// evicts inline.
@(test)
test_evict_held_slices :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	BIG :: 400 * 1024
	big := patterned(BIG, 99)
	{
		env, ok := chunk_db_create(t, path, EVICT_KEYS, EVICT_VAL)
		if !ok {
			return
		}
		txn, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), big), kv.Error.None)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		kv.env_close(env)
	}
	B :: 4
	env, err := kv.env_open(path, kv.Options{chunk_size = CHUNK_TEST_SIZE, mapped_budget = B * CHUNK_TEST_SIZE})
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)
	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)

	// A full scan holding every value: far past the budget, so it evicts
	// inline again and again under the slices it holds.
	held := make([][]byte, EVICT_KEYS, context.temp_allocator)
	c := kv.cursor_open(&txn)
	for key, value, cerr := kv.cursor_first(&c); cerr == .None; key, value, cerr = kv.cursor_next(&c) {
		if string(key) == "big" {
			continue
		}
		i, _ := strconv.parse_int(string(key[3:]))
		held[i] = value
		testing.expect(t, kv.env_stats(env).resident_chunks <= B + 2, "over the hard watermark")
	}
	s := kv.env_stats(env)
	testing.expect(t, s.inline_evictions > 0, "no inline eviction")
	testing.expect_value(t, s.sweeps, 0)
	expect_values(t, held)

	// The large value: its run is more chunks than the budget.
	v, gerr := kv.get(&txn, transmute([]byte)string("big"))
	testing.expect_value(t, gerr, kv.Error.None)
	testing.expect(t, bytes.equal(v, big), "wrong large value")
	testing.expect(t, kv.env_stats(env).resident_chunks <= B + 2, "over the hard watermark")

	// Then everything, by env_sweep, and every slice again. Reading them
	// faults their pages back in uncounted (Q4), so the OS's view is not
	// compared here.
	kv.env_sweep(env, 0)
	testing.expect(t, bytes.equal(v, big), "large value changed across env_sweep")
	expect_values(t, held)
	expect_chunks_consistent(t, env)
}

// One transaction reading far past the budget, a full scan and random gets:
// inline eviction keeps it within B + 2 chunks while it runs, and its end
// brings the estimate within the budget.
@(test)
test_evict_long_txn_inline :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	B :: 6
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = B * CHUNK_TEST_SIZE})
	if !ok {
		return
	}
	defer kv.env_close(env)

	high := 0
	for round in 0 ..< 5 {
		txn, _ := kv.txn_begin(env)
		for _ in 0 ..< 200 {
			i := rand.int_max(EVICT_KEYS)
			v, _ := kv.get(&txn, evict_key(i))
			if !bytes.equal(v, patterned(EVICT_VAL, u32(i))) {
				testing.expectf(t, false, "round %d: wrong value for key %d", round, i)
			}
			high = max(high, kv.env_stats(env).resident_chunks)
		}
		c := kv.cursor_open(&txn)
		for _, _, err := kv.cursor_first(&c); err == .None; _, _, err = kv.cursor_next(&c) {
			high = max(high, kv.env_stats(env).resident_chunks)
		}
		kv.txn_abort(&txn)
		testing.expectf(t, kv.env_stats(env).resident_chunks <= B, "round %d: %d chunks resident after the transaction ended", round, kv.env_stats(env).resident_chunks)
	}
	s := kv.env_stats(env)
	testing.expectf(t, high <= B + 2, "resident estimate reached %d chunks, budget %d", high, B)
	testing.expect(t, s.inline_evictions > 0, "no inline eviction")
	testing.expect_value(t, s.sweeps, 0)
	expect_chunks_consistent(t, env)
	expect_os_within_estimate(t, env)
}

// Transactions that each read a few chunks: the end of each one, read-only
// or write, committed or aborted, brings the estimate back within the
// budget, and read-only ones reading less than the hard margin never evict
// inline. Without a budget, nothing is evicted at all.
@(test)
test_evict_at_txn_end :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	B :: 8
	for budget in ([]int{B * CHUNK_TEST_SIZE, 0}) {
		env: ^kv.Env
		ok: bool
		if budget != 0 {
			env, ok = chunk_db_create(t, path, EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = budget})
		} else {
			err: kv.Error
			env, err = kv.env_open(path, kv.Options{chunk_size = CHUNK_TEST_SIZE})
			ok = testing.expect_value(t, err, kv.Error.None)
		}
		if !ok {
			return
		}
		chunks := int(kv.env_snapshot(env).last_pgno) / CHUNK_PAGES
		// Read-only transactions reading two chunks each: never past the
		// hard watermark, from at most the budget.
		for n in 0 ..< 200 {
			txn, err := kv.txn_begin(env)
			if !testing.expect_value(t, err, kv.Error.None) {
				break
			}
			read_chunks(&txn, 1 + rand.int_max(chunks - 1), 1 + rand.int_max(chunks - 1))
			kv.txn_abort(&txn)
			if budget != 0 && kv.env_stats(env).resident_chunks > B {
				testing.expectf(t, false, "read transaction %d: %d chunks resident after it ended", n, kv.env_stats(env).resident_chunks)
				break
			}
		}
		if budget != 0 {
			testing.expect_value(t, kv.env_stats(env).inline_evictions, 0)
		}
		// Write transactions, committed and aborted: a put reads its path
		// too, so these may also evict inline.
		for n in 0 ..< 100 {
			txn, err := kv.txn_begin(env, read_only = false)
			if !testing.expect_value(t, err, kv.Error.None) {
				break
			}
			read_chunks(&txn, 1 + rand.int_max(chunks - 1), 1 + rand.int_max(chunks - 1))
			key := fmt.tprintf("n%04d", n)
			kv.put(&txn, transmute([]byte)key, patterned(100, u32(n)))
			if n % 2 == 0 {
				testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
			} else {
				kv.txn_abort(&txn)
			}
			if budget != 0 && kv.env_stats(env).resident_chunks > B {
				testing.expectf(t, false, "write transaction %d: %d chunks resident after it ended", n, kv.env_stats(env).resident_chunks)
				break
			}
		}
		s := kv.env_stats(env)
		if budget != 0 {
			testing.expect(t, s.txn_end_evictions > 0, "no eviction at a transaction's end")
		} else {
			testing.expect_value(t, s.evictions, 0)
			testing.expect(t, s.resident_chunks > B, "too few chunks read without a budget")
		}
		testing.expect_value(t, s.sweeps, 0)
		expect_chunks_consistent(t, env)
		expect_os_within_estimate(t, env)
		kv.env_close(env)
	}
}

/*
The budget as it is kept while a store is in use, with no env_sweep at all:
reader threads serving small requests and a writer committing, the
estimate brought back at the end of every transaction, and a thread past
the hard watermark waiting for an eviction under way. The readers have a
working set that fits the budget (nine requests in ten read a quarter of
the keys) and the rest of the database is three times the budget. Checked
by each thread after each of its transactions, allowing one chunk in
flight per thread (a mark whose check found eviction under way), and at the
end. Run with -sanitize:thread as well, and more than once.
*/
@(private = "file")
Budget_Worker :: struct {
	env:      ^kv.Env,
	requests: int,
	writer:   bool,
	stop:     ^bool,
	// Results, read after the thread is joined.
	high:     int,
	problem:  string,
}

@(private = "file")
budget_worker_run :: proc(w: ^Budget_Worker) {
	for req := 0; w.writer ? !sync.atomic_load(w.stop) : req < w.requests; req += 1 {
		txn, err := kv.txn_begin(w.env, read_only = !w.writer)
		if err != .None {
			w.problem = "txn_begin failed"
			return
		}
		if w.writer {
			for n in 0 ..< 4 {
				key := fmt.tprintf("w%05d", rand.int_max(2_000))
				if kv.put(&txn, transmute([]byte)key, patterned(500, u32(req + n))) != .None {
					w.problem = "put failed"
					kv.txn_abort(&txn)
					return
				}
			}
			if kv.txn_commit(&txn) != .None {
				w.problem = "commit failed"
				return
			}
		} else {
			for _ in 0 ..< 2 {
				i := rand.int_max(EVICT_KEYS / 4) if rand.int_max(10) != 0 else rand.int_max(EVICT_KEYS)
				v, _ := kv.get(&txn, evict_key(i))
				if !bytes.equal(v, patterned(EVICT_VAL, u32(i))) {
					w.problem = fmt.aprintf("key %d wrong", i)
					kv.txn_abort(&txn)
					return
				}
			}
			kv.txn_abort(&txn)
		}
		w.high = max(w.high, sync.atomic_load(&w.env.chunks.resident))
		free_all(context.temp_allocator)
	}
}

@(test)
test_evict_budget_no_sweep :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	B :: 24
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = B * CHUNK_TEST_SIZE, dirty_budget = MIN_DIRTY_BUDGET})
	if !ok {
		return
	}
	defer kv.env_close(env)

	READERS :: 4
	stop := false
	workers: [READERS + 1]Budget_Worker
	threads: [READERS + 1]^thread.Thread
	for i in 0 ..= READERS {
		workers[i] = {env = env, requests = 2_000, writer = i == READERS, stop = &stop}
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], budget_worker_run)
	}
	thread.join_multiple(..threads[:READERS])
	sync.atomic_store(&stop, true)
	thread.join(threads[READERS])
	high := 0
	for &w, i in workers {
		thread.destroy(threads[i])
		if w.problem != "" {
			testing.expectf(t, false, "thread %d: %s", i, w.problem)
			delete(w.problem)
		}
		high = max(high, w.high)
	}
	s := kv.env_stats(env)
	log.infof("highest estimate seen after a transaction: %d chunks (budget %d); %d chunks evicted, by %d transaction ends and %d inline evictions; %d faults", high, B, s.evictions, s.txn_end_evictions, s.inline_evictions, s.chunk_faults)
	testing.expectf(t, high <= B + 2 + READERS + 1, "estimate reached %d chunks, budget %d", high, B)
	testing.expectf(t, s.resident_chunks <= B + 2, "estimate %d chunks at the end, budget %d", s.resident_chunks, B)
	// The watermark is global, so inline eviction also fires here when
	// several short transactions together pass it; which path does more
	// depends on timing (logged above). test_evict_at_txn_end checks that
	// short transactions alone never evict inline.
	testing.expect(t, s.txn_end_evictions > 0, "no eviction at a transaction's end")
	testing.expect_value(t, s.sweeps, 0)
	expect_chunks_consistent(t, env)
	expect_latest_ok(t, env)
}

// Write transactions and commits across evictions: sweeps with a write
// transaction open (its reads of committed and spilled pages go through the
// map), inline evictions during its operations, and a small dirty pool so
// that it spills.
@(test)
test_evict_across_writes :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	B :: 4
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = B * CHUNK_TEST_SIZE, dirty_budget = MIN_DIRTY_BUDGET})
	if !ok {
		return
	}
	defer kv.env_close(env)

	// seed[i]: what key i's value was last written with.
	seed := make([]u32, EVICT_KEYS, context.temp_allocator)
	for &s, i in seed {
		s = u32(i)
	}
	check := proc(t: ^testing.T, txn: ^kv.Txn, seed: []u32, round: int) -> bool {
		for s, i in seed {
			v, err := kv.get(txn, evict_key(i))
			if err != .None || !bytes.equal(v, patterned(EVICT_VAL, s)) {
				return testing.expectf(t, false, "round %d: key %d: %v", round, i, err)
			}
		}
		return true
	}
	for round in 0 ..< 12 {
		txn, err := kv.txn_begin(env, read_only = false)
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		for n in 0 ..< 300 {
			i := rand.int_max(EVICT_KEYS)
			seed[i] = u32(round * 100_000 + n + EVICT_KEYS)
			if kv.put(&txn, evict_key(i), patterned(EVICT_VAL, seed[i])) != .None {
				testing.expectf(t, false, "round %d: put failed", round)
			}
			if n % 100 == 50 {
				kv.env_sweep(env, 0)
			}
		}
		check(t, &txn, seed, round)
		kv.env_sweep(env, 0)
		check(t, &txn, seed, round)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		kv.env_sweep(env, 0)
		reader, _ := kv.txn_begin(env)
		check(t, &reader, seed, round)
		kv.txn_abort(&reader)
		expect_latest_ok(t, env)
	}
	s := kv.env_stats(env)
	testing.expect(t, s.spills > 0, "nothing spilled")
	testing.expect(t, s.inline_evictions > 0, "no inline eviction")
	testing.expect(t, s.resident_chunks <= B + 2, "over the hard watermark")
	expect_chunks_consistent(t, env)
	// Operations read pages they took slices of before an inline eviction
	// in the same operation, so the OS may hold chunks the estimate
	// doesn't count (Q4); reported, not asserted.
	log_uncounted(env)
}

/*
Requests arriving while the store is put to sleep: reader threads, each
over a budget of a few chunks so that they cross the hard watermark all the
time and their inline evictions race each other and the reads, holding
values across a request and comparing them at its end; a writer committing
meanwhile; and a thread calling env_sweep(env, 0) again and again, as the
application's sleep path would, some of them with a write transaction open
on the writer's thread. Run with -sanitize:thread as well, and more than
once.
*/
@(private = "file")
Sweeper :: struct {
	env:      ^kv.Env,
	requests: int,
	stop:     ^bool,
	// Results, read after the thread is joined.
	evicted:  int,
	problem:  string,
}

@(private = "file")
sweep_reader_run :: proc(r: ^Sweeper) {
	held: [32][]byte
	idx: [32]int
	for _ in 0 ..< r.requests {
		txn, err := kv.txn_begin(r.env)
		if err != .None {
			r.problem = "txn_begin failed"
			return
		}
		for &h, j in held {
			idx[j] = rand.int_max(EVICT_KEYS)
			h, _ = kv.get(&txn, evict_key(idx[j]))
		}
		// Part of a scan, from a random key.
		c := kv.cursor_open(&txn)
		n := 0
		for _, _, cerr := kv.cursor_seek(&c, evict_key(rand.int_max(EVICT_KEYS))); cerr == .None && n < 100; _, _, cerr = kv.cursor_next(&c) {
			n += 1
		}
		for h, j in held {
			if !bytes.equal(h, patterned(EVICT_VAL, u32(idx[j]))) {
				r.problem = fmt.aprintf("key %d changed", idx[j])
				kv.txn_abort(&txn)
				return
			}
		}
		kv.txn_abort(&txn)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
sweep_writer_run :: proc(r: ^Sweeper) {
	for round := 0; !sync.atomic_load(r.stop); round += 1 {
		txn, err := kv.txn_begin(r.env, read_only = false)
		if err != .None {
			r.problem = "write txn_begin failed"
			return
		}
		// Keys of their own ("w…"), so the readers' values never change.
		for n in 0 ..< 50 {
			key := fmt.tprintf("w%05d", rand.int_max(2_000))
			if kv.put(&txn, transmute([]byte)key, patterned(500, u32(round + n))) != .None {
				r.problem = "put failed"
				kv.txn_abort(&txn)
				return
			}
		}
		if kv.txn_commit(&txn) != .None {
			r.problem = "commit failed"
			return
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
sweep_sleep_run :: proc(r: ^Sweeper) {
	for !sync.atomic_load(r.stop) {
		r.evicted += kv.env_sweep(r.env, 0)
		thread.yield()
	}
}

// Run with -sanitize:thread as well.
@(test)
test_sweep_concurrent :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	B :: 4
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = B * CHUNK_TEST_SIZE, dirty_budget = MIN_DIRTY_BUDGET})
	if !ok {
		return
	}
	defer kv.env_close(env)

	READERS :: 4
	stop := false
	sweepers: [READERS + 2]Sweeper
	threads: [READERS + 2]^thread.Thread
	for i in 0 ..< READERS {
		sweepers[i] = {env = env, requests = 300, stop = &stop}
		threads[i] = thread.create_and_start_with_poly_data(&sweepers[i], sweep_reader_run)
	}
	sweepers[READERS] = {env = env, stop = &stop}
	threads[READERS] = thread.create_and_start_with_poly_data(&sweepers[READERS], sweep_writer_run)
	sweepers[READERS + 1] = {env = env, stop = &stop}
	threads[READERS + 1] = thread.create_and_start_with_poly_data(&sweepers[READERS + 1], sweep_sleep_run)
	thread.join_multiple(..threads[:READERS])
	sync.atomic_store(&stop, true)
	thread.join_multiple(..threads[READERS:])
	for &s, i in sweepers {
		thread.destroy(threads[i])
		if s.problem != "" {
			testing.expectf(t, false, "thread %d: %s", i, s.problem)
			delete(s.problem)
		}
	}
	st := kv.env_stats(env)
	testing.expect(t, sweepers[READERS + 1].evicted > 0 && st.sweeps > 0, "no sweep evicted anything")
	testing.expect(t, st.inline_evictions > 0, "no inline eviction")
	log.infof("%d chunks evicted: %d by %d sweeps to 0, the rest by %d inline evictions; %d faults", st.evictions, sweepers[READERS + 1].evicted, st.sweeps, st.inline_evictions, st.chunk_faults)
	expect_chunks_consistent(t, env)
	// The readers read held values after evictions (Q4); the sleep path
	// drops those pages as well.
	log_uncounted(env)
	kv.env_sweep(env, 0)
	expect_os_empty(t, env)
	expect_latest_ok(t, env)
}

// While another thread holds evict_mutex, env_sweep and a transaction end
// return at once without evicting; a read past the hard watermark waits for
// the lock and then evicts down to the low watermark.
@(private = "file")
Lock_Holder :: struct {
	env:      ^kv.Env,
	locked:   sync.Sema,
	release:  sync.Sema,
	released: time.Tick,
}

@(private = "file")
lock_holder_run :: proc(h: ^Lock_Holder) {
	sync.mutex_lock(&h.env.chunks.evict_mutex)
	sync.sema_post(&h.locked)
	sync.sema_wait(&h.release)
	time.sleep(20 * time.Millisecond)
	h.released = time.tick_now()
	sync.mutex_unlock(&h.env.chunks.evict_mutex)
}

@(test)
test_sweep_try_lock :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	B :: 2
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{mapped_budget = B * CHUNK_TEST_SIZE})
	if !ok {
		return
	}
	defer kv.env_close(env)
	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)

	// Another thread holds the lock, as if it were evicting.
	holder := Lock_Holder{env = env}
	th := thread.create_and_start_with_poly_data(&holder, lock_holder_run)
	defer thread.destroy(th)
	sync.sema_wait(&holder.locked)

	// Up to the hard watermark, above the budget: env_sweep and the end of
	// a transaction don't wait and evict nothing.
	read_chunks(&txn, 1, 2, 3)
	testing.expect_value(t, kv.env_stats(env).resident_chunks, B + 2)
	testing.expect_value(t, kv.env_sweep(env, 0), 0)
	testing.expect_value(t, kv.env_sweep(env), 0)
	other, _ := kv.txn_begin(env)
	kv.txn_abort(&other)
	s := kv.env_stats(env)
	testing.expect_value(t, s.evictions, 0)
	testing.expect_value(t, s.resident_chunks, B + 2)

	// Past it, the read waits for the lock, then evicts.
	sync.sema_post(&holder.release)
	read_chunks(&txn, 4)
	done := time.tick_now()
	thread.join(th)
	testing.expect(t, time.tick_diff(holder.released, done) >= 0, "the read past the hard watermark didn't wait for the lock")
	s = kv.env_stats(env)
	testing.expect_value(t, s.resident_chunks, env.chunks.low)
	testing.expect_value(t, s.inline_evictions, 1)
	testing.expect_value(t, s.txn_end_evictions, 0)
	testing.expect_value(t, s.evictions, B + 3 - env.chunks.low)
	expect_chunks_consistent(t, env)
}

/*
The estimate is never under what the process holds, for reads accounted
after they fault (KV-I-0004 D9's order): reader threads read a page through
the map and only then call page_ptr on it, while a thread sweeps again and
again, to 0 (chunks_evict_all) and to one chunk (CLOCK) in turn. Whatever
the interleaving, a chunk present at the end was read after its last
eviction, and so marked after it. Checked against the OS on
Linux; elsewhere only the count's consistency is.
*/
@(private = "file")
Order_Reader :: struct {
	env:   ^kv.Env,
	id:    int,
	pages: int,
	stop:  ^bool,
	sum:   int,
}

@(private = "file")
order_reader_run :: proc(r: ^Order_Reader) {
	ps := r.env.page_size
	for !sync.atomic_load(r.stop) {
		txn, err := kv.txn_begin(r.env)
		if err != .None {
			return
		}
		for _ in 0 ..< 8 {
			pgno := 2 + rand.int_max(r.pages - 2)
			r.sum += int((^u8)(&r.env.map_base[pgno * ps + 100])^)
			kv.page_ptr(&txn, kv.Pgno(pgno))
		}
		kv.txn_abort(&txn)
	}
}

@(test)
test_sweep_estimate_not_under :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL)
	if !ok {
		return
	}
	defer kv.env_close(env)

	// Checked after each of several rounds, since only the state at the end
	// of a round can be compared with the OS. A lost mark shows only if
	// its chunk isn't read again before the round ends, so the readers
	// spread over the whole database.
	READERS :: 4
	ROUNDS :: 10
	pages := int(kv.env_snapshot(env).last_pgno) + 1
	sweeps := 0
	for round in 0 ..< ROUNDS {
		stop := false
		readers: [READERS]Order_Reader
		threads: [READERS]^thread.Thread
		for i in 0 ..< READERS {
			readers[i] = {env = env, id = i, pages = pages, stop = &stop}
			threads[i] = thread.create_and_start_with_poly_data(&readers[i], order_reader_run)
		}
		start := time.tick_now()
		for time.tick_since(start) < 50 * time.Millisecond {
			// The sleep path and CLOCK in turn.
			kv.env_sweep(env, 0 if sweeps % 2 == 0 else CHUNK_TEST_SIZE)
			sweeps += 1
		}
		sync.atomic_store(&stop, true)
		thread.join_multiple(..threads[:])
		for th in threads {
			thread.destroy(th)
		}
		if !expect_chunks_consistent(t, env) || !expect_os_within_estimate(t, env) {
			log.errorf("round %d", round)
			break
		}
	}
	log.infof("%d sweeps, %d evictions", sweeps, kv.env_stats(env).evictions)
}

/*
What env_sweep costs (reported, not asserted; KV-T-0024 measures it
properly): with nothing to do, and evicting. Only with -define:KV_BENCH=true:

	odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_sweep
*/
when #config(KV_BENCH, false) {
	@(test)
	test_bench_sweep :: proc(t: ^testing.T) {
		dir := temp_dir_create(t)
		defer temp_dir_destroy(&dir, DB)

		env, ok := chunk_db_create(t, temp_dir_file(dir, DB), EVICT_KEYS, EVICT_VAL, kv.Options{chunk_size = kv.DEFAULT_CHUNK_SIZE, mapped_budget = 64 * kv.DEFAULT_CHUNK_SIZE})
		if !ok {
			return
		}
		defer kv.env_close(env)
		txn, _ := kv.txn_begin(env)
		defer kv.txn_abort(&txn)

		N :: 1_000_000
		start := time.tick_now()
		for _ in 0 ..< N {
			kv.env_sweep(env)
		}
		log.infof("env_sweep with nothing to do: %.2f ns", f64(time.duration_nanoseconds(time.tick_since(start))) / N)

		// Fault every chunk in (touching every page), then evict them:
		// all at once (the sleep path), or half of them by CLOCK.
		chunks := (int(env.file_size) + env.chunks.size - 1) / env.chunks.size
		ROUNDS :: 200
		sum := 0
		for half in ([]bool{false, true}) {
			evicted := 0
			elapsed: time.Duration
			for _ in 0 ..< ROUNDS {
				for pgno in 2 ..= int(txn.snapshot.last_pgno) {
					sum += int(kv.page_ptr(&txn, kv.Pgno(pgno))[100])
				}
				start = time.tick_now()
				evicted += kv.env_sweep(env, env.chunks.size * kv.env_stats(env).resident_chunks / 2 if half else 0)
				elapsed += time.tick_since(start)
			}
			log.infof("env_sweep(env, %s) over %d chunks of 256 KiB: %.2f µs per call, %.2f µs per chunk evicted", "half" if half else "0", chunks, time.duration_microseconds(elapsed) / ROUNDS, time.duration_microseconds(elapsed) / f64(evicted))
		}
		log.infof("(checksum %d)", sum)
	}
}
