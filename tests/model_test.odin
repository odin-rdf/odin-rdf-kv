package kv_tests

import "core:bytes"
import "core:log"
import "core:math/rand"
import "core:testing"

import kv "../kv"

Model_Stats :: struct {
	puts, overflow_puts, gets, scans, commits, aborts, reopens: int,
}

/*
Runs `ops` random operations against the database at `path` and the model,
comparing after every commit and reopen. Stops early (returning true) when
`stop_on_map_full` is set and a put hits Map_Full, after aborting, reopening
and checking that the database is still at the last commit.

The workload:
- 45% put, a new key or an overwrite: 70% small values, 20% within a few
  bytes of the inline/overflow boundary, 10% overflow values of up to 3
  pages;
- 30% get, of present and absent keys;
- 15% forward range scan: seek (to a key or random bytes), then up to 20
  nexts;
- 10% backward walk: seek, then up to 10 prevs.

Transactions last 1–500 operations; 85% commit and 15% abort. The database
is closed and reopened about every 10,000 operations.
*/
run_model :: proc(t: ^testing.T, path: string, options: kv.Options, ops: int, keys: int, stop_on_map_full := false) -> (stats: Model_Stats, hit_map_full: bool) {
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
	in_txn := false
	txn_ops, txn_limit := 0, 0
	last_reopen := 0
	version: u32

	verify_committed :: proc(t: ^testing.T, env: ^kv.Env, ks: Key_Space, m: Model, buf: []byte, phase: string, seed: u64) -> bool {
		reader, err := kv.txn_begin(env)
		if err != .None {
			testing.expectf(t, false, "[seed %d] %s: txn_begin: %v", seed, phase, err)
			return false
		}
		defer kv.txn_abort(&reader)
		return model_compare(t, &reader, ks, m, buf, phase, seed)
	}

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
		}

		id := rand.int_max(keys)
		switch r := rand.int_max(100); {
		case r < 45:
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
			if put_err == .Map_Full && stop_on_map_full {
				// Abort, reopen, and check the last commit is intact.
				kv.txn_abort(&txn)
				kv.env_close(env)
				env, err = kv.env_open(path, options)
				testing.expect_value(t, err, kv.Error.None)
				if err != .None {
					env = nil
					return
				}
				verify_committed(t, env, ks, committed, value_buf, "after Map_Full and reopen", seed)
				return stats, true
			}
			if put_err != .None {
				testing.expectf(t, false, "[seed %d] op %d: put: %v", seed, op, put_err)
				return
			}
			working[id] = spec
			stats.puts += 1

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

		txn_ops += 1
		if txn_ops < txn_limit && op < ops - 1 {
			continue
		}
		if rand.int_max(100) < 85 || op == ops - 1 {
			if commit_err := kv.txn_commit(&txn); commit_err != .None {
				testing.expectf(t, false, "[seed %d] op %d: commit: %v", seed, op, commit_err)
				return
			}
			copy(committed, working)
			stats.commits += 1
		} else {
			kv.txn_abort(&txn)
			stats.aborts += 1
		}
		in_txn = false
		if !verify_committed(t, env, ks, committed, value_buf, "after commit/abort", seed) {
			return
		}

		if op - last_reopen >= 10_000 {
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
	return stats, false
}

@(test)
test_model_randomized :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// Without page reuse the file grows with every commit, so reserve
	// plenty of address space.
	stats, _ := run_model(t, temp_dir_file(dir, DB), kv.Options{map_size = 4 << 30}, ops = 100_000, keys = 3_000)
	log.infof("[seed %d] %v", t.seed, stats)

	// The run must actually exercise everything it claims to.
	testing.expect(t, stats.puts > 40_000 && stats.overflow_puts > 3_000, "too few puts")
	testing.expect(t, stats.commits > 100 && stats.aborts > 10, "too few commits or aborts")
	testing.expect(t, stats.reopens >= 5, "too few reopens")
}

@(test)
test_model_until_map_full :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	stats, hit := run_model(t, temp_dir_file(dir, DB), kv.Options{map_size = 8 << 20}, ops = 200_000, keys = 2_000, stop_on_map_full = true)
	log.infof("[seed %d] %v", t.seed, stats)
	testing.expect(t, hit, "the map never filled")
	testing.expect(t, stats.commits > 0, "nothing was committed before the map filled")
}
