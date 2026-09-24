package kv_tests

import "core:bytes"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"

import kv "../kv"

/*
Chunk accounting (KV-I-0004 D7, KV-T-0022): the resident estimate kept on
every read of a mapped page. Most tests use the smallest chunk, 64 KiB, so
that 16 pages of 4 KiB make a chunk and a small database spans many.
*/

CHUNK_TEST_SIZE :: kv.MIN_CHUNK_SIZE
CHUNK_PAGES :: CHUNK_TEST_SIZE / kv.DEFAULT_PAGE_SIZE

// The chunks of `env` whose flags are exactly `flags`, in order (temp
// allocator).
chunks_with :: proc(env: ^kv.Env, flags: u8) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< env.chunks.count {
		if sync.atomic_load(&env.chunks.bits[i]) & flags == flags {
			append(&out, i)
		}
	}
	return out[:]
}

// Checks that the resident count is the number of chunks flagged resident,
// that every resident chunk is inside the file, and that chunk_faults less
// evictions is the count, in env_stats as well.
expect_chunks_consistent :: proc(t: ^testing.T, env: ^kv.Env, loc := #caller_location) -> bool {
	resident := chunks_with(env, kv.CHUNK_RESIDENT)
	s := kv.env_stats(env)
	ok := testing.expect_value(t, s.resident_chunks, len(resident), loc = loc)
	ok &= testing.expect_value(t, s.chunk_faults - s.evictions, s.resident_chunks, loc = loc)
	ok &= testing.expect_value(t, s.chunk_size, env.chunks.size, loc = loc)
	for i in resident {
		ok &= testing.expectf(t, i64(i) * i64(env.chunks.size) < env.file_size, "chunk %d past the end of the file is resident", i, loc = loc)
	}
	return ok
}

// Checks that the chunks with CHUNK_RESIDENT set are exactly `want`.
expect_resident :: proc(t: ^testing.T, env: ^kv.Env, want: []int, loc := #caller_location) -> bool {
	got := chunks_with(env, kv.CHUNK_RESIDENT)
	return testing.expectf(t, fmt.tprint(got) == fmt.tprint(want), "resident chunks %v, expected %v", got, want, loc = loc) && expect_chunks_consistent(t, env, loc)
}

// Creates a database of `n` keys with values of `val_len` bytes in one
// commit, and reopens it with 64 KiB chunks, so that the only chunks
// resident are those env_open read.
chunk_db_create :: proc(t: ^testing.T, path: string, n: int, val_len: int, options := kv.Options{}) -> (env: ^kv.Env, ok: bool) {
	txn: kv.Txn
	env, txn = open_write(t, path) or_return
	for i in 0 ..< n {
		key := fmt.tprintf("key%06d", i)
		if !testing.expect_value(t, kv.put(&txn, transmute([]byte)key, patterned(val_len, u32(i))), kv.Error.None) {
			kv.txn_abort(&txn)
			kv.env_close(env)
			return nil, false
		}
	}
	commit_err := kv.txn_commit(&txn)
	kv.env_close(env)
	if !testing.expect_value(t, commit_err, kv.Error.None) {
		return nil, false
	}
	opts := options
	if opts.chunk_size == 0 {
		opts.chunk_size = CHUNK_TEST_SIZE
	}
	err: kv.Error
	env, err = kv.env_open(path, opts)
	return env, testing.expect_value(t, err, kv.Error.None)
}

@(test)
test_chunk_options :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB, "big.db")
	path := temp_dir_file(dir, DB)

	// Defaults: 256 KiB chunks, no budget, the map in whole chunks, one
	// byte per chunk, and only chunk 0 (the meta pages) resident.
	{
		env, err := kv.env_open(path, kv.Options{map_size = 300 * 1024})
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		s := kv.env_stats(env)
		testing.expect_value(t, s.chunk_size, kv.DEFAULT_CHUNK_SIZE)
		testing.expect_value(t, s.mapped_budget, 0)
		testing.expect_value(t, env.map_size, 2 * kv.DEFAULT_CHUNK_SIZE)
		testing.expect_value(t, env.chunks.count, 2)
		testing.expect_value(t, int(1) << env.chunks.shift, kv.DEFAULT_CHUNK_SIZE)
		expect_resident(t, env, {0})
		kv.env_close(env)
	}
	// The default map is 4 KiB of table at the default chunk size.
	{
		env, err := kv.env_open(path)
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		testing.expect_value(t, env.chunks.count, 4096)
		kv.env_close(env)
	}
	// Valid sizes, and the budget reported as given.
	for size in ([]int{kv.MIN_CHUNK_SIZE, 128 * 1024, 1 << 20}) {
		env, err := kv.env_open(path, kv.Options{map_size = 100 * 1024, chunk_size = size, mapped_budget = 20 << 20})
		if !testing.expect_value(t, err, kv.Error.None) {
			continue
		}
		s := kv.env_stats(env)
		testing.expect_value(t, s.chunk_size, size)
		testing.expect_value(t, s.mapped_budget, 20 << 20)
		testing.expect_value(t, env.map_size, max(size, 128 * 1024))
		testing.expect_value(t, env.map_size % size, 0)
		testing.expect_value(t, int(uintptr(env.map_base)) % size, 0)
		expect_resident(t, env, {0})
		kv.env_close(env)
	}
	// Too small, not a power of two, negative; a negative budget.
	bad := []kv.Options {
		{chunk_size = 32 * 1024},
		{chunk_size = kv.DEFAULT_PAGE_SIZE},
		{chunk_size = 96 * 1024},
		{chunk_size = 3 * kv.DEFAULT_CHUNK_SIZE},
		{chunk_size = -kv.DEFAULT_CHUNK_SIZE},
		{mapped_budget = -1},
	}
	for options in bad {
		env, err := kv.env_open(path, options)
		testing.expectf(t, err == .Invalid_Argument, "%v: got %v", options, err)
		if err == .None {
			kv.env_close(env)
		}
	}
	// A database with 32 KiB pages still fits whole pages in the smallest
	// chunk.
	{
		big := temp_dir_file(dir, "big.db")
		env, err := kv.env_open(big, kv.Options{page_size = kv.MAX_PAGE_SIZE, chunk_size = kv.MIN_CHUNK_SIZE})
		if testing.expect_value(t, err, kv.Error.None) {
			testing.expect_value(t, kv.MIN_CHUNK_SIZE % env.page_size, 0)
			expect_resident(t, env, {0})
			kv.env_close(env)
		}
	}
}

@(test)
test_chunk_reads_cross_boundary :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// About 1,000 pages: every chunk from 0 to ~60 holds tree pages.
	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), 3_000, 1_000)
	if !ok {
		return
	}
	defer kv.env_close(env)
	snap := kv.env_snapshot(env)
	testing.expect(t, int(snap.last_pgno) > 4 * CHUNK_PAGES, "database too small")
	expect_resident(t, env, {0})

	txn, _ := kv.txn_begin(env)
	// The last page of chunk 1 and the first of chunk 2: one chunk each,
	// both flags set.
	kv.page_ptr(&txn, CHUNK_PAGES * 2 - 1)
	expect_resident(t, env, {0, 1})
	kv.page_ptr(&txn, CHUNK_PAGES * 2)
	expect_resident(t, env, {0, 1, 2})
	testing.expect_value(t, len(chunks_with(env, kv.CHUNK_RESIDENT | kv.CHUNK_REFERENCED)), 3)
	// Every page of both chunks again: nothing more.
	for pgno in CHUNK_PAGES ..< 3 * CHUNK_PAGES {
		kv.page_ptr(&txn, kv.Pgno(pgno))
	}
	expect_resident(t, env, {0, 1, 2})

	// A chunk whose referenced flag was cleared (as a sweep does) gets it
	// back on the next read, and isn't counted again.
	sync.atomic_and(&env.chunks.bits[1], ~kv.CHUNK_REFERENCED)
	kv.page_ptr(&txn, CHUNK_PAGES + 3)
	testing.expect_value(t, sync.atomic_load(&env.chunks.bits[1]), kv.CHUNK_RESIDENT | kv.CHUNK_REFERENCED)
	expect_resident(t, env, {0, 1, 2})

	// A full scan through a cursor marks every chunk holding a tree page,
	// which is every chunk up to the last page here, and each once.
	c := kv.cursor_open(&txn)
	n := 0
	for _, _, err := kv.cursor_first(&c); err == .None; _, _, err = kv.cursor_next(&c) {
		n += 1
	}
	testing.expect_value(t, n, 3_000)
	last_chunk := int(snap.last_pgno) / CHUNK_PAGES
	want := make([]int, last_chunk + 1, context.temp_allocator)
	for &w, i in want {
		w = i
	}
	expect_resident(t, env, want)
	kv.txn_abort(&txn)
}

@(test)
test_chunk_dirty_reads_not_counted :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), 100, 1_000)
	if !ok {
		return
	}
	defer kv.env_close(env)

	txn, err := kv.txn_begin(env, read_only = false)
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.txn_abort(&txn)
	// Allocate past the file's chunks read so far until a page lies in a
	// chunk nothing has read: reading it (from the pool) marks nothing.
	pgno: kv.Pgno
	for {
		pgno, _, err = kv.page_alloc(&txn, 1)
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		if int(pgno) / CHUNK_PAGES > 0 && sync.atomic_load(&env.chunks.bits[int(pgno) / CHUNK_PAGES]) == 0 {
			break
		}
	}
	before := kv.env_stats(env).resident_chunks
	page := kv.page_ptr(&txn, pgno)
	testing.expect(t, uintptr(raw_data(page)) < uintptr(env.map_base) || uintptr(raw_data(page)) >= uintptr(env.map_base) + uintptr(env.map_size), "a dirty page read from the map")
	testing.expect_value(t, sync.atomic_load(&env.chunks.bits[int(pgno) / CHUNK_PAGES]), 0)
	testing.expect_value(t, kv.env_stats(env).resident_chunks, before)
	expect_chunks_consistent(t, env)
}

@(test)
test_chunk_overflow_value_marks_run :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	// A 300 KiB value (at least five chunks) behind some small ones.
	SIZE :: 300 * 1024
	value := patterned(SIZE, 7)
	{
		env, txn, ok := open_write(t, path)
		if !ok {
			return
		}
		for i in 0 ..< 50 {
			key := fmt.tprintf("a%03d", i)
			kv.put(&txn, transmute([]byte)key, patterned(500, u32(i)))
		}
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), value), kv.Error.None)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		kv.env_close(env)
	}
	env, err := kv.env_open(path, kv.Options{chunk_size = CHUNK_TEST_SIZE})
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)
	expect_resident(t, env, {0})

	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)
	got, get_err := kv.get(&txn, transmute([]byte)string("big"))
	testing.expect_value(t, get_err, kv.Error.None)
	testing.expect(t, bytes.equal(got, value), "wrong value")

	// The run: from its header page to the value's last byte.
	start := int(uintptr(raw_data(got)) - uintptr(env.map_base)) - kv.PAGE_HEADER_SIZE
	pages := kv.overflow_pages(env.page_size, SIZE)
	first, last := start / CHUNK_TEST_SIZE, (start + pages * env.page_size - 1) / CHUNK_TEST_SIZE
	testing.expect(t, last - first >= 4, "the run spans fewer than five chunks")
	resident := chunks_with(env, kv.CHUNK_RESIDENT | kv.CHUNK_REFERENCED)
	for i in first ..= last {
		testing.expectf(t, sync.atomic_load(&env.chunks.bits[i]) == kv.CHUNK_RESIDENT | kv.CHUNK_REFERENCED, "chunk %d of the run not marked", i)
	}
	expect_chunks_consistent(t, env)
	// Reading it again adds nothing.
	count := kv.env_stats(env).resident_chunks
	kv.get(&txn, transmute([]byte)string("big"))
	testing.expect_value(t, kv.env_stats(env).resident_chunks, count)
	testing.expect_value(t, len(chunks_with(env, kv.CHUNK_RESIDENT)), len(resident))
}

@(test)
test_chunk_freelist_load_marks_run :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	// Overwrite every key of a ~1,000-page database with a reader holding
	// the first snapshot, so the second commit frees about as many pages
	// and its free-list run lies past them.
	{
		env, ok := chunk_db_create(t, path, 3_000, 1_000)
		if !ok {
			return
		}
		reader, _ := kv.txn_begin(env)
		txn, _ := kv.txn_begin(env, read_only = false)
		for i in 0 ..< 3_000 {
			key := fmt.tprintf("key%06d", i)
			kv.put(&txn, transmute([]byte)key, patterned(1_000, u32(i) + 1))
		}
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		kv.txn_abort(&reader)
		kv.env_close(env)
	}
	env, err := kv.env_open(path, kv.Options{chunk_size = CHUNK_TEST_SIZE})
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)
	snap := kv.env_snapshot(env)
	if !testing.expect(t, snap.freelist_pgno != 0, "no free-list run") {
		return
	}
	run_pages := freelist_run_len(t, env, snap)
	first := int(snap.freelist_pgno) / CHUNK_PAGES
	last := (int(snap.freelist_pgno) + run_pages - 1) / CHUNK_PAGES
	testing.expect(t, first > 0, "the run is in chunk 0")
	// Only chunk 0 (the meta pages) and the run's chunks were read.
	want := make([dynamic]int, context.temp_allocator)
	append(&want, 0)
	for i in first ..= last {
		append(&want, i)
	}
	expect_resident(t, env, want[:])
	testing.expectf(t, kv.env_stats(env).free_list_bytes >= int(snap.freelist_count) * size_of(kv.Pgno), "free_list_bytes %d for %d records", kv.env_stats(env).free_list_bytes, snap.freelist_count)
}

// Reader threads that read the same chunks at the same moment: each chunk
// must be counted once whoever wins. The table is reset between rounds
// (no reader is inside it then), so every round races again.
Chunk_Race :: struct {
	env:     ^kv.Env,
	barrier: ^sync.Barrier,
	rounds:  int,
	chunks:  int,
	id:      int,
}

chunk_race_run :: proc(r: ^Chunk_Race) {
	for _ in 0 ..< r.rounds {
		sync.barrier_wait(r.barrier)
		txn, err := kv.txn_begin(r.env)
		if err == .None {
			// Half the threads walk the chunks upwards, half downwards,
			// so every chunk sees both an early and a late crowd.
			for j in 1 ..< r.chunks {
				c := j if r.id % 2 == 0 else r.chunks - j
				kv.page_ptr(&txn, kv.Pgno(c * CHUNK_PAGES + r.id % CHUNK_PAGES))
			}
			kv.txn_abort(&txn)
		}
		sync.barrier_wait(r.barrier)
		// The main thread checks and resets the table here.
		sync.barrier_wait(r.barrier)
	}
}

// Run with -sanitize:thread as well.
@(test)
test_chunk_concurrent_readers :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, ok := chunk_db_create(t, temp_dir_file(dir, DB), 3_000, 1_000)
	if !ok {
		return
	}
	defer kv.env_close(env)

	THREADS :: 8
	ROUNDS :: 200
	chunks := int(kv.env_snapshot(env).last_pgno) / CHUNK_PAGES // whole chunks of tree pages
	barrier: sync.Barrier
	sync.barrier_init(&barrier, THREADS + 1)
	races: [THREADS]Chunk_Race
	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		races[i] = {env = env, barrier = &barrier, rounds = ROUNDS, chunks = chunks, id = i}
		threads[i] = thread.create_and_start_with_poly_data(&races[i], chunk_race_run)
	}
	bad_rounds := 0
	for round in 0 ..< ROUNDS {
		sync.barrier_wait(&barrier)
		sync.barrier_wait(&barrier)
		// Chunk 0 and chunks 1 ..< chunks, each once.
		s := kv.env_stats(env)
		if s.resident_chunks != chunks || len(chunks_with(env, kv.CHUNK_RESIDENT | kv.CHUNK_REFERENCED)) != chunks {
			if bad_rounds == 0 {
				testing.expectf(t, false, "round %d: %d chunks counted, %d flagged, %d read", round, s.resident_chunks, len(chunks_with(env, kv.CHUNK_RESIDENT)), chunks)
			}
			bad_rounds += 1
		}
		testing.expect_value(t, s.chunk_faults, s.resident_chunks)
		// Forget every chunk but 0, as if evicted, and race again.
		for i in 1 ..< env.chunks.count {
			sync.atomic_store(&env.chunks.bits[i], 0)
		}
		sync.atomic_store(&env.chunks.resident, 1)
		sync.atomic_store(&env.chunks.faults, 1)
		sync.barrier_wait(&barrier)
	}
	thread.join_multiple(..threads[:])
	for th in threads {
		thread.destroy(th)
	}
	testing.expectf(t, bad_rounds == 0, "%d of %d rounds miscounted", bad_rounds, ROUNDS)
}
