package kv_tests

import "core:encoding/endian"
import "core:log"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import kv "../kv"

/*
The crash sweeps (KV-I-0005 D1, D2, D8, KV-T-0027, KV-T-0028): workloads
1–4 of the initiative's design, each swept cut by cut with process kills
(crash_sweep_kill) and power losses (crash_sweep_power, see crash.odin).
Only registered in a build with `-define:KV_IO_HOOK=true`; scripts/test.sh
runs one, with KV_NO_SYNC. `-define:KV_CRASH=true` selects larger trees,
and `-define:KV_CRASH_SUBSETS=n` the random power-loss subsets per window
(default 16).

Each workload asserts that it did what it is named for, so a change that
stops a commit spilling, say, fails here rather than quietly sweeping less.
*/
when kv.IO_HOOK {
	@(test)
	test_crash_kill_puts :: proc(t: ^testing.T) {
		crash_kill(t, crash_workload_puts)
	}

	@(test)
	test_crash_kill_spill :: proc(t: ^testing.T) {
		s, ok := crash_kill(t, crash_workload_spill)
		// KV-I-0005 D8: the file grew during the transaction, and the cut
		// right after its truncate opened like any other.
		testing.expectf(t, !ok || s.after_truncate > 0, "no cut after a truncate")
	}

	@(test)
	test_crash_kill_deletes :: proc(t: ^testing.T) {
		crash_kill(t, crash_workload_deletes)
	}

	@(test)
	test_crash_kill_reuse :: proc(t: ^testing.T) {
		crash_kill(t, crash_workload_reuse)
	}

	@(test)
	test_crash_power_puts :: proc(t: ^testing.T) {
		crash_power(t, crash_workload_puts)
	}

	@(test)
	test_crash_power_spill :: proc(t: ^testing.T) {
		crash_power(t, crash_workload_spill)
	}

	@(test)
	test_crash_power_deletes :: proc(t: ^testing.T) {
		crash_power(t, crash_workload_deletes)
	}

	@(test)
	test_crash_power_reuse :: proc(t: ^testing.T) {
		crash_power(t, crash_workload_reuse)
	}

	// Workload 5 (KV-I-0005 D6, KV-T-0029): creation, at the default page
	// size and at 16 KiB. A kill image is no file, two zero pages, or one
	// or both meta pages whole: each opens as an empty database. Six cuts:
	// the baseline and one after each of the five operations, the sync
	// after the truncate (KV-T-0035) included.
	@(test)
	test_crash_kill_create :: proc(t: ^testing.T) {
		for w in ([]Crash_Workload{crash_workload_create, crash_workload_create_16k}) {
			s, ok := crash_kill(t, w)
			testing.expectf(t, !ok || s.after_truncate == 1, "%d cuts after a truncate, want the one of creation", s.after_truncate)
			testing.expectf(t, !ok || s.cuts == 6, "%d cuts, want 6", s.cuts)
		}
	}

	@(test)
	test_crash_power_create :: proc(t: ^testing.T) {
		for w in ([]Crash_Workload{crash_workload_create, crash_workload_create_16k}) {
			run: Crash_Run
			start := time.tick_now()
			s, ok := crash_sweep(t, w, &run, crash_sweep_create_power)
			log.infof("%s: power loss during creation: %d images over %d windows, %d refused as Corrupted (%d a torn meta page on two pages, %d with the truncate lost), in %v",
				run.name, s.images, s.windows, s.refused_torn + s.refused_short, s.refused_torn, s.refused_short, time.tick_since(start))
			// The sync after the truncate (KV-T-0035): a power loss never
			// keeps a meta write while losing the sizing, so the only images
			// refused are a meta write torn with neither whole, which the
			// sector-atomicity question decides (KV-T-0038) and the sweep
			// still pins.
			testing.expectf(t, !ok || s.refused_short == 0, "%s: %d images with a meta write kept and the truncate lost", run.name, s.refused_short)
			testing.expectf(t, !ok || s.refused_torn > 0, "%s: no image with a torn meta write refused", run.name)
			crash_run_destroy(&run)
		}
	}
}

// Larger trees for the sweep, on demand.
CRASH :: #config(KV_CRASH, false)

// A workload for the crash sweeps: builds a database at `path`, takes the
// baseline and makes its commits into `run` (see crash.odin), and checks
// that it exercised what it is named for.
Crash_Workload :: #type proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool

// Runs `workload` and sweeps process kills over its journal.
crash_kill :: proc(t: ^testing.T, workload: Crash_Workload) -> (s: Crash_Sweep, ok: bool) {
	run: Crash_Run
	defer crash_run_destroy(&run)
	start := time.tick_now()
	s, ok = crash_sweep(t, workload, &run, crash_sweep_kill)
	log.infof("%s: %d cuts over %d commits (%d after a truncate, %d at a workload commit) in %v",
		run.name, s.cuts, len(run.commits), s.after_truncate, s.committed, time.tick_since(start))
	return s, ok
}

// Runs `workload` and sweeps power losses over its journal.
crash_power :: proc(t: ^testing.T, workload: Crash_Workload) -> (s: Crash_Sweep, ok: bool) {
	run: Crash_Run
	defer crash_run_destroy(&run)
	start := time.tick_now()
	s, ok = crash_sweep(t, workload, &run, crash_sweep_power)
	log.infof("%s: power loss at %d cuts over %d commits, %d with unsynced writes: %d images (%d at a workload commit), %d meta-corruption images, in %v",
		run.name, s.cuts, len(run.commits), s.windows, s.images, s.committed, s.corrupt, time.tick_since(start))
	return s, ok
}

// Runs `workload` into `run` in a temporary directory, then `sweep`.
@(private = "file")
crash_sweep :: proc(t: ^testing.T, workload: Crash_Workload, run: ^Crash_Run, sweep: proc(t: ^testing.T, run: ^Crash_Run, path: string) -> (Crash_Sweep, bool)) -> (s: Crash_Sweep, ok: bool) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "db", "image")
	path := strings.clone(temp_dir_file(dir, "db"), context.temp_allocator)
	image := strings.clone(temp_dir_file(dir, "image"), context.temp_allocator)
	if !workload(t, path, run) {
		return s, false
	}
	return sweep(t, run, image)
}

// A key space of 8-byte big-endian keys 0 ..< n, for workloads that need to
// know which keys share a leaf.
@(private = "file")
crash_u64_keys :: proc(n: int) -> Key_Space {
	ks := Key_Space {
		keys       = make([][]byte, n, context.temp_allocator),
		sorted_ids = make([]int, n, context.temp_allocator),
	}
	for id in 0 ..< n {
		ks.keys[id] = make([]byte, 8, context.temp_allocator)
		endian.put_u64(ks.keys[id], .Big, u64(id))
		ks.sorted_ids[id] = id
	}
	return ks
}

// The ids of each leaf of a tree over crash_u64_keys, left to right.
@(private = "file")
crash_leaves :: proc(txn: ^kv.Txn, pgno: kv.Pgno, leaves: ^[dynamic][]int) {
	page := kv.page_ptr(txn, pgno)
	n := kv.page_num_keys(page)
	if kv.page_is_leaf(page) {
		ids := make([]int, n, context.temp_allocator)
		for &id, i in ids {
			v, _ := endian.get_u64(kv.node_key(page, i), .Big)
			id = int(v)
		}
		append(leaves, ids)
		return
	}
	for i in 0 ..< n {
		crash_leaves(txn, kv.branch_child(page, i), leaves)
	}
}

// Opens the workload's env, failing the test if it can't.
@(private = "file")
crash_open :: proc(t: ^testing.T, path: string, options := kv.Options{}) -> (env: ^kv.Env, ok: bool) {
	err: kv.Error
	env, err = kv.env_open(path, options)
	return env, testing.expect_value(t, err, kv.Error.None)
}

// Pages of whole-page writes of `run`'s commit `c` past the meta pages, and
// of those, pages at or below the last page of the snapshot it began from
// (reused).
@(private = "file")
crash_commit_pages :: proc(run: ^Crash_Run, c: Crash_Commit) -> (written, reused: int) {
	ps := i64(run.page_size)
	for r in run.journal.ops[c.first:c.end] {
		if r.kind != .Write || r.offset < 2 * ps {
			continue
		}
		for p in 0 ..< i64(len(r.bytes)) / ps {
			written += 1
			reused += int(kv.Pgno(r.offset / ps + p) <= c.prev_last)
		}
	}
	return
}

/*
Workload 1: a few puts on a committed tree of several levels, new keys and
overwrites spread over its leaves: the plain commit order.
*/
@(private = "file")
crash_workload_puts :: proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool {
	n := 3000 if CRASH else 300
	crash_run_init(run, "puts", key_space_make(n))
	env := crash_open(t, path) or_return

	crash_pre_baseline(run)
	txn, _ := kv.txn_begin(env, read_only = false)
	for id in 0 ..< n {
		if id % 8 != 0 && crash_put(&txn, run, id, 50 + id * 37 % 250) != .None {
			testing.expectf(t, false, "baseline put %d failed", id)
			kv.txn_abort(&txn)
			kv.env_close(env)
			return false
		}
	}
	if !commit_ok(t, env, &txn) || !testing.expect(t, kv.env_snapshot(env).depth >= 2, "the baseline tree is a single leaf") {
		kv.env_close(env)
		return false
	}
	if !crash_baseline(t, run, env, path) {
		kv.env_close(env)
		return false
	}
	defer crash_finish(run, env)

	txn, _ = kv.txn_begin(env, read_only = false)
	for i in 0 ..< 8 {
		if crash_put(&txn, run, i * n / 8 + i, 120) != .None {
			testing.expectf(t, false, "put %d failed", i)
			kv.txn_abort(&txn)
			return false
		}
	}
	crash_commit(t, run, env, &txn) or_return
	written, _ := crash_commit_pages(run, run.commits[0])
	return testing.expectf(t, written >= 3, "the commit wrote %d pages: a leaf, the root and the free list at least", written)
}

/*
Workload 2: one commit with the smallest pool that spills while its puts
run, with overflow values written straight to the file, and whose free
list is long enough for a run of several pages (written a page at a time
by freelist_write). The baseline frees a large overflow value in its last
commit, so its pages stay pending through the workload's commit (the reuse
horizon keeps them), and the transaction's pages come from the end of the
file. The baseline is built with a small map, which caps the file's growth
steps, so the file has little room left past its last page and grows while
the transaction spills (KV-I-0005 D8).
*/
@(private = "file")
crash_workload_spill :: proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool {
	base_keys, new_keys := 40, 2000 if CRASH else 280
	// A free-list page holds 255 records.
	big_pages := 260
	big := base_keys + new_keys
	crash_run_init(run, "spill", crash_u64_keys(big + 1))
	ps := kv.DEFAULT_PAGE_SIZE
	env := crash_open(t, path, {dirty_budget = MIN_DIRTY_BUDGET, map_size = (big_pages + 60) * ps}) or_return

	txn, _ := kv.txn_begin(env, read_only = false)
	for id in 0 ..< base_keys {
		crash_put(&txn, run, id, 200)
	}
	crash_put(&txn, run, big, big_pages * ps)
	ok := commit_ok(t, env, &txn)
	if ok {
		crash_pre_baseline(run)
		txn, _ = kv.txn_begin(env, read_only = false)
		crash_del(&txn, run, big)
		ok = commit_ok(t, env, &txn)
	}
	kv.env_close(env)
	if !ok {
		return false
	}
	env = crash_open(t, path, {dirty_budget = MIN_DIRTY_BUDGET}) or_return
	room := kv.env_stats(env).file_pages - int(kv.env_snapshot(env).last_pgno) - 1
	if !testing.expectf(t, room < new_keys / 4, "the baseline file has room for %d more pages", room) || !crash_baseline(t, run, env, path) {
		kv.env_close(env)
		return false
	}
	defer crash_finish(run, env)

	overflow_id := -1
	txn, _ = kv.txn_begin(env, read_only = false)
	for i in 0 ..< new_keys {
		id := base_keys + i
		size := 1000
		if i % 25 == 7 {
			size, overflow_id = 3 * ps, id
		}
		if crash_put(&txn, run, id, size) != .None {
			testing.expectf(t, false, "put %d failed", id)
			kv.txn_abort(&txn)
			return false
		}
	}
	crash_commit(t, run, env, &txn) or_return

	c := run.commits[0]
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	run_len := freelist_run_len(t, env, reader.snapshot)
	ok = testing.expectf(t, c.spills > 0, "the transaction spilled nothing")
	ok &= testing.expect(t, is_overflow(&reader, run.ks.keys[overflow_id]), "no overflow value")
	ok &= testing.expectf(t, run_len > 1, "the free-list run has %d pages", run_len)
	return ok
}

/*
Workload 3: deletes that merge leaves and collapse the root. Every leaf of
the committed tree loses all its keys but its first, so none empties: each
page that goes away was merged into a sibling.
*/
@(private = "file")
crash_workload_deletes :: proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool {
	n := 3000 if CRASH else 60
	crash_run_init(run, "deletes", crash_u64_keys(n))
	env := crash_open(t, path) or_return

	crash_pre_baseline(run)
	txn, _ := kv.txn_begin(env, read_only = false)
	for id in 0 ..< n {
		crash_put(&txn, run, id, SHAPE_VAL)
	}
	if !commit_ok(t, env, &txn) || !crash_baseline(t, run, env, path) {
		kv.env_close(env)
		return false
	}
	defer crash_finish(run, env)

	leaves := make([dynamic][]int, context.temp_allocator)
	txn, _ = kv.txn_begin(env, read_only = false)
	depth := txn.snapshot.depth
	crash_leaves(&txn, txn.snapshot.root, &leaves)
	for ids in leaves {
		for id in ids[1:] {
			if crash_del(&txn, run, id) != .None {
				testing.expectf(t, false, "delete %d failed", id)
				kv.txn_abort(&txn)
				return false
			}
		}
	}
	crash_commit(t, run, env, &txn) or_return

	after := make([dynamic][]int, context.temp_allocator)
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	crash_leaves(&reader, reader.snapshot.root, &after)
	ok := testing.expectf(t, len(after) < len(leaves), "%d leaves before the deletes, %d after: nothing merged", len(leaves), len(after))
	ok &= testing.expectf(t, reader.snapshot.depth < depth, "depth %d before the deletes, %d after: the root didn't collapse", depth, reader.snapshot.depth)
	return ok
}

/*
Workload 4: three commits in a row, each overwriting a third of the keys
and moving a few, on a baseline whose earlier commits left reusable pages:
every commit writes into reused pages, so a cut in the second or third
lands on a file where pages of older snapshots are being overwritten
(KV-I-0002 D1).
*/
@(private = "file")
crash_workload_reuse :: proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool {
	n := 3000 if CRASH else 150
	crash_run_init(run, "reuse", key_space_make(n))
	env := crash_open(t, path) or_return

	ok := true
	for round in 0 ..< 3 {
		if round == 2 {
			crash_pre_baseline(run)
		}
		txn, _ := kv.txn_begin(env, read_only = false)
		for id in 0 ..< n {
			if (round == 0 && id % 11 != 0) || (round > 0 && id % 3 == round) {
				crash_put(&txn, run, id, 40 + (id + round) * 29 % 200)
			}
		}
		if ok = commit_ok(t, env, &txn); !ok {
			break
		}
	}
	if !ok || !crash_baseline(t, run, env, path) {
		kv.env_close(env)
		return false
	}
	defer crash_finish(run, env)

	for round in 0 ..< 3 {
		txn, _ := kv.txn_begin(env, read_only = false)
		for id in 0 ..< n {
			err := kv.Error.None
			switch {
			case id % 11 == round + 1:
				err = crash_put(&txn, run, id, 90)
			case id % 3 == round:
				err = crash_put(&txn, run, id, 30 + (id + round) * 53 % 220)
			case id % 13 == round:
				err = crash_del(&txn, run, id)
			}
			if err != .None && err != .Not_Found {
				testing.expectf(t, false, "round %d, key %d: %v", round, id, err)
				kv.txn_abort(&txn)
				return false
			}
		}
		crash_commit(t, run, env, &txn) or_return
	}
	for c, i in run.commits {
		written, reused := crash_commit_pages(run, c)
		ok &= testing.expectf(t, reused > 0, "commit %d wrote %d pages, none of them reused", i + 1, written)
	}
	return ok
}

/*
Workload 5: env_open of a path with no file (KV-I-0005 D6). The baseline
is no file, the state the empty database at txn 0, and the journal
env_open's truncate, sync, two meta writes and sync. The images are opened at
the page size the database was created at (Crash_Run.options), since the
D6 rule is at the page size of the open.
*/
@(private = "file")
crash_workload_create :: proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool {
	return crash_create(t, path, run, "create", kv.DEFAULT_PAGE_SIZE)
}

@(private = "file")
crash_workload_create_16k :: proc(t: ^testing.T, path: string, run: ^Crash_Run) -> bool {
	return crash_create(t, path, run, "create 16k", 16384)
}

@(private = "file")
crash_create :: proc(t: ^testing.T, path: string, run: ^Crash_Run, name: string, page_size: int) -> bool {
	crash_run_init(run, name, crash_u64_keys(1))
	run.options = {page_size = page_size}
	run.page_size = page_size
	file_remove(path)
	ok: bool
	run.base, ok = baseline_take(path)
	if !testing.expectf(t, ok && !run.base.exists, "%s: a baseline of no file", name) {
		return false
	}
	append(&run.states, slice.clone(run.model))
	journal_start(&run.journal)
	env := crash_open(t, path, run.options) or_else nil
	if env == nil {
		journal_stop()
		return false
	}
	crash_finish(run, env)
	// The journal's shape is the sweeps' to check: the kill sweep counts
	// its cuts (the sync after the truncate, KV-T-0035, is one of them),
	// and the power sweep takes its windows from the syncs, so creation
	// without that sync still reaches it and shows what it costs.
	return true
}
