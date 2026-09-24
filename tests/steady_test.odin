package kv_tests

import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"

import kv "../kv"

// Keys in the steady-state workload. Every commit overwrites 1–20 of them.
STEADY_KEYS :: 1_000

// Commits in the plateau and full-map tests. Each is synced, and on macOS
// the two tests take about three minutes together at 10⁴, which is what
// KV-T-0013 asks for; pass -define:KV_STEADY_COMMITS=1000 while iterating.
STEADY_COMMITS :: #config(KV_STEADY_COMMITS, 10_000)
#assert(STEADY_COMMITS >= 1_000 && STEADY_COMMITS % 100 == 0)

// The dirty-page budget the steady-state tests open with; 0 is the default
// (4 MiB). Pass -define:KV_STEADY_DIRTY_BUDGET=200704 (MIN_DIRTY_BUDGET, 49
// pages) to run them with the smallest pool, where the initial load and
// many commits spill (KV-I-0004 NFR-004).
STEADY_DIRTY_BUDGET :: #config(KV_STEADY_DIRTY_BUDGET, 0)

/*
The plateau, full-map, long-reader and churn tests make thousands of synced
commits, several minutes per build configuration, so they are not part of
the ordinary suite. Run them with -define:KV_STEADY=true, or with
`scripts/test.sh --steady`, after changing allocation, the free list or
commit.

Only the registration is guarded, as for the benchmark: the procedures are
compiled and type-checked by every run.
*/
when #config(KV_STEADY, false) {
	@(test)
	test_steady_state_plateau :: proc(t: ^testing.T) {
		steady_state_plateau(t)
	}

	@(test)
	test_steady_state_full_map :: proc(t: ^testing.T) {
		steady_state_full_map(t)
	}

	@(test)
	test_steady_state_long_reader :: proc(t: ^testing.T) {
		steady_state_long_reader(t)
	}

	@(test)
	test_steady_state_churn :: proc(t: ^testing.T) {
		steady_state_churn(t)
	}
}

// Most keys one steady-state commit overwrites, and the most pages one of
// its values takes in an overflow run.
STEADY_COMMIT_KEYS :: 20
STEADY_MAX_RUN :: 4

/*
The value of key `i` after round `round` of the steady-state workload
(temp allocator). 15% of values are in an overflow run of 1–4 pages, the
rest are inline, up to 100 bytes. The size is derived from both, so it
changes on almost every overwrite; with `fixed_size` it is derived from the
key alone, so the data's size never changes. The bytes always depend on
the round.
*/
steady_value :: proc(i, round: int, page_size: int, fixed_size := false) -> []byte {
	h := u64(i) * 0x9E37_79B9_7F4A_7C15 ~ (0 if fixed_size else u64(round) * 0xBF58_476D_1CE4_E5B9)
	h ~= h >> 29
	h *= 0x94D0_49BB_1331_11EB
	h ~= h >> 32
	size := int(h >> 8 % 101)
	if h % 100 < 15 {
		// Past the threshold for an 8-byte key, and less than 3 pages.
		low := kv.overflow_threshold(page_size)
		size = low + int(h >> 8 % u64(3 * page_size - low))
	}
	return patterned(size, u32(h) + u32(round))
}

/*
One steady-state commit: overwrites `count` random keys (every key when
`count` is STEADY_KEYS, as the initial load) with round `round`'s values,
and once it has committed records the round in `model`. Afterwards
space_check and tree_check run on the new snapshot. With `written`, the pages the commit wrote are added
to it; with `put_growth`, the pages its puts added at the end of the file
(as opposed to the commit's free-list run). Returns the first error from
put or commit, without failing the test, so that callers can expect
Map_Full.
*/
steady_commit :: proc(t: ^testing.T, env: ^kv.Env, model: []int, round, count: int, written: ^[dynamic]kv.Pgno = nil, put_growth: ^int = nil, fixed_size := false, loc := #caller_location) -> kv.Error {
	txn, err := kv.txn_begin(env, read_only = false)
	if err != .None {
		testing.expectf(t, false, "round %d: txn_begin: %v", round, err, loc = loc)
		return err
	}
	defer kv.txn_abort(&txn)
	begin_last := txn.snapshot.last_pgno
	keys := make([]int, count, context.temp_allocator)
	for &i, j in keys {
		i = j if count == STEADY_KEYS else rand.int_max(STEADY_KEYS)
		key: [8]byte
		if err = kv.put(&txn, u64_key(&key, u64(i)), steady_value(i, round, env.page_size, fixed_size)); err != .None {
			return err
		}
	}
	if written != nil {
		append(written, ..written_pgnos(&txn))
	}
	if put_growth != nil {
		put_growth^ += int(txn.snapshot.last_pgno - begin_last)
	}
	if err = kv.txn_commit(&txn); err != .None {
		return err
	}
	for i in keys {
		model[i] = round
	}
	if !expect_latest_ok(t, env, loc = loc) {
		return .Corrupted
	}
	return .None
}

// Checks that `txn` holds every key with the value of the round `model`
// records for it.
steady_expect :: proc(t: ^testing.T, txn: ^kv.Txn, model: []int, fixed_size := false, loc := #caller_location) -> bool {
	testing.expect_value(t, txn.snapshot.entries, STEADY_KEYS, loc = loc)
	for round, i in model {
		key: [8]byte
		got, err := kv.get(txn, u64_key(&key, u64(i)))
		if err != .None || !slice.equal(got, steady_value(i, round, txn.env.page_size, fixed_size)) {
			testing.expectf(t, false, "key %d: %v, or not the value of round %d", i, err, round, loc = loc)
			return false
		}
	}
	return true
}

// space_check and tree_check on the latest snapshot, with a new reader.
expect_latest_ok :: proc(t: ^testing.T, env: ^kv.Env, loc := #caller_location) -> bool {
	reader, err := kv.txn_begin(env)
	testing.expect_value(t, err, kv.Error.None, loc = loc)
	if err != .None {
		return false
	}
	defer kv.txn_abort(&reader)
	return expect_tree_ok(t, &reader, loc) && expect_space_ok(t, &reader, loc)
}

// env_stats reports the committed snapshot, the free list's two parts, the
// file size and the live readers, including from a thread that has a write
// transaction open.
@(test)
test_env_stats :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, kv.env_stats(env), kv.Stats{last_pgno = 1, file_pages = 2, dirty_budget = kv.DEFAULT_DIRTY_BUDGET, chunk_size = kv.DEFAULT_CHUNK_SIZE, resident_chunks = 1, chunk_faults = 1})

	// Figures that must match the env's own state, with no transaction open
	// or from the thread that has the write transaction.
	expect_matches :: proc(t: ^testing.T, env: ^kv.Env, readers: int, oldest: kv.Txn_Id, loc := #caller_location) -> kv.Stats {
		s := kv.env_stats(env)
		size, _ := kv.os_file_size(env.fd)
		testing.expect_value(t, s.last_pgno, kv.env_snapshot(env).last_pgno, loc = loc)
		testing.expect_value(t, s.file_pages, int(size) / env.page_size, loc = loc)
		testing.expect_value(t, s.free_ready, len(env.free.ready), loc = loc)
		testing.expect_value(t, s.free_pending, len(env.free.pending), loc = loc)
		testing.expect_value(t, s.free_list_bytes, cap(env.free.ready) * size_of(kv.Pgno) + cap(env.free.pending) * size_of(kv.Free_Record), loc = loc)
		testing.expect_value(t, s.readers, readers, loc = loc)
		testing.expect_value(t, s.oldest_reader, oldest, loc = loc)
		return s
	}

	model := make([]int, STEADY_KEYS, context.temp_allocator)
	testing.expect_value(t, steady_commit(t, env, model, 0, STEADY_KEYS), kv.Error.None)
	s := expect_matches(t, env, 0, 0)
	testing.expect(t, s.last_pgno > 2 && s.file_pages > int(s.last_pgno), "no pages or no growth step")
	testing.expect(t, s.free_ready == 0 && s.free_pending == 0, "the first commit freed pages")

	// Three readers on two snapshots.
	r1, _ := kv.txn_begin(env)
	r2, _ := kv.txn_begin(env)
	testing.expect_value(t, steady_commit(t, env, model, 1, 20), kv.Error.None)
	r3, _ := kv.txn_begin(env)
	expect_matches(t, env, 3, r1.snapshot.txn_id)
	for round in 2 ..< 5 {
		testing.expect_value(t, steady_commit(t, env, model, round, 20), kv.Error.None)
	}
	// The readers pin everything freed since, so nothing is reusable.
	s = expect_matches(t, env, 3, r1.snapshot.txn_id)
	testing.expect(t, s.free_ready == 0 && s.free_pending > 0, "freed pages not pending")
	kv.txn_abort(&r1)
	kv.txn_abort(&r2)
	expect_matches(t, env, 1, r3.snapshot.txn_id)
	kv.txn_abort(&r3)
	s = expect_matches(t, env, 0, 0)
	testing.expect(t, s.free_ready == 0, "pages released before a write transaction began")

	// A write transaction's release shows at once; what it takes and frees
	// only shows once it commits. env_stats doesn't wait for the writer.
	txn, _ := kv.txn_begin(env, read_only = false)
	s = expect_matches(t, env, 0, 0)
	testing.expect(t, s.free_ready > 0, "the release at begin is not reported")
	for i in 0 ..< 100 {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(i)), steady_value(i, 5, env.page_size))
		model[i] = 5
	}
	testing.expect(t, txn.write.ready_taken > 0 && len(txn.write.freed) > 0, "the transaction took or freed nothing")
	// Except the dirty pool's figures, which are live.
	live := kv.env_stats(env)
	testing.expect(t, live.dirty_pages > 0 && live.dirty_committed >= live.dirty_pages * env.page_size, "dirty pages not reported live")
	live.dirty_pages, live.dirty_committed = s.dirty_pages, s.dirty_committed
	testing.expect_value(t, live, s)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	s = expect_matches(t, env, 0, 0)
	testing.expect(t, s.dirty_pages == 0 && s.dirty_committed == 0, "dirty pages reported after the commit")

	// A reader in this thread counts while it is open.
	reader, _ := kv.txn_begin(env)
	expect_matches(t, env, 1, reader.snapshot.txn_id)
	kv.txn_abort(&reader)

	// After a reopen the figures come from the loaded free list.
	before := kv.env_stats(env)
	kv.env_close(env)
	env, err = kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	s = expect_matches(t, env, 0, 0)
	testing.expect_value(t, s.last_pgno, before.last_pgno)
	testing.expect_value(t, s.free_ready + s.free_pending, before.free_ready + before.free_pending)
}

/*
NFR-004: with no readers, overwriting a fixed key set keeps the file from
growing. 1,000 keys with values that change size (inline and in overflow
runs) are overwritten over 10⁴ commits (STEADY_COMMITS) of 1–20 random keys
each, and last_pgno is sampled every 100 commits.

The file follows the high-water mark of the data plus the pages that D1
keeps in flight (what the last commit freed and what this one allocates),
and with random commits and value sizes a new high is still set now and
then, ever more rarely. So "the last 50 samples are equal" holds for only
about half the seeds (KV-T-0013). What must hold, and what a leak or broken
reuse would fail, is that the second half of the commits adds at most 1% of
the pages it writes (without reuse, every page written is added), and that the
file stays within twice the size the data first loaded at.
*/
steady_state_plateau :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = STEADY_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	COMMITS :: STEADY_COMMITS
	SAMPLE :: 100
	model := make([]int, STEADY_KEYS, context.temp_allocator)
	if steady_commit(t, env, model, 0, STEADY_KEYS) != .None {
		return
	}
	loaded := kv.env_stats(env).last_pgno
	samples: [COMMITS / SAMPLE]kv.Pgno
	last_growth, last := 0, loaded
	written := make([dynamic]kv.Pgno, context.temp_allocator)
	written_late := 0
	for round in 1 ..= COMMITS {
		clear(&written)
		if commit_err := steady_commit(t, env, model, round, 1 + rand.int_max(STEADY_COMMIT_KEYS), &written); commit_err != .None {
			testing.expectf(t, false, "[seed %d] round %d: %v", t.seed, round, commit_err)
			return
		}
		if round > COMMITS / 2 {
			written_late += len(written)
		}
		if s := kv.env_stats(env); s.last_pgno != last {
			last_growth, last = round, s.last_pgno
		}
		if round % SAMPLE == 0 {
			samples[round / SAMPLE - 1] = last
		}
	}
	half := samples[len(samples) / 2 - 1]
	late_growth := int(last - half)
	log.infof("[seed %d] loaded at last_pgno %d; %d after 500 commits, %d after %d, %d after %d; last growth at commit %d; the second half wrote %d pages and added %d; %v",
		t.seed, loaded, samples[4], half, COMMITS / 2, last, COMMITS, last_growth, written_late, late_growth, kv.env_stats(env))
	testing.expectf(t, late_growth * 100 <= written_late, "[seed %d] the second half of the commits added %d pages, more than 1%% of the %d it wrote", t.seed, late_growth, written_late)
	testing.expectf(t, last <= 2 * loaded, "[seed %d] the file grew to %d pages, from %d", t.seed, last, loaded)

	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	steady_expect(t, &reader, model)
}

/*
REQ-007 at scale: a database whose file has reached the end of a map just
large enough for its data keeps accepting overwrites, on reused pages
alone, for 10⁴ commits (STEADY_COMMITS).

Values keep their size, so the data's size is fixed. The margin is what
the workload can need at once: the pages the previous commit freed (still
pending under D1), those this commit allocates, and put's reserve for its
worst case. A commit allocates at most a leaf and an overflow run per key,
plus the branch pages above them and the free-list run. A held reader
first fills the map, so every later allocation is a reuse.
*/
steady_state_full_map :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	ps := kv.DEFAULT_PAGE_SIZE

	// Load with the default map to measure the data, then reopen with a map
	// of the data plus the margin.
	model := make([]int, STEADY_KEYS, context.temp_allocator)
	env, err := kv.env_open(path, kv.Options{dirty_budget = STEADY_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, steady_commit(t, env, model, 0, STEADY_KEYS, fixed_size = true), kv.Error.None)
	data := kv.env_stats(env)
	depth := int(kv.env_snapshot(env).depth)
	kv.env_close(env)
	commit_pages := STEADY_COMMIT_KEYS * (1 + STEADY_MAX_RUN) + depth + 2
	margin := 2 * commit_pages + (2 * depth + 1 + STEADY_MAX_RUN)
	env, err = kv.env_open(path, kv.Options{map_size = (int(data.last_pgno) + 1 + margin) * ps, dirty_budget = STEADY_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	map_pages := env.map_size / ps

	// A reader pins every page freed, so overwrites extend the file until
	// a put is refused at the end of the map.
	round := 1
	{
		reader, _ := kv.txn_begin(env)
		defer kv.txn_abort(&reader)
		for ; round < 1_000; round += 1 {
			if fill_err := steady_commit(t, env, model, round, STEADY_COMMIT_KEYS, fixed_size = true); fill_err != .None {
				testing.expect_value(t, fill_err, kv.Error.Map_Full)
				break
			}
		}
	}
	filled := kv.env_stats(env)
	testing.expectf(t, int(filled.last_pgno) + commit_pages >= map_pages, "the map never filled: last_pgno %d of %d pages", filled.last_pgno, map_pages)

	COMMITS :: STEADY_COMMITS
	for c in 0 ..< COMMITS {
		round += 1
		if commit_err := steady_commit(t, env, model, round, 1 + rand.int_max(STEADY_COMMIT_KEYS), fixed_size = true); commit_err != .None {
			testing.expectf(t, false, "[seed %d] commit %d at the full map: %v (%v)", t.seed, c, commit_err, kv.env_stats(env))
			return
		}
	}
	s := kv.env_stats(env)
	log.infof("[seed %d] data %d pages, margin %d, map %d pages; filled to %d; after %d commits %v", t.seed, data.last_pgno, margin, map_pages, filled.last_pgno, COMMITS, s)
	testing.expect(t, int(s.last_pgno) < map_pages, "the file grew past the map")

	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	steady_expect(t, &reader, model, fixed_size = true)
}

/*
A long-lived reader pins every page freed while it is held, so the file
grows. Once it ends, a further 10³ commits reuse those pages: no put
extends the file.

The pinned pages stay on the free list (the file never shrinks), so the
list holds thousands of records and its own run is about 30 pages. Until
KV-T-0014 that run had to be exactly as long as its records needed, and
now and then no length fit, so placement extended the file (0–3 times in
1,000 commits over 16 seeds). With a page of slack allowed, the file
doesn't grow at all.

free_ready stays level rather than falling, as KV-T-0013 recorded: each
commit frees about as many pages as it takes. It is logged.
*/
steady_state_long_reader :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = STEADY_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	model := make([]int, STEADY_KEYS, context.temp_allocator)
	if steady_commit(t, env, model, 0, STEADY_KEYS) != .None {
		return
	}
	round := 1
	commit :: proc(t: ^testing.T, env: ^kv.Env, model: []int, round: ^int, written: ^[dynamic]kv.Pgno = nil, put_growth: ^int = nil) -> bool {
		err := steady_commit(t, env, model, round^, 1 + rand.int_max(STEADY_COMMIT_KEYS), written, put_growth)
		testing.expectf(t, err == .None, "[seed %d] round %d: %v", t.seed, round^, err)
		round^ += 1
		return err == .None
	}
	for _ in 0 ..< 200 {
		if !commit(t, env, model, &round) {
			return
		}
	}
	before := kv.env_stats(env)

	// Held for 300 commits, the reader keeps every page they free pending.
	// The first two commits still release pages freed before its snapshot.
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	reader_model := slice.clone(model, context.temp_allocator)
	pending := before.free_pending
	for c in 0 ..< 300 {
		if !commit(t, env, model, &round) {
			return
		}
		s := kv.env_stats(env)
		testing.expect_value(t, s.readers, 1)
		testing.expect_value(t, s.oldest_reader, reader.snapshot.txn_id)
		testing.expectf(t, c < 2 || s.free_pending > pending, "commit %d with the reader held added no pending page", c)
		pending = s.free_pending
	}
	held := kv.env_stats(env)
	testing.expectf(t, held.last_pgno > before.last_pgno + 1_000, "the file grew from %d only to %d while the reader was held", before.last_pgno, held.last_pgno)
	steady_expect(t, &reader, reader_model)
	expect_space_ok(t, &reader)
	kv.txn_abort(&reader)
	ended := kv.env_stats(env)
	testing.expect(t, ended.readers == 0 && ended.oldest_reader == 0, "the reader is still counted")
	// Nothing is released until a write transaction begins.
	testing.expect_value(t, ended.free_pending, held.free_pending)
	snap := kv.env_snapshot(env)
	run_pages := freelist_run_len(t, env, snap)

	written := make([dynamic]kv.Pgno, context.temp_allocator)
	put_growth, reused := 0, 0
	ready: [10]int
	for c in 0 ..< 1_000 {
		clear(&written)
		if !commit(t, env, model, &round, &written, &put_growth) {
			return
		}
		for p in written {
			if p <= held.last_pgno {
				reused += 1
			}
		}
		s := kv.env_stats(env)
		if c == 0 {
			testing.expectf(t, s.free_ready > 1_000, "the first commit released only %d pages", s.free_ready)
		}
		if c % 100 == 99 {
			ready[c / 100] = s.free_ready
		}
	}
	s := kv.env_stats(env)
	growth := int(s.last_pgno - held.last_pgno)
	log.infof("[seed %d] last_pgno %d before the reader, %d while held (%d pending, a run of %d pages); after 1,000 more commits %d, of which %d from puts; %d pages reused; free_ready every 100 commits %v",
		t.seed, before.last_pgno, held.last_pgno, held.free_pending, run_pages, s.last_pgno, put_growth, reused, ready)
	testing.expectf(t, put_growth == 0, "puts added %d pages after the reader ended", put_growth)
	testing.expectf(t, growth == 0, "the file grew by %d pages after the reader ended (free-list run of %d pages)", growth, run_pages)
	testing.expect(t, reused > 5_000, "too few pages reused")
	latest, _ := kv.txn_begin(env)
	defer kv.txn_abort(&latest)
	steady_expect(t, &latest, model)
}


/*
KV-I-0003 NFR-004: with no readers, inserting and deleting over a moving
key set keeps the file bounded, as overwriting does (steady_state_plateau).

Ids 0..<1,000 are loaded, then 10⁴ commits (STEADY_COMMITS) each make 1–20
changes. Half slide the window of live ids: the lowest id is deleted (if a
change inside the window hasn't already) and the next id above it is
inserted, so the tree loses keys on its left and gains them on its right,
and pages merge and split at both ends. The other half toggle a random id
inside the window, deleting it if present and inserting it otherwise.
Values are steady_value's, 15% in overflow runs.

The criteria are the plateau's, and for the same reasons: the second half
of the commits adds at most 1% of the pages it writes, and the file stays
within twice the size the data first loaded at (the window holds fewer
live keys after the load, as the toggles thin it out).
*/
steady_state_churn :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = STEADY_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ps := env.page_size

	COMMITS :: STEADY_COMMITS
	// For each id ever used, the round of its value plus one, or 0 while
	// absent.
	present := make([]int, STEADY_KEYS + COMMITS * STEADY_COMMIT_KEYS, context.temp_allocator)
	model := make([]int, STEADY_KEYS, context.temp_allocator)
	if steady_commit(t, env, model, 0, STEADY_KEYS) != .None {
		return
	}
	for i in 0 ..< STEADY_KEYS {
		present[i] = 1
	}
	loaded := kv.env_stats(env).last_pgno
	lo, hi := 0, STEADY_KEYS
	last, half := loaded, loaded
	written_late, dels, puts := 0, 0, 0

	for round in 1 ..= COMMITS {
		txn, begin_err := kv.txn_begin(env, read_only = false)
		if begin_err != .None {
			testing.expectf(t, false, "round %d: txn_begin: %v", round, begin_err)
			return
		}
		failed := false
		for _ in 0 ..< 1 + rand.int_max(STEADY_COMMIT_KEYS) {
			key: [8]byte
			ids: [2]int
			n := 0
			if rand.int_max(2) == 0 {
				ids[0], ids[1], n = lo, hi, 2
				lo += 1
				hi += 1
			} else {
				ids[0], n = lo + rand.int_max(hi - lo), 1
			}
			for id in ids[:n] {
				op_err: kv.Error
				if present[id] != 0 {
					op_err = kv.del(&txn, u64_key(&key, u64(id)))
					present[id] = 0
					dels += 1
				} else if id < lo {
					continue
				} else {
					op_err = kv.put(&txn, u64_key(&key, u64(id)), steady_value(id, round, ps))
					present[id] = round + 1
					puts += 1
				}
				if op_err != .None {
					testing.expectf(t, false, "[seed %d] round %d: id %d: %v", t.seed, round, id, op_err)
					failed = true
					break
				}
			}
			if failed {
				break
			}
		}
		if round > COMMITS / 2 {
			written_late += len(written_pgnos(&txn))
		}
		if failed || !commit_ok(t, env, &txn) {
			kv.txn_abort(&txn)
			return
		}
		last = kv.env_stats(env).last_pgno
		if round == COMMITS / 2 {
			half = last
		}
	}
	late_growth := int(last - half)
	log.infof("[seed %d] loaded at last_pgno %d; %d after %d commits, %d after %d; %d puts and %d deletes; window [%d, %d); the second half wrote %d pages and added %d; %v",
		t.seed, loaded, half, COMMITS / 2, last, COMMITS, puts, dels, lo, hi, written_late, late_growth, kv.env_stats(env))
	testing.expectf(t, late_growth * 100 <= written_late, "[seed %d] the second half of the commits added %d pages, more than 1%% of the %d it wrote", t.seed, late_growth, written_late)
	testing.expectf(t, last <= 2 * loaded, "[seed %d] the file grew to %d pages, from %d", t.seed, last, loaded)

	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	live: u64
	for round, id in present {
		key: [8]byte
		got, get_err := kv.get(&reader, u64_key(&key, u64(id)))
		if round == 0 {
			if get_err != .Not_Found {
				testing.expectf(t, false, "id %d: %v, want Not_Found", id, get_err)
				return
			}
			continue
		}
		live += 1
		if get_err != .None || !slice.equal(got, steady_value(id, round - 1, ps)) {
			testing.expectf(t, false, "id %d: %v, or not the value of round %d", id, get_err, round - 1)
			return
		}
	}
	testing.expect_value(t, reader.snapshot.entries, live)
}
