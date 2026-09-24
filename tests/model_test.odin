package kv_tests

import "core:bytes"
import "core:log"
import "core:math/rand"
import "core:testing"

import kv "../kv"

Model_Stats :: struct {
	puts, overflow_puts, gets, scans, commits, aborts, reopens: int,
	// Deletes of present keys, deletes of absent ones (Not_Found), and
	// commits that left the tree empty.
	dels, absent_dels, empty_commits:                          int,
	// Read transactions held across commits and checked on release, the
	// commits they were held across in total, and pages that commits wrote
	// in place of a page of the file they began from (reused pages).
	held_readers, held_commits, reused_pages:                 int,
	// Pages spilled from the dirty-page pool (Stats.spills at the end).
	spills:                                                    int,
}

// At most this many read transactions are held at once.
MODEL_HELD_READERS :: 4

// A read transaction run_model holds across commits, with the committed
// model it began at.
@(private = "file")
Held_Reader :: struct {
	txn:     kv.Txn,
	model:   Model,
	// Stats.commits when it began, and when it is to be released.
	begun:   int,
	release: int,
}

/*
Runs `ops` random operations against the database at `path` and the model,
comparing after every commit and reopen, and checking with space_check that
every page is owned exactly once before and after every commit. Stops early (returning true) when
`stop_on_map_full` is set and a put hits Map_Full, after aborting, reopening
and checking that the database is still at the last commit.

The workload alternates between tides: a rising tide of 10–40 commits,
then a falling one that lasts until a commit leaves the tree empty (or 200
commits). Without `tides` the tide never falls. Each operation is:
- 40% (rising) or 10% (falling) put, a new key or an overwrite: 70% small
  values, 20% within a few bytes of the inline/overflow boundary, 10%
  overflow values of up to 3 pages;
- 10% (rising) or 40% (falling) delete: 80% of a present key (the first
  present one from a random position in key order), 20% of a random id,
  which may be absent;
- 25% get, of present and absent keys;
- 15% forward range scan: seek (to a key or random bytes), then up to 20
  nexts;
- 10% backward walk: seek, then up to 10 prevs.

Transactions last 1–500 operations; 85% commit and 15% abort. The database
is closed and reopened about every 10,000 operations.

Alongside the writer, up to `max_held` read transactions are held:
each begins at a random operation, with a copy of the committed model, and
is released after 1–20 further commits (or before a reopen). On release it
must still match the model it began at, by model_diff and space_check, so a
page reused while a reader could still see it is caught.
*/
run_model :: proc(t: ^testing.T, path: string, options: kv.Options, ops: int, keys: int, stop_on_map_full := false, max_held := MODEL_HELD_READERS, tides := true) -> (stats: Model_Stats, hit_map_full: bool) {
	seed := t.seed
	ks := key_space_make(keys)
	committed := make(Model, keys, context.temp_allocator)
	working := make(Model, keys, context.temp_allocator)
	value_buf := make([]byte, MODEL_MAX_VALUE, context.temp_allocator)
	ps := kv.DEFAULT_PAGE_SIZE
	threshold := kv.overflow_threshold(ps)

	env, err := kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	txn: kv.Txn
	defer kv.txn_abort(&txn)
	held: [MODEL_HELD_READERS]Held_Reader
	for &h in held {
		h.model = make(Model, keys, context.temp_allocator)
	}
	// Runs before env_close; ending a reader twice is harmless.
	defer for &h in held {
		kv.txn_abort(&h.txn)
	}
	in_txn := false
	begin_last: kv.Pgno
	txn_ops, txn_limit := 0, 0
	last_reopen := 0
	version: u32
	// The tide: whether the tree is being emptied, and the commit at which
	// a rising tide turns.
	falling := false
	tide_turn := 10 + rand.int_max(31)

	for op in 0 ..< ops {
		if !in_txn {
			txn, err = kv.txn_begin(env, read_only = false)
			if err != .None {
				testing.expectf(t, false, "[seed %d] op %d: txn_begin: %v", seed, op, err)
				return
			}
			copy(working, committed)
			in_txn = true
			txn_ops, txn_limit = 0, 1 + rand.int_max(500)
			begin_last = txn.snapshot.last_pgno
		}

		// Now and then a reader begins on the last commit and is held.
		if rand.int_max(500) == 0 {
			for &h in held[:max_held] {
				if h.txn.env != nil && !h.txn.done {
					continue
				}
				h.txn, err = kv.txn_begin(env)
				if err != .None {
					testing.expectf(t, false, "[seed %d] op %d: reader txn_begin: %v", seed, op, err)
					return
				}
				copy(h.model, committed)
				h.begun, h.release = stats.commits, stats.commits + 1 + rand.int_max(20)
				break
			}
		}

		id := rand.int_max(keys)
		put_pct := 10 if falling else 40
		switch r := rand.int_max(100); {
		case r < put_pct:
			key := ks.keys[id]
			max_inline := threshold - kv.leaf_node_size(len(key), 0, false)
			size: int
			switch s := rand.int_max(10); {
			case s < 7:
				size = rand.int_max(65)
			case s < 9:
				size = clamp(max_inline - 20 + rand.int_max(41), 0, MODEL_MAX_VALUE)
			case:
				size = min(max_inline + 1 + rand.int_max(3 * ps), MODEL_MAX_VALUE)
				stats.overflow_puts += 1
			}
			version += 1
			spec := Val_Spec{true, version, size}
			put_err := kv.put(&txn, key, model_value(id, spec, value_buf))
			if put_err == .Map_Full && txn.err != .None {
				// The up-front check must refuse a put before it changes
				// anything, reusable pages or not (KV-I-0002 REQ-007).
				testing.expectf(t, false, "[seed %d] op %d: put hit Map_Full part-way", seed, op)
				return
			}
			if put_err == .Map_Full && stop_on_map_full {
				kv.txn_abort(&txn)
				if !held_release(t, held[:], ks, value_buf, &stats, seed, all = true) {
					return
				}
				return stats, map_full_reopen(t, &env, path, options, ks, committed, value_buf, seed)
			}
			if put_err != .None {
				testing.expectf(t, false, "[seed %d] op %d: put: %v", seed, op, put_err)
				return
			}
			working[id] = spec
			stats.puts += 1

		case r < 50:
			if rand.int_max(5) != 0 {
				// A present key, if there is one.
				pos := next_present(ks, working, rand.int_max(keys), 1)
				if pos == keys {
					pos = next_present(ks, working, 0, 1)
				}
				if pos < keys {
					id = ks.sorted_ids[pos]
				}
			}
			del_err := kv.del(&txn, ks.keys[id])
			if del_err == .Map_Full && txn.err != .None {
				testing.expectf(t, false, "[seed %d] op %d: del hit Map_Full part-way", seed, op)
				return
			}
			if del_err == .Map_Full && stop_on_map_full {
				kv.txn_abort(&txn)
				if !held_release(t, held[:], ks, value_buf, &stats, seed, all = true) {
					return
				}
				return stats, map_full_reopen(t, &env, path, options, ks, committed, value_buf, seed)
			}
			want := kv.Error.None if working[id].present else kv.Error.Not_Found
			if del_err != want {
				testing.expectf(t, false, "[seed %d] op %d: del of id %d: %v, want %v", seed, op, id, del_err, want)
				return
			}
			if want == .None {
				working[id] = {}
				stats.dels += 1
			} else {
				stats.absent_dels += 1
			}

		case r < 75:
			got, get_err := kv.get(&txn, ks.keys[id])
			spec := working[id]
			ok := get_err == .Not_Found if !spec.present else get_err == .None && bytes.equal(got, model_value(id, spec, value_buf))
			if !ok {
				testing.expectf(t, false, "[seed %d] op %d: get of id %d: %v", seed, op, id, get_err)
				return
			}
			stats.gets += 1

		case:
			// Seek to an existing key or to random bytes.
			target := ks.keys[id]
			rnd: [9]byte
			if rand.int_max(2) == 0 {
				target = rnd[:1 + rand.int_max(len(rnd))]
				random_bytes(target)
			}
			forward := r < 90
			c := kv.cursor_open(&txn)
			key, _, seek_err := kv.cursor_seek(&c, target)
			pos := next_present(ks, working, lower_bound(ks, target), 1)
			for step in 0 ..< (20 if forward else 10) {
				want_found := pos >= 0 && pos < len(ks.sorted_ids)
				if want_found != (seek_err == .None) || (want_found && !bytes.equal(key, ks.keys[ks.sorted_ids[pos]])) {
					testing.expectf(t, false, "[seed %d] op %d: %s scan step %d differs", seed, op, "forward" if forward else "backward", step)
					return
				}
				if !want_found {
					break
				}
				if forward {
					key, _, seek_err = kv.cursor_next(&c)
					pos = next_present(ks, working, pos + 1, 1)
				} else {
					key, _, seek_err = kv.cursor_prev(&c)
					pos = next_present(ks, working, pos - 1, -1)
				}
			}
			stats.scans += 1
		}

		if !expect_pool_within(t, env) {
			return
		}
		txn_ops += 1
		if txn_ops < txn_limit && op < ops - 1 {
			continue
		}
		// Every page is accounted for in the write transaction too, with
		// the pages it freed or dropped.
		if ok, reason := kv.space_check(&txn, context.allocator); !ok {
			testing.expectf(t, false, "[seed %d] op %d: space_check before commit: %s", seed, op, reason)
			return
		}
		if rand.int_max(100) < 85 || op == ops - 1 {
			for pgno in written_pgnos(&txn) {
				if pgno <= begin_last {
					stats.reused_pages += 1
				}
			}
			commit_err := kv.txn_commit(&txn)
			if commit_err == .Map_Full && stop_on_map_full {
				// The commit's free-list run didn't fit (KV-I-0002 D6).
				if !held_release(t, held[:], ks, value_buf, &stats, seed, all = true) {
					return
				}
				return stats, map_full_reopen(t, &env, path, options, ks, committed, value_buf, seed)
			}
			if commit_err != .None {
				testing.expectf(t, false, "[seed %d] op %d: commit: %v", seed, op, commit_err)
				return
			}
			copy(committed, working)
			stats.commits += 1
			if model_count(committed) == 0 {
				stats.empty_commits += 1
			}
			// Turn the tide: a falling one once the tree is empty.
			if falling && (model_count(committed) == 0 || stats.commits >= tide_turn) {
				falling, tide_turn = false, stats.commits + 10 + rand.int_max(31)
			} else if tides && !falling && stats.commits >= tide_turn {
				falling, tide_turn = true, stats.commits + 200
			}
		} else {
			kv.txn_abort(&txn)
			stats.aborts += 1
		}
		in_txn = false
		if !verify_committed(t, env, ks, committed, value_buf, "after commit/abort", seed) {
			return
		}
		reopen := op - last_reopen >= 10_000
		if !held_release(t, held[:], ks, value_buf, &stats, seed, all = reopen) {
			return
		}

		if reopen {
			stats.spills += kv.env_stats(env).spills
			kv.env_close(env)
			env, err = kv.env_open(path, options)
			testing.expect_value(t, err, kv.Error.None)
			if err != .None {
				env = nil
				return
			}
			if !verify_committed(t, env, ks, committed, value_buf, "after reopen", seed) {
				return
			}
			last_reopen = op
			stats.reopens += 1
		}
	}
	stats.spills += kv.env_stats(env).spills
	return stats, false
}

// Checks the last commit with a new read transaction: model_compare, then
// space_check.
@(private = "file")
verify_committed :: proc(t: ^testing.T, env: ^kv.Env, ks: Key_Space, m: Model, buf: []byte, phase: string, seed: u64) -> bool {
	reader, err := kv.txn_begin(env)
	if err != .None {
		testing.expectf(t, false, "[seed %d] %s: txn_begin: %v", seed, phase, err)
		return false
	}
	defer kv.txn_abort(&reader)
	if !model_compare(t, &reader, ks, m, buf, phase, seed) {
		return false
	}
	if ok, reason := kv.space_check(&reader, context.allocator); !ok {
		testing.expectf(t, false, "[seed %d] %s: space_check: %s", seed, phase, reason)
		return false
	}
	return true
}

/*
Releases the held readers that are due (all of them with `all`), each
after checking that it still sees exactly the model it began at: every key
by `get`, full scans both ways, tree_check and space_check. Its snapshot's
free-list run and pages must all be intact, whatever was reused since.
*/
@(private = "file")
held_release :: proc(t: ^testing.T, held: []Held_Reader, ks: Key_Space, buf: []byte, stats: ^Model_Stats, seed: u64, all: bool) -> bool {
	for &h in held {
		if h.txn.env == nil || h.txn.done || (!all && h.release > stats.commits) {
			continue
		}
		defer kv.txn_abort(&h.txn)
		stats.held_readers += 1
		stats.held_commits += stats.commits - h.begun
		phase := "held reader on release"
		if !model_compare(t, &h.txn, ks, h.model, buf, phase, seed) {
			return false
		}
		if ok, reason := kv.space_check(&h.txn, context.allocator); !ok {
			testing.expectf(t, false, "[seed %d] %s: space_check: %s", seed, phase, reason)
			return false
		}
	}
	return true
}

// After a Map_Full with stop_on_map_full: reopens the database and checks
// that it is still at the last commit. The transaction has already ended.
@(private = "file")
map_full_reopen :: proc(t: ^testing.T, env: ^^kv.Env, path: string, options: kv.Options, ks: Key_Space, committed: Model, buf: []byte, seed: u64) -> bool {
	kv.env_close(env^)
	err: kv.Error
	env^, err = kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		env^ = nil
		return false
	}
	verify_committed(t, env^, ks, committed, buf, "after Map_Full and reopen", seed)
	return true
}

@(test)
test_model_randomized :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// Plenty of address space, so the run never hits Map_Full.
	stats, _ := run_model(t, temp_dir_file(dir, DB), kv.Options{map_size = 4 << 30}, ops = 100_000, keys = 3_000)
	log.infof("[seed %d] %v", t.seed, stats)

	// The run must actually exercise everything it claims to.
	testing.expect(t, stats.puts > 20_000 && stats.overflow_puts > 2_000, "too few puts")
	testing.expect(t, stats.dels > 10_000 && stats.absent_dels > 1_000, "too few deletes")
	// Falling tides emptied the tree, so it collapsed to nothing and grew
	// again from an empty root.
	testing.expect(t, stats.empty_commits >= 2, "the tree was never emptied")
	testing.expect(t, stats.commits > 100 && stats.aborts > 10, "too few commits or aborts")
	testing.expect(t, stats.reopens >= 5, "too few reopens")
	// Readers were held across commits while pages were being reused.
	testing.expect(t, stats.held_readers >= 50 && stats.held_commits >= 5 * stats.held_readers, "too few readers held")
	testing.expect(t, stats.reused_pages > 10_000, "too few pages reused")
}

// The same workload with the smallest dirty-page pool: transactions of up to
// 500 operations spill again and again, so pages are re-touched after being
// spilled, spilled pages and overflow runs are freed within the
// transaction, and aborts discard spilled pages (KV-I-0004 D4).
@(test)
test_model_randomized_min_pool :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	stats, _ := run_model(t, temp_dir_file(dir, DB), kv.Options{map_size = 4 << 30, dirty_budget = MIN_DIRTY_BUDGET}, ops = 100_000, keys = 3_000)
	log.infof("[seed %d] %v", t.seed, stats)
	testing.expect(t, stats.puts > 20_000 && stats.dels > 10_000, "too few changes")
	testing.expect(t, stats.commits > 100 && stats.aborts > 10, "too few commits or aborts")
	testing.expect(t, stats.spills > 1_000, "too few pages spilled")
}

@(test)
test_model_until_map_full :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// Pages are reused, so the map must be smaller than the data 2,000 keys
	// grow to, and the tide never falls. Deletes still run, 10% of
	// operations, so a delete can meet the full map as well as a put. At
	// 4 MiB it fills after 60–90 commits. No reader is held: one pins enough
	// pages to fill the map within 12–30 commits, before much is reused, and
	// filling it with reuse is what this test is for.
	stats, hit := run_model(t, temp_dir_file(dir, DB), kv.Options{map_size = 4 << 20}, ops = 200_000, keys = 2_000, stop_on_map_full = true, max_held = 0, tides = false)
	log.infof("[seed %d] %v", t.seed, stats)
	testing.expect(t, hit, "the map never filled")
	testing.expect(t, stats.commits > 0, "nothing was committed before the map filled")
}
