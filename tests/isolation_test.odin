package kv_tests

import "core:bytes"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import kv "../kv"

// A reader thread: holds one read transaction and keeps comparing it with
// the model state from when it began, until told to stop.
@(private = "file")
Reader :: struct {
	env:       ^kv.Env,
	ks:        Key_Space,
	frozen:    Model,
	value_buf: []byte,
	ready:     ^int,
	stop:      ^bool,
	// Results, read after the thread is joined.
	begin_err: kv.Error,
	txn_id:    kv.Txn_Id,
	scans:     int,
	diff:      string,
}

@(private = "file")
reader_run :: proc(r: ^Reader) {
	txn, err := kv.txn_begin(r.env)
	r.begin_err = err
	sync.atomic_add(r.ready, 1)
	if err != .None {
		return
	}
	defer kv.txn_abort(&txn)
	r.txn_id = txn.snapshot.txn_id
	for {
		if diff := model_diff(&txn, r.ks, r.frozen, r.value_buf); diff != "" {
			r.diff = diff
			return
		}
		r.scans += 1
		if sync.atomic_load(r.stop) {
			return
		}
	}
}

// A hash of one entry. Entry hashes are summed, so a snapshot's checksum can
// be updated as its entries change, whatever their order.
@(private = "file")
entry_hash :: proc(key, value: []byte) -> u64 {
	h: u64 = 0xCBF2_9CE4_8422_2325
	for b in key {
		h = (h ~ u64(b)) * 0x100_0000_01B3
	}
	h = (h ~ 0xFF) * 0x100_0000_01B3
	for b in value {
		h = (h ~ u64(b)) * 0x100_0000_01B3
	}
	h ~= h >> 33
	h *= 0xFF51_AFD7_ED55_8CCD
	return h ~ (h >> 33)
}

// Scans everything `txn` sees, checking that the keys ascend and that there
// are as many as the snapshot says, and returns the sum of the entry
// hashes.
@(private = "file")
scan_checksum :: proc(txn: ^kv.Txn) -> (sum: u64, problem: string) {
	c := kv.cursor_open(txn)
	prev: []byte
	n: u64
	for key, value, err := kv.cursor_first(&c); err == .None; key, value, err = kv.cursor_next(&c) {
		if n > 0 && bytes.compare(prev, key) >= 0 {
			return 0, "keys out of order"
		}
		sum += entry_hash(key, value)
		prev = key
		n += 1
	}
	if n != txn.snapshot.entries {
		return 0, "the scan found a different number of entries"
	}
	return sum, ""
}

// A reader thread that keeps beginning read transactions, scanning each one
// one to three times against the checksum the writer recorded for its
// snapshot, and ending it.
@(private = "file")
Churn_Reader :: struct {
	env:     ^kv.Env,
	// Indexed by txn_id. The writer fills an entry before publishing that
	// snapshot, so the reader's txn_begin orders the read after the write.
	sums:     []u64,
	stop:     ^bool,
	// Read transactions finished by all churn readers, and churn readers
	// still running; both updated atomically, so the writer can pace
	// itself.
	finished: ^int,
	running:  ^int,
	// Results, read after the thread is joined.
	txns:    int,
	scans:   int,
	problem: string,
	err:     kv.Error,
}

@(private = "file")
churn_reader_run :: proc(r: ^Churn_Reader) {
	defer sync.atomic_sub(r.running, 1)
	for !sync.atomic_load(r.stop) {
		txn, err := kv.txn_begin(r.env)
		if err != .None {
			r.err = err
			return
		}
		want := r.sums[txn.snapshot.txn_id]
		for _ in 0 ..= rand.int_max(3) {
			got, problem := scan_checksum(&txn)
			if problem == "" && got != want {
				problem = "the checksum differs from the snapshot's"
			}
			if problem != "" {
				r.problem = problem
				kv.txn_abort(&txn)
				return
			}
			r.scans += 1
		}
		s := kv.env_stats(r.env)
		if s.readers < 1 || s.oldest_reader == 0 || s.oldest_reader > txn.snapshot.txn_id {
			r.problem = "env_stats doesn't count this reader"
		}
		kv.txn_abort(&txn)
		r.txns += 1
		sync.atomic_add(r.finished, 1)
		if r.problem != "" {
			return
		}
	}
}

/*
Readers see their snapshot however much the writer changes, while pages are
reused under them. A third of the writer's operations are deletes, so pages
merge and are dropped under the readers too. First four readers hold one snapshot for 100 commits,
which pins every page those commits free. Then four readers keep beginning
and ending transactions for 200 more commits, so the horizon moves and
freed pages are reused all the time; each checks its scans against the
checksum of its snapshot. The writer waits for a read transaction to finish
before each of those commits, so they interleave however fast commits are.
Run with -sanitize:thread.
*/
@(test)
test_snapshot_isolation_across_threads :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	KEYS :: 12_000
	ks := key_space_make(KEYS)
	model := make(Model, KEYS, context.temp_allocator)
	value_buf := make([]byte, MODEL_MAX_VALUE, context.temp_allocator)
	ps := kv.DEFAULT_PAGE_SIZE

	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{map_size = 4 << 30})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	version: u32
	// Puts `count` random keys (new or existing, some with overflow values)
	// in one commit, updating the model. With `deletes`, a third of the
	// operations delete a random key instead, present or not.
	commit_random :: proc(t: ^testing.T, env: ^kv.Env, ks: Key_Space, model: Model, buf: []byte, count: int, version: ^u32, ps: int, deletes := true) -> bool {
		txn, err := kv.txn_begin(env, read_only = false)
		if err != .None {
			return false
		}
		defer kv.txn_abort(&txn)
		for _ in 0 ..< count {
			id := rand.int_max(len(model))
			if deletes && rand.int_max(3) == 0 {
				want := kv.Error.None if model[id].present else kv.Error.Not_Found
				if kv.del(&txn, ks.keys[id]) != want {
					return false
				}
				model[id] = {}
				continue
			}
			version^ += 1
			size := rand.int_max(3 * ps) if rand.int_max(20) == 0 else rand.int_max(40)
			spec := Val_Spec{true, version^, size}
			if kv.put(&txn, ks.keys[id], model_value(id, spec, buf)) != .None {
				return false
			}
			model[id] = spec
		}
		return kv.txn_commit(&txn) == .None && expect_latest_ok(t, env)
	}

	// The starting state: about 10,000 keys.
	testing.expect(t, commit_random(t, env, ks, model, value_buf, 16_000, &version, ps, deletes = false), "initial commit failed")
	base_txn := kv.env_snapshot(env).txn_id
	frozen := slice.clone(model, context.temp_allocator)

	READERS :: 4
	ready := 0
	stop := false
	readers: [READERS]Reader
	threads: [READERS]^thread.Thread
	for &r, i in readers {
		r = Reader {
			env       = env,
			ks        = ks,
			frozen    = frozen,
			value_buf = make([]byte, MODEL_MAX_VALUE, context.temp_allocator),
			ready     = &ready,
			stop      = &stop,
		}
		threads[i] = thread.create_and_start_with_poly_data(&r, reader_run)
	}
	for sync.atomic_load(&ready) < READERS {
		time.sleep(time.Millisecond)
	}

	// The writer commits 100 times while the readers scan.
	for _ in 0 ..< 100 {
		if !commit_random(t, env, ks, model, value_buf, 100, &version, ps) {
			testing.expect(t, false, "writer commit failed")
			break
		}
	}
	sync.atomic_store(&stop, true)
	thread.join_multiple(..threads[:])
	for th in threads {
		thread.destroy(th)
	}

	log.infof("reader scans while the writer committed: %d %d %d %d", readers[0].scans, readers[1].scans, readers[2].scans, readers[3].scans)
	for r, i in readers {
		testing.expectf(t, r.begin_err == .None, "reader %d: txn_begin %v", i, r.begin_err)
		testing.expectf(t, r.diff == "", "[seed %d] reader %d saw a change: %s", t.seed, i, r.diff)
		testing.expectf(t, r.txn_id == base_txn, "reader %d began at txn %d, not %d", i, r.txn_id, base_txn)
		testing.expectf(t, r.scans >= 1, "reader %d never finished a scan", i)
	}
	testing.expect_value(t, kv.env_snapshot(env).txn_id, base_txn + 100)

	// The writer really changed things, and a new reader sees all of it.
	testing.expect(t, !slice.equal(model, frozen), "the writer changed nothing")
	{
		reader, _ := kv.txn_begin(env)
		defer kv.txn_abort(&reader)
		model_compare(t, &reader, ks, model, value_buf, "new reader after the writer", t.seed)
	}

	// Readers come and go while the writer overwrites, forcing reuse.
	CHURN_COMMITS :: 200
	first := kv.env_snapshot(env).txn_id
	sums := make([]u64, int(first) + CHURN_COMMITS + 2, context.temp_allocator)
	sum: u64
	for spec, id in model {
		if spec.present {
			sum += entry_hash(ks.keys[id], model_value(id, spec, value_buf))
		}
	}
	sums[first] = sum
	churn_stop := false
	finished, running := 0, READERS
	churn: [READERS]Churn_Reader
	for &r, i in churn {
		r = Churn_Reader {
			env      = env,
			sums     = sums,
			stop     = &churn_stop,
			finished = &finished,
			running  = &running,
		}
		threads[i] = thread.create_and_start_with_poly_data(&r, churn_reader_run)
	}
	reused, overflow, deleted, seen := 0, 0, 0, 0
	for c in 0 ..< CHURN_COMMITS {
		for sync.atomic_load(&finished) == seen && sync.atomic_load(&running) > 0 {
			time.sleep(100 * time.Microsecond)
		}
		seen = sync.atomic_load(&finished)
		txn, begin_err := kv.txn_begin(env, read_only = false)
		if begin_err != .None {
			testing.expectf(t, false, "churn commit %d: txn_begin %v", c, begin_err)
			break
		}
		last := txn.snapshot.last_pgno
		failed := false
		for _ in 0 ..< 50 {
			id := rand.int_max(len(model))
			if rand.int_max(3) == 0 {
				want := kv.Error.None if model[id].present else kv.Error.Not_Found
				if kv.del(&txn, ks.keys[id]) != want {
					failed = true
					break
				}
				if model[id].present {
					sum -= entry_hash(ks.keys[id], model_value(id, model[id], value_buf))
					deleted += 1
				}
				model[id] = {}
				continue
			}
			version += 1
			big := rand.int_max(20) == 0
			spec := Val_Spec{true, version, rand.int_max(3 * ps) if big else rand.int_max(40)}
			if kv.put(&txn, ks.keys[id], model_value(id, spec, value_buf)) != .None {
				failed = true
				break
			}
			if model[id].present {
				sum -= entry_hash(ks.keys[id], model_value(id, model[id], value_buf))
			}
			sum += entry_hash(ks.keys[id], model_value(id, spec, value_buf))
			model[id] = spec
			overflow += int(big)
		}
		for pgno in txn.write.dirty {
			if pgno <= last {
				reused += 1
			}
		}
		// Recorded before the snapshot is published.
		sums[txn.snapshot.txn_id + 1] = sum
		if failed || kv.txn_commit(&txn) != .None {
			kv.txn_abort(&txn)
			testing.expectf(t, false, "churn commit %d failed", c)
			break
		}
		if !expect_latest_ok(t, env) {
			break
		}
	}
	sync.atomic_store(&churn_stop, true)
	thread.join_multiple(..threads[:])
	for th in threads {
		thread.destroy(th)
	}

	total := 0
	for r, i in churn {
		testing.expectf(t, r.err == .None, "churn reader %d: txn_begin %v", i, r.err)
		testing.expectf(t, r.problem == "", "[seed %d] churn reader %d: %s", t.seed, i, r.problem)
		testing.expectf(t, r.txns >= 1, "churn reader %d never finished a transaction", i)
		total += r.txns
	}
	log.infof("%d read transactions across %d commits (%d overflow values, %d deletes) that reused %d pages; %v", total, CHURN_COMMITS, overflow, deleted, reused, kv.env_stats(env))
	testing.expect(t, total >= CHURN_COMMITS, "too few read transactions")
	testing.expect(t, reused > 10 * CHURN_COMMITS, "too few pages reused")
	testing.expect_value(t, kv.env_stats(env).readers, 0)

	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	model_compare(t, &reader, ks, model, value_buf, "new reader after the churn", t.seed)
	expect_space_ok(t, &reader)
}
