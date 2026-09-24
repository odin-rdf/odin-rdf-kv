package kv_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:sync"
import "core:sys/posix"
import "core:testing"

import kv "../kv"

// The value of key 2i after overwrite round `round`.
@(private = "file")
round_value :: proc(i, round: int) -> []byte {
	return transmute([]byte)fmt.tprintf("r%d_%d", round, i)
}

// Overwrites keys 0, 2, ..., 2(n − 1) with round `round`'s values in one
// write transaction and commits it. Returns the pages the transaction freed
// and the pages it wrote (temp allocator).
@(private = "file")
commit_round :: proc(t: ^testing.T, env: ^kv.Env, n, round: int, loc := #caller_location) -> (freed, written: []kv.Pgno, ok: bool) {
	txn, err := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, err, kv.Error.None, loc = loc)
	if err != .None {
		return
	}
	defer kv.txn_abort(&txn)
	for i in 0 ..< n {
		key: [8]byte
		if put_err := kv.put(&txn, u64_key(&key, u64(2 * i)), round_value(i, round)); put_err != .None {
			testing.expectf(t, false, "put failed: %v", put_err, loc = loc)
			return
		}
	}
	if !expect_space_ok(t, &txn, loc) {
		return
	}
	freed = slice.clone(txn.write.freed[:], context.temp_allocator)
	written = dirty_pages(&txn)
	commit_err := kv.txn_commit(&txn)
	testing.expect_value(t, commit_err, kv.Error.None, loc = loc)
	if commit_err != .None {
		return
	}
	return freed, written, expect_latest_ok(t, env, loc)
}

// Checks that `txn` sees exactly keys 0, 2, ... with round `round`'s values.
@(private = "file")
expect_round :: proc(t: ^testing.T, txn: ^kv.Txn, n, round: int, loc := #caller_location) -> bool {
	testing.expect_value(t, txn.snapshot.entries, u64(n), loc = loc)
	for i in 0 ..< n {
		key: [8]byte
		value, err := kv.get(txn, u64_key(&key, u64(2 * i)))
		if err != .None || string(value) != string(round_value(i, round)) {
			testing.expectf(t, false, "key %d: got %q, %v, want round %d", 2 * i, string(value), err, round, loc = loc)
			return false
		}
	}
	return expect_tree_ok(t, txn, loc) && expect_space_ok(t, txn, loc)
}

/*
Begins a write transaction and allocates single pages until page_alloc
extends the file, which it only does once every reusable page is taken.
Returns the reusable pages it was handed, which must be exactly
Env.free.ready in ascending order, and the transaction's horizon. The
transaction is aborted: the pages are only probed.
*/
@(private = "file")
probe_reusable :: proc(t: ^testing.T, env: ^kv.Env, loc := #caller_location) -> (pages: []kv.Pgno, oldest: kv.Txn_Id) {
	txn, err := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, err, kv.Error.None, loc = loc)
	if err != .None {
		return
	}
	defer kv.txn_abort(&txn)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	last := txn.snapshot.last_pgno
	got := make([dynamic]kv.Pgno, context.temp_allocator)
	for {
		pgno, _, alloc_err := kv.page_alloc(&txn, 1)
		testing.expect_value(t, alloc_err, kv.Error.None, loc = loc)
		if alloc_err != .None || pgno > last {
			break
		}
		append(&got, pgno)
	}
	testing.expect(t, slice.equal(got[:], ready), "single pages not handed out lowest first", loc = loc)
	return got[:], txn.write.oldest
}

@(private = "file")
any_in :: proc(pages, set: []kv.Pgno) -> bool {
	for p in pages {
		if slice.contains(set, p) {
			return true
		}
	}
	return false
}

@(private = "file")
all_in :: proc(pages, set: []kv.Pgno) -> bool {
	for p in pages {
		if !slice.contains(set, p) {
			return false
		}
	}
	return true
}

// The pages of the free-list run of `snap`, from the committed meta fields
// and the run's header (temp allocator).
@(private = "file")
run_pages_of :: proc(t: ^testing.T, env: ^kv.Env, snap: kv.Snapshot) -> []kv.Pgno {
	if snap.freelist_pgno == 0 {
		return nil
	}
	pages := make([]kv.Pgno, freelist_run_len(t, env, snap), context.temp_allocator)
	for &p, i in pages {
		p = snap.freelist_pgno + kv.Pgno(i)
	}
	return pages
}

// A page freed by transaction T stays pending while a reader holds T − 1,
// and is reusable by the first write transaction after that reader ends.
@(test)
test_reuse_waits_for_reader :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	N :: 2_000
	for round in 0 ..< 2 {
		if _, _, ok := commit_round(t, env, N, round); !ok {
			return
		}
	}

	// The reader holds snapshot 2; commit 3 frees F.
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, reader.snapshot.txn_id, 2)
	f, _, ok := commit_round(t, env, N, 2)
	if !ok {
		return
	}
	f = slice.concatenate([][]kv.Pgno{f, run_pages_of(t, env, reader.snapshot)}, context.temp_allocator)
	testing.expect(t, len(f) > 0, "commit 3 freed nothing")

	// A reader on the latest snapshot doesn't move the horizon past the
	// older one.
	latest, _ := kv.txn_begin(env)
	defer kv.txn_abort(&latest)
	for round in 3 ..< 6 {
		probed, oldest := probe_reusable(t, env)
		testing.expect_value(t, oldest, 2)
		testing.expect(t, len(probed) > 0 || round > 3, "nothing reusable while the reader is held")
		testing.expect(t, !any_in(f, probed), "a page freed by 3 is reusable while snapshot 2 is read")
		_, written, round_ok := commit_round(t, env, N, round)
		if !round_ok {
			return
		}
		testing.expect(t, !any_in(f, written), "a page freed by 3 was reused while snapshot 2 is read")
		for p in f {
			testing.expectf(t, slice.contains(env.free.pending[:], kv.Free_Record{pgno = u64le(p), txn_id = 3}), "page %d is not pending with tag 3", p)
		}
	}
	// Snapshot 2 is intact, its free-list run included.
	expect_round(t, &reader, N, 1)
	kv.txn_abort(&latest)
	kv.txn_abort(&reader)

	// The first write transaction after the reader ends can take all of F.
	probed, oldest := probe_reusable(t, env)
	testing.expect_value(t, oldest, 5)
	testing.expect(t, all_in(f, probed), "a page freed by 3 is not reusable after the reader ended")
	_, written, _ := commit_round(t, env, N, 6)
	testing.expect(t, any_in(written, probed), "the next commit reused nothing")
}

// Pages freed by commit S are part of snapshot S − 1, which meta page S + 1
// is about to overwrite, so transaction S + 1 must not reuse them; S + 2 can
// (KV-I-0002 D1).
@(test)
test_reuse_keeps_previous_snapshot :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	N :: 2_000
	for round in 0 ..< 2 {
		if _, _, ok := commit_round(t, env, N, round); !ok {
			return
		}
	}
	prev_run := run_pages_of(t, env, kv.env_snapshot(env))
	f, _, ok := commit_round(t, env, N, 2)
	if !ok {
		return
	}
	f = slice.concatenate([][]kv.Pgno{f, prev_run}, context.temp_allocator)
	testing.expect_value(t, kv.env_snapshot(env).txn_id, 3)

	// Transaction 4 begins from 3: pages freed by 3 wait.
	probed, oldest := probe_reusable(t, env)
	testing.expect_value(t, oldest, 2)
	testing.expect(t, len(probed) > 0, "nothing reusable")
	testing.expect(t, !any_in(f, probed), "transaction 4 may reuse pages freed by 3")
	_, written, round_ok := commit_round(t, env, N, 3)
	if !round_ok {
		return
	}
	testing.expect(t, !any_in(f, written), "transaction 4 reused pages freed by 3")
	testing.expect(t, any_in(written, probed), "transaction 4 reused nothing")

	// Transaction 5 can reuse them all.
	probed, oldest = probe_reusable(t, env)
	testing.expect_value(t, oldest, 3)
	testing.expect(t, all_in(f, probed), "transaction 5 may not reuse pages freed by 3")
	commit_round(t, env, N, 4)
}

// A page reused by a write transaction is new to it: touching it again
// changes it in place, and a loose page is handed out before anything else.
@(test)
test_reuse_loose_and_touched_pages :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	N :: 500
	for round in 0 ..< 3 {
		if _, _, ok := commit_round(t, env, N, round); !ok {
			return
		}
	}

	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	testing.expect(t, len(env.free.ready) > 0, "nothing reusable")
	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 0), transmute([]byte)string("first")), kv.Error.None)
	// The path was copied into the lowest reusable pages.
	testing.expect(t, slice.contains(env.free.ready[:], txn.snapshot.root), "root not in a reused page")
	testing.expect_value(t, txn.write.ready_next, int(txn.snapshot.depth))
	dirty, freed, taken := len(txn.write.dirty), len(txn.write.freed), txn.write.ready_taken
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 0), transmute([]byte)string("again")), kv.Error.None)
	testing.expect_value(t, len(txn.write.dirty), dirty)
	testing.expect_value(t, len(txn.write.freed), freed)
	testing.expect_value(t, txn.write.ready_taken, taken)

	// An overflow run replaced within the transaction becomes loose, and
	// its pages are the next single pages handed out, each in a pool slot
	// rather than in the map. (The old run's slots are free again, so the
	// new pages may be in them.)
	big := transmute([]byte)string("big")
	testing.expect_value(t, kv.put(&txn, big, patterned(3 * env.page_size, 1)), kv.Error.None)
	testing.expect_value(t, kv.put(&txn, big, patterned(2 * env.page_size, 2)), kv.Error.None)
	loose := slice.clone(txn.write.loose[:], context.temp_allocator)
	testing.expect_value(t, len(loose), kv.overflow_pages(env.page_size, 3 * env.page_size))
	expect_space_ok(t, &txn)
	for _ in loose {
		pgno, buf, alloc_err := kv.page_alloc(&txn, 1)
		testing.expect_value(t, alloc_err, kv.Error.None)
		testing.expectf(t, slice.contains(loose, pgno), "page %d is not a loose page", pgno)
		p := uintptr(raw_data(buf))
		in_pool := p >= uintptr(env.pool.base) && p < uintptr(env.pool.base) + uintptr(env.pool.reserved)
		testing.expect(t, in_pool, "reused page not in the dirty-page pool")
		dirty, _ := dirty_buf(&txn, pgno)
		testing.expect(t, raw_data(dirty) == raw_data(buf), "reused page not registered as dirty")
	}
	testing.expect_value(t, len(txn.write.loose), 0)
}

// An overflow value is placed in a run of pages freed by an earlier commit.
@(test)
test_reuse_overflow_value_in_freed_run :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ps := env.page_size
	big := transmute([]byte)string("big")
	commit_entries(t, env, {{big, patterned(4 * ps, 1)}, {transmute([]byte)string("a"), transmute([]byte)string("1")}})
	// Commit 2 frees the run; commit 3 changes something else, so that
	// transaction 4 may reuse it.
	commit_entries(t, env, {{big, transmute([]byte)string("small now")}})
	commit_entries(t, env, {{transmute([]byte)string("a"), transmute([]byte)string("2")}})

	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	last := txn.snapshot.last_pgno
	value := patterned(4 * ps, 2)
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big2"), value), kv.Error.None)
	path: kv.Path
	kv.tree_search(&txn, transmute([]byte)string("big2"), &path)
	e := kv.path_leaf(&path)
	_, run, bigdata := kv.leaf_value(kv.page_ptr(&txn, e.pgno), e.idx)
	testing.expect(t, bigdata, "value not in an overflow run")
	n := kv.overflow_pages(ps, len(value))
	for i in 0 ..< n {
		p := run + kv.Pgno(i)
		testing.expectf(t, p <= last && slice.contains(ready, p), "run page %d was not reusable", p)
		testing.expectf(t, slice.contains(txn.write.taken[:], p), "run page %d not recorded as taken", p)
	}
	expect_space_ok(t, &txn)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)

	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	got, get_err := kv.get(&reader, transmute([]byte)string("big2"))
	testing.expect(t, get_err == .None && slice.equal(got, value), "overflow value differs")
	expect_tree_ok(t, &reader)
	expect_space_ok(t, &reader)
}

// An aborted transaction leaves Env.free exactly as it was once it had
// begun, however much it took from it.
@(test)
test_reuse_abort_leaves_free_unchanged :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ps := env.page_size
	// Overflow values in every commit, so reusable runs exist.
	for round in 0 ..< 6 {
		txn, _ := kv.txn_begin(env, read_only = false)
		for i in 0 ..< 300 {
			key: [8]byte
			size := 2 * ps if i % 10 == 0 else 20
			kv.put(&txn, u64_key(&key, u64(i)), patterned(size, u32(round)))
		}
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	}
	before := kv.env_snapshot(env)

	ready: []kv.Pgno
	pending: []kv.Free_Record
	for attempt in 0 ..< 2 {
		txn, _ := kv.txn_begin(env, read_only = false)
		if attempt == 0 {
			ready = slice.clone(env.free.ready[:], context.temp_allocator)
			pending = slice.clone(env.free.pending[:], context.temp_allocator)
			testing.expect(t, len(ready) > 0, "nothing reusable")
		} else {
			// Beginning again from the same snapshot has nothing to move.
			testing.expect(t, slice.equal(env.free.ready[:], ready), "ready pages changed by beginning again")
			testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records changed by beginning again")
		}
		for i in 0 ..< 2_000 {
			key: [8]byte
			size := 2 * ps if i % 7 == 0 else 30
			kv.put(&txn, u64_key(&key, u64(rand.int_max(3_000))), patterned(size, 9))
		}
		testing.expect_value(t, txn.err, kv.Error.None)
		// Loose pages come first, so a reusable page or two may be left.
		testing.expect(t, txn.write.ready_taken > len(ready) / 2, "few reusable pages taken")
		testing.expect(t, len(txn.write.taken) > 0 && len(txn.write.loose) > 0, "no run taken or dropped")
		expect_space_ok(t, &txn)
		kv.txn_abort(&txn)

		testing.expectf(t, slice.equal(env.free.ready[:], ready), "attempt %d: ready pages changed", attempt)
		testing.expectf(t, slice.equal(env.free.pending[:], pending), "attempt %d: pending records changed", attempt)
		testing.expect_value(t, kv.env_snapshot(env), before)
		expect_latest_ok(t, env)
	}
}

// As if a commit had written the pages it reused and then failed before its
// meta page: the database is still at S, and still falls back to S − 1.
@(test)
test_reuse_failed_commit_keeps_both_snapshots :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	N :: 1_000
	for round in 0 ..< 5 {
		if _, _, ok := commit_round(t, env, N, round); !ok {
			kv.env_close(env)
			return
		}
	}
	s := kv.env_snapshot(env)
	testing.expect_value(t, s.txn_id, 5)

	txn, _ := kv.txn_begin(env, read_only = false)
	for i in 0 ..< N {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(2 * i)), round_value(i, 5))
	}
	reused := 0
	for pgno in txn.write.dirty {
		if pgno <= s.last_pgno {
			buf, _ := dirty_buf(&txn, pgno)
			testing.expect_value(t, kv.os_pwrite(env.fd, buf, i64(pgno) * i64(env.page_size)), kv.Error.None)
			reused += 1
		}
	}
	testing.expect(t, reused > 0, "nothing reused")
	fd := env.fd
	env.fd = posix.FD(-1)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.Io)
	env.fd = fd
	kv.env_close(env)

	{
		env2, reader, ok := open_read(t, path)
		if !ok {
			return
		}
		testing.expect_value(t, reader.snapshot, s)
		expect_round(t, &reader, N, 4)
		kv.txn_abort(&reader)
		kv.env_close(env2)
	}
	corrupt_meta(t, path, int(s.txn_id & 1))
	env3, reader, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env3)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, reader.snapshot.txn_id, s.txn_id - 1)
	expect_round(t, &reader, N, 3)
}

// Once the file has reached the end of the map, overwrites keep succeeding
// on reused pages. A commit whose free-list run fits nowhere fails with
// Map_Full and leaves the database as it was (KV-I-0002 D6).
@(test)
test_reuse_full_map :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	options := kv.Options{map_size = 256 * 1024}

	env, err := kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	value :: proc(i, round: int) -> []byte {
		return transmute([]byte)fmt.tprintf("%06d_%06d", round, i)
	}

	N :: 600
	model := make([]int, N, context.temp_allocator)
	txn0, _ := kv.txn_begin(env, read_only = false)
	for i in 0 ..< N {
		key: [8]byte
		kv.put(&txn0, u64_key(&key, u64(i)), value(i, 0))
	}
	testing.expect_value(t, kv.txn_commit(&txn0), kv.Error.None)

	// A reader pins every page, so overwrites extend the file until it
	// reaches the end of the map.
	pages := env.map_size / env.page_size
	pinned := 0
	{
		reader, _ := kv.txn_begin(env)
		defer kv.txn_abort(&reader)
		full: for round := 1; ; round += 1 {
			txn, _ := kv.txn_begin(env, read_only = false)
			for i in 0 ..< N {
				key: [8]byte
				if put_err := kv.put(&txn, u64_key(&key, u64(i)), value(i, round)); put_err != .None {
					testing.expect_value(t, put_err, kv.Error.Map_Full)
					testing.expect_value(t, txn.err, kv.Error.None)
					kv.txn_abort(&txn)
					break full
				}
			}
			commit_err := kv.txn_commit(&txn)
			if commit_err == .Map_Full {
				break full
			}
			testing.expect_value(t, commit_err, kv.Error.None)
			slice.fill(model, round)
			pinned += 1
		}
	}
	testing.expect(t, pinned > 0, "no overwrite fit while the reader was held")

	// With the reader gone, overwrites keep committing on reused pages,
	// writing many times more pages than the map holds.
	written := 0
	for round in 1 ..= 200 {
		txn, _ := kv.txn_begin(env, read_only = false)
		for _ in 0 ..< 1 + rand.int_max(10) {
			i := rand.int_max(N)
			key: [8]byte
			put_err := kv.put(&txn, u64_key(&key, u64(i)), value(i, 1_000 + round))
			if put_err != .None {
				testing.expectf(t, false, "round %d: put: %v", round, put_err)
				kv.txn_abort(&txn)
				kv.env_close(env)
				return
			}
			model[i] = 1_000 + round
		}
		written += len(written_pgnos(&txn))
		if commit_err := kv.txn_commit(&txn); commit_err != .None {
			testing.expectf(t, false, "round %d: commit: %v", round, commit_err)
			kv.env_close(env)
			return
		}
		if !expect_latest_ok(t, env) {
			kv.env_close(env)
			return
		}
	}
	testing.expect(t, written > 4 * pages, "too few pages written")
	testing.expect(t, int(kv.env_snapshot(env).last_pgno) < pages, "file grew past the map")
	before := kv.env_snapshot(env)

	// Take every page left, reusable or at the end, so the run has nowhere
	// to go.
	txn, _ := kv.txn_begin(env, read_only = false)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	pending := slice.clone(env.free.pending[:], context.temp_allocator)
	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 0), value(0, 999)), kv.Error.None)
	for {
		if _, _, alloc_err := kv.page_alloc(&txn, 1); alloc_err != .None {
			testing.expect_value(t, alloc_err, kv.Error.Map_Full)
			break
		}
	}
	testing.expect_value(t, txn.write.ready_taken, len(ready))
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.Map_Full)
	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, slice.equal(env.free.ready[:], ready), "ready pages changed")
	testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records changed")
	testing.expect(t, sync.mutex_try_lock(&env.writer_mutex), "writer lock not released")
	sync.mutex_unlock(&env.writer_mutex)
	kv.env_close(env)

	env2, reader, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env2)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, reader.snapshot, before)
	for i in 0 ..< N {
		got, get_err := kv.get(&reader, u64_key(&key, u64(i)))
		if get_err != .None || string(got) != string(value(i, model[i])) {
			testing.expectf(t, false, "key %d: got %q, %v", i, string(got), get_err)
			break
		}
	}
	expect_tree_ok(t, &reader)
	expect_space_ok(t, &reader)
}
