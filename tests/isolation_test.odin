package kv_tests

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
	// in one commit, updating the model.
	commit_random :: proc(t: ^testing.T, env: ^kv.Env, ks: Key_Space, model: Model, buf: []byte, count: int, version: ^u32, ps: int) -> bool {
		txn, err := kv.txn_begin(env, read_only = false)
		if err != .None {
			return false
		}
		defer kv.txn_abort(&txn)
		for _ in 0 ..< count {
			id := rand.int_max(len(model))
			version^ += 1
			size := rand.int_max(3 * ps) if rand.int_max(20) == 0 else rand.int_max(40)
			spec := Val_Spec{true, version^, size}
			if kv.put(&txn, ks.keys[id], model_value(id, spec, buf)) != .None {
				return false
			}
			model[id] = spec
		}
		return kv.txn_commit(&txn) == .None
	}

	// The starting state: about 10,000 keys.
	testing.expect(t, commit_random(t, env, ks, model, value_buf, 16_000, &version, ps), "initial commit failed")
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
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	model_compare(t, &reader, ks, model, value_buf, "new reader after the writer", t.seed)
}
