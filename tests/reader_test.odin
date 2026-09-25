package kv_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import kv "../kv"

// Puts one small entry and commits it, returning the new snapshot's txn_id.
// space_check runs on the write transaction just before the commit, rather
// than on a new reader after it, which would change the reader table these
// tests inspect.
@(private = "file")
commit_one :: proc(t: ^testing.T, env: ^kv.Env, i: int) -> kv.Txn_Id {
	txn, err := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return 0
	}
	defer kv.txn_abort(&txn)
	key := fmt.tprintf("key%05d", i)
	testing.expect_value(t, kv.put(&txn, transmute([]byte)key, transmute([]byte)key), kv.Error.None)
	expect_space_ok(t, &txn)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	return kv.env_snapshot(env).txn_id
}

// Checks the reader table's invariants under its lock: slots strictly
// increasing, none at count 0, none newer than the latest snapshot. Returns
// the number of registered readers, or a problem as a string literal (so it
// allocates nothing and is safe on any thread).
@(private = "file")
reader_table_check :: proc(env: ^kv.Env) -> (readers: int, problem: string) {
	sync.mutex_lock(&env.snapshot_mutex)
	defer sync.mutex_unlock(&env.snapshot_mutex)
	for slot, i in env.readers {
		if slot.count <= 0 {
			return 0, "slot with a count of 0 or less"
		}
		if i > 0 && env.readers[i - 1].txn_id >= slot.txn_id {
			return 0, "slots not strictly increasing"
		}
		if slot.txn_id > env.snapshot.txn_id {
			return 0, "slot newer than the latest snapshot"
		}
		readers += slot.count
	}
	return readers, ""
}

// Returns the reader table as a slice of slots, copied under its lock.
@(private = "file")
reader_slots :: proc(env: ^kv.Env) -> []kv.Reader_Slot {
	sync.mutex_lock(&env.snapshot_mutex)
	defer sync.mutex_unlock(&env.snapshot_mutex)
	out := make([]kv.Reader_Slot, len(env.readers), context.temp_allocator)
	copy(out, env.readers[:])
	return out
}

@(test)
test_reader_table_one_snapshot :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	_, ok := kv.env_oldest_reader(env)
	testing.expect(t, !ok, "a reader before any transaction began")
	snap := commit_one(t, env, 0)

	// A write transaction never registers, with or without readers around.
	{
		w, _ := kv.txn_begin(env, read_only = false)
		_, ok = kv.env_oldest_reader(env)
		testing.expect(t, !ok, "a write transaction registered as a reader")
		kv.txn_abort(&w)
	}

	N :: 100
	txns: [N]kv.Txn
	for &txn in txns {
		txn, err = kv.txn_begin(env)
		testing.expect_value(t, err, kv.Error.None)
	}
	testing.expect_value(t, len(env.readers), 1)
	testing.expect_value(t, env.readers[0], kv.Reader_Slot{snap, N})
	{
		w, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, len(env.readers), 1)
		kv.txn_abort(&w)
	}

	// End them in a random order: through commit, abort, and abort again.
	order := rand.perm(N, context.temp_allocator)
	for idx, step in order {
		if step % 3 == 0 {
			testing.expect_value(t, kv.txn_commit(&txns[idx]), kv.Error.None)
		}
		kv.txn_abort(&txns[idx])
		kv.txn_abort(&txns[idx])
		left := N - step - 1
		oldest, has := kv.env_oldest_reader(env)
		if left > 0 {
			testing.expect_value(t, env.readers[0], kv.Reader_Slot{snap, left})
			testing.expect(t, has && oldest == snap, "oldest reader lost")
		} else {
			testing.expect_value(t, len(env.readers), 0)
			testing.expect(t, !has, "reader left after all ended")
		}
	}
}

@(test)
test_reader_table_several_snapshots :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	// Between two and four readers on each of 30 snapshots, more than the
	// table's initial capacity. Snapshot 0 (the empty database) is one.
	SNAPSHOTS :: 30
	txns := make([dynamic]kv.Txn, context.temp_allocator)
	per_snapshot: [SNAPSHOTS]int
	for s in 0 ..< SNAPSHOTS {
		if s > 0 {
			testing.expect_value(t, commit_one(t, env, s), kv.Txn_Id(s))
		}
		per_snapshot[s] = 2 + rand.int_max(3)
		for _ in 0 ..< per_snapshot[s] {
			txn, begin_err := kv.txn_begin(env)
			testing.expect_value(t, begin_err, kv.Error.None)
			testing.expect_value(t, txn.snapshot.txn_id, kv.Txn_Id(s))
			append(&txns, txn)
		}
	}
	slots := reader_slots(env)
	testing.expect_value(t, len(slots), SNAPSHOTS)
	for slot, s in slots {
		testing.expect_value(t, slot, kv.Reader_Slot{kv.Txn_Id(s), per_snapshot[s]})
	}

	// End them in a random order, checking the whole table after each step
	// against the readers still live.
	order := rand.perm(len(txns), context.temp_allocator)
	for idx, step in order {
		ended := txns[idx].snapshot.txn_id
		kv.txn_abort(&txns[idx])
		per_snapshot[ended] -= 1

		expected := make([dynamic]kv.Reader_Slot, context.temp_allocator)
		for count, s in per_snapshot {
			if count > 0 {
				append(&expected, kv.Reader_Slot{kv.Txn_Id(s), count})
			}
		}
		got := reader_slots(env)
		same := len(got) == len(expected)
		for i in 0 ..< min(len(got), len(expected)) {
			same &&= got[i] == expected[i]
		}
		testing.expectf(t, same, "step %d (ended a reader on %d): table %v, expected %v", step, ended, got, expected[:])

		oldest, has := kv.env_oldest_reader(env)
		if len(expected) > 0 {
			testing.expect(t, has && oldest == expected[0].txn_id, "wrong oldest reader")
		} else {
			testing.expect(t, !has, "reader left after all ended")
		}
		if !same {
			break
		}
	}
	for &txn in txns {
		kv.txn_abort(&txn)
	}
}

// Beginning and ending readers allocates nothing once the table has room,
// and env_close frees everything the environment allocated.
@(test)
test_reader_table_allocates_nothing :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	env, err := kv.env_open(temp_dir_file(dir, DB), allocator = mem.tracking_allocator(&track))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}

	begin_end_readers :: proc(t: ^testing.T, env: ^kv.Env, track: ^mem.Tracking_Allocator) {
		before := track.total_allocation_count
		held: [kv.READER_TABLE_CAPACITY]kv.Txn
		for &txn in held {
			txn, _ = kv.txn_begin(env)
		}
		for _ in 0 ..< 1_000 {
			txn, begin_err := kv.txn_begin(env)
			testing.expect_value(t, begin_err, kv.Error.None)
			kv.txn_abort(&txn)
		}
		for &txn in held {
			kv.txn_abort(&txn)
		}
		testing.expect_value(t, track.total_allocation_count, before)
	}

	// Within the capacity reserved at open.
	begin_end_readers(t, env, &track)

	// Grow the table past it: one reader on each of 2 × capacity snapshots.
	grown: [2 * kv.READER_TABLE_CAPACITY]kv.Txn
	for &txn, i in grown {
		commit_one(t, env, i)
		txn, _ = kv.txn_begin(env)
	}
	testing.expect_value(t, len(env.readers), len(grown))

	// With the table full, more readers on the newest snapshot, and ending
	// the held ones out of order, allocate nothing.
	before := track.total_allocation_count
	begin_end_readers(t, env, &track)
	for idx in rand.perm(len(grown), context.temp_allocator) {
		kv.txn_abort(&grown[idx])
	}
	testing.expect_value(t, track.total_allocation_count, before)
	testing.expect(t, cap(env.readers) >= len(grown), "table capacity shrank")

	// Within the capacity it grew to.
	begin_end_readers(t, env, &track)

	kv.env_close(env)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(private = "file")
Table_Reader :: struct {
	env:     ^kv.Env,
	stop:    ^bool,
	// Read transactions begun by every reader, read by the writer while
	// they run.
	total:   ^int,
	// Results, read after the thread is joined.
	begins:  int,
	problem: string,
	err:     kv.Error,
}

// Begins and ends read transactions until told to stop, sometimes holding a
// second, newer one and ending the older first. While a reader is live, the
// table must hold its snapshot as the oldest or newer.
@(private = "file")
table_reader_run :: proc(r: ^Table_Reader) {
	for !sync.atomic_load(r.stop) {
		a, err := kv.txn_begin(r.env)
		if err != .None {
			r.err = err
			return
		}
		r.begins += 1
		sync.atomic_add(r.total, 1)
		b: kv.Txn
		two := rand.int_max(2) == 0
		if two {
			time.sleep(time.Duration(rand.int_max(50)) * time.Microsecond)
			if b, err = kv.txn_begin(r.env); err != .None {
				kv.txn_abort(&a)
				r.err = err
				return
			}
			r.begins += 1
			sync.atomic_add(r.total, 1)
			if b.snapshot.txn_id < a.snapshot.txn_id {
				r.problem = "a later reader got an older snapshot"
			}
		}
		oldest, ok := kv.env_oldest_reader(r.env)
		if !ok || oldest > a.snapshot.txn_id {
			r.problem = "a live reader's snapshot is older than the oldest reader"
		}
		if _, problem := reader_table_check(r.env); problem != "" {
			r.problem = problem
		}
		kv.txn_abort(&a)
		if two {
			if oldest, ok = kv.env_oldest_reader(r.env); !ok || oldest > b.snapshot.txn_id {
				r.problem = "a live reader's snapshot is older than the oldest reader"
			}
			kv.txn_abort(&b)
		}
		if r.problem != "" {
			return
		}
	}
}

// Readers begin and end on several threads while a writer commits. The table
// stays valid throughout and ends empty. Run with -sanitize:thread.
//
// The writer makes COMMITS commits, and goes on until the readers have begun
// more read transactions than that, up to MAX_COMMITS: without syncs
// (KV_NO_SYNC) 300 commits can end before the reader threads are well under
// way, which on Linux left 50–250 read transactions every time (KV-T-0033).
@(test)
test_reader_table_across_threads :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	READERS :: 6
	stop := false
	total := 0
	readers: [READERS]Table_Reader
	threads: [READERS]^thread.Thread
	for &r, i in readers {
		r = Table_Reader {
			env  = env,
			stop = &stop,
			total = &total,
		}
		threads[i] = thread.create_and_start_with_poly_data(&r, table_reader_run)
	}

	COMMITS :: 300
	MAX_COMMITS :: 100 * COMMITS
	max_readers := 0
	commits := 0
	for commits < COMMITS || (commits < MAX_COMMITS && sync.atomic_load(&total) <= COMMITS) {
		i := commits
		commits += 1
		commit_one(t, env, i)
		n, problem := reader_table_check(env)
		testing.expectf(t, problem == "", "after commit %d: %s", i, problem)
		max_readers = max(max_readers, n)
	}
	sync.atomic_store(&stop, true)
	thread.join_multiple(..threads[:])
	for th in threads {
		thread.destroy(th)
	}

	for r, i in readers {
		testing.expectf(t, r.err == .None, "reader %d: txn_begin %v", i, r.err)
		testing.expectf(t, r.problem == "", "reader %d: %s", i, r.problem)
		testing.expectf(t, r.begins > 0, "reader %d never began", i)
	}
	begins := 0
	for r in readers {
		begins += r.begins
	}
	testing.expect_value(t, begins, total)
	log.infof("%d read transactions across %d commits, at most %d live at a commit", begins, commits, max_readers)
	testing.expectf(t, begins > COMMITS, "only %d read transactions across %d commits", begins, commits)

	n, problem := reader_table_check(env)
	testing.expectf(t, problem == "", "at the end: %s", problem)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(env.readers), 0)
}
