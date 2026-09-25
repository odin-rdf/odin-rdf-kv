package kv_tests

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:testing"

import kv "../kv"

/*
Poisoning after a failed sync or meta-page write (KV-I-0005 D7,
KV-T-0030). Only registered in a build with `-define:KV_IO_HOOK=true`,
which injects the failure through the journal (see crash.odin).

A commit on a baseline of three commits (so the env's free list has
reusable pages as well as the end of the file) fails at its first sync, its
meta-page write or its final sync. Then: the commit returns the error,
env_stats reports the flag, the next txn_begin(rw) returns Poisoned, a
reader begun afterwards sees the previous commit, env_sweep and env_close
work, and a reopen is at the previous commit, or at the failed one if its
meta page reached the file, passing crash_image_check (the checks, one more
commit, a reopen at it).

After the final sync fails, the test goes on as a store without poisoning
would, if txn_begin(rw) is not refused: a second transaction makes
different changes, reusing the pages the failed commit wrote into, and
commits; the kill image cut just before its meta-page write must then open
at the failed commit's state. It can't (KV-T-0030 records the failure), so
the refusal is what keeps a durable meta page from pointing at overwritten
pages.
*/
when kv.IO_HOOK {
	@(test)
	test_poison_first_sync :: proc(t: ^testing.T) {
		poison(t, .First_Sync)
	}

	@(test)
	test_poison_meta_write :: proc(t: ^testing.T) {
		poison(t, .Meta_Write)
	}

	@(test)
	test_poison_final_sync :: proc(t: ^testing.T) {
		poison(t, .Final_Sync)
	}

	// A failure before the first sync (a data-page write) doesn't poison:
	// nothing durable refers to what was written.
	@(test)
	test_poison_not_before_sync :: proc(t: ^testing.T) {
		poison(t, .Before_Sync)
	}
}

// Where the commit fails. The last three are its last three operations.
@(private = "file")
Poison_Point :: enum {
	Before_Sync,
	First_Sync,
	Meta_Write,
	Final_Sync,
}

@(private = "file")
POISON_KEYS :: 300

/*
Builds the baseline at `path` (removed first, so a dry run and the real run
are identical): three commits, the last two overwriting a third of the keys
each. Returns the env open with the journal started (crash_baseline).
*/
@(private = "file")
poison_baseline :: proc(t: ^testing.T, path: string, run: ^Crash_Run, name: string) -> (env: ^kv.Env, ok: bool) {
	crash_run_init(run, name, key_space_make(POISON_KEYS))
	file_remove(path)
	err: kv.Error
	env, err = kv.env_open(path)
	if !testing.expect_value(t, err, kv.Error.None) {
		return nil, false
	}
	for round in 0 ..< 3 {
		txn, _ := kv.txn_begin(env, read_only = false)
		for id in 0 ..< POISON_KEYS {
			if (round == 0 && id % 8 != 0) || (round > 0 && id % 3 == round) {
				crash_put(&txn, run, id, 50 + (id + round) * 37 % 250)
			}
		}
		if !commit_ok(t, env, &txn) {
			kv.env_close(env)
			return nil, false
		}
	}
	if !crash_baseline(t, run, env, path) {
		kv.env_close(env)
		return nil, false
	}
	return env, true
}

// The failed commit's changes: new keys and overwrites spread over the
// leaves.
@(private = "file")
poison_changes_failed :: proc(txn: ^kv.Txn, run: ^Crash_Run) -> kv.Error {
	for i in 0 ..< 12 {
		crash_put(txn, run, i * POISON_KEYS / 12 + 3, 180) or_return
	}
	return .None
}

// The second transaction's changes: other keys, other sizes, and deletes,
// so the pages it writes differ from the failed commit's.
@(private = "file")
poison_changes_next :: proc(txn: ^kv.Txn, run: ^Crash_Run) -> kv.Error {
	for i in 0 ..< 12 {
		id := i * POISON_KEYS / 12 + 7
		if i % 3 == 0 {
			if err := crash_del(txn, run, id); err != .None && err != .Not_Found {
				return err
			}
		} else {
			crash_put(txn, run, id, 60) or_return
		}
	}
	return .None
}

@(private = "file")
poison :: proc(t: ^testing.T, point: Poison_Point) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "db", "image")
	path := strings.clone(temp_dir_file(dir, "db"), context.temp_allocator)
	image := strings.clone(temp_dir_file(dir, "image"), context.temp_allocator)
	name := fmt.tprintf("poison at %v", point)

	// The dry run: the failed commit's operations, performed.
	first, last: int
	{
		dry: Crash_Run
		defer crash_run_destroy(&dry)
		env, ok := poison_baseline(t, path, &dry, name)
		if !ok {
			return
		}
		txn, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, poison_changes_failed(&txn, &dry), kv.Error.None)
		// Overflow values are written at put: the commit's own start here.
		commit_first := len(dry.journal.ops)
		ok = crash_commit(t, &dry, env, &txn)
		crash_finish(&dry, env)
		if !ok {
			return
		}
		ops := dry.journal.ops[:]
		n := len(ops)
		// The shape KV-T-0026 pinned: data pages, sync, meta page, sync.
		if !testing.expectf(t, n >= 5 && ops[n - 3].kind == .Sync && ops[n - 1].kind == .Sync, "%s: the commit's journal ends %v", name, ops[max(n - 3, 0):]) {
			return
		}
		_, is_meta := record_meta_txn_id(ops[n - 2])
		testing.expect(t, is_meta, "the commit's last write isn't its meta page")
		switch point {
		case .Before_Sync:
			// Every operation of the commit before its first sync: the
			// free-list run, the data pages, a truncate if the file grows.
			first, last = commit_first, n - 4
			testing.expectf(t, n - 3 - commit_first >= 3, "%s: the commit has %d operations before its first sync", name, n - 3 - commit_first)
		case .First_Sync:
			first, last = n - 3, n - 3
		case .Meta_Write:
			first, last = n - 2, n - 2
		case .Final_Sync:
			first, last = n - 1, n - 1
		}
	}
	for fail_at in first ..= last {
		poison_at(t, path, image, fmt.tprintf("%s (operation %d)", name, fail_at), point, fail_at) or_break
	}
}

// Fails operation `fail_at` of the commit and checks what follows; see
// the file's comment.
@(private = "file")
poison_at :: proc(t: ^testing.T, path, image, name: string, point: Poison_Point, fail_at: int) -> bool {
	run: Crash_Run
	defer crash_run_destroy(&run)
	env, ok := poison_baseline(t, path, &run, name)
	if !ok {
		return false
	}
	prev := run.base_txn
	run.journal.fail_at, run.journal.fail_with = fail_at, .Io
	txn, _ := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, poison_changes_failed(&txn, &run), kv.Error.None)
	err := kv.txn_commit(&txn)
	testing.expectf(t, err == .Io, "%s: txn_commit returned %v", name, err)
	// states[1]: what the failed commit would have committed as prev + 1.
	append(&run.states, slice.clone(run.model))
	testing.expect_value(t, kv.env_snapshot(env).txn_id, prev)

	poisoned := point != .Before_Sync
	testing.expectf(t, kv.env_stats(env).poisoned == poisoned, "%s: Stats.poisoned is %v", name, !poisoned)

	// Read transactions and the rest of the env carry on, at prev.
	value_buf := make([]byte, 4096, context.temp_allocator)
	reader, rerr := kv.txn_begin(env)
	if testing.expect_value(t, rerr, kv.Error.None) {
		testing.expect_value(t, reader.snapshot.txn_id, prev)
		if diff := model_diff(&reader, run.ks, run.states[0], value_buf); diff != "" {
			testing.expectf(t, false, "%s: a reader after the failure: %s", name, diff)
		}
		kv.txn_abort(&reader)
	}
	kv.env_sweep(env, 0)
	testing.expect_value(t, kv.env_stats(env).resident_chunks, 0)

	next, nerr := kv.txn_begin(env, read_only = false)
	if !poisoned {
		// Nothing durable refers to the pages written: the env commits on.
		ok = testing.expect_value(t, nerr, kv.Error.None)
		if ok {
			ok = testing.expect_value(t, poison_changes_next(&next, &run), kv.Error.None)
			run.journal.fail_at = -1
			ok &= testing.expect_value(t, kv.txn_commit(&next), kv.Error.None)
		}
		crash_finish(&run, env)
		env, err = kv.env_open(path)
		if !testing.expect_value(t, err, kv.Error.None) {
			return false
		}
		defer kv.env_close(env)
		return ok && testing.expect_value(t, kv.env_snapshot(env).txn_id, prev + 1)
	}
	if nerr == .Poisoned {
		// Still refused on a second try, and still unaffecting readers.
		_, nerr = kv.txn_begin(env, read_only = false)
		testing.expect_value(t, nerr, kv.Error.Poisoned)
		crash_finish(&run, env)
		// The hooked build fails a meta write without performing it, so
		// the failed commit's meta page is in the file exactly when the
		// final sync failed.
		want := prev + 1 if point == .Final_Sync else prev
		return crash_image_check(t, &run, path, {want}, "reopened after the failure")
	}

	testing.expectf(t, false, "%s: txn_begin(rw) after the failure returned %v, want Poisoned", name, nerr)
	if nerr != .None || point != .Final_Sync {
		// After a failed first sync or meta write, the hooked build leaves
		// no meta page to point at the reused pages: the hazard there is
		// pages the kernel dropped, which no image here models.
		kv.txn_abort(&next)
		crash_finish(&run, env)
		return false
	}
	// Poisoning is missing: what it prevents. The second transaction
	// commits into the pages the failed commit wrote, and a kill just
	// before its meta-page write leaves the failed commit's meta page
	// pointing at them.
	start := len(run.journal.ops)
	testing.expect_value(t, poison_changes_next(&next, &run), kv.Error.None)
	run.journal.fail_at = -1
	testing.expect_value(t, kv.txn_commit(&next), kv.Error.None)
	crash_finish(&run, env)
	cut := -1
	#reverse for r, i in run.journal.ops[start:] {
		if _, is_meta := record_meta_txn_id(r); is_meta {
			cut = start + i
			break
		}
	}
	if !testing.expect(t, cut > start, "the second transaction wrote no meta page") {
		return false
	}
	if !testing.expect(t, journal_image_kill(run.base, run.journal, cut, image), "writing the image") {
		return false
	}
	testing.expect_value(t, crash_kill_txn(&run, cut), prev + 1)
	// Pages both transactions wrote, past the meta pages: the overwrite.
	ps := i64(run.page_size)
	failed_pages := make(map[i64]bool, context.temp_allocator)
	for r in run.journal.ops[:start] {
		if r.kind == .Write && r.offset >= 2 * ps {
			for p in 0 ..< i64(len(r.bytes)) / ps {
				failed_pages[r.offset / ps + p] = true
			}
		}
	}
	overwritten, written := 0, 0
	for r in run.journal.ops[start:cut] {
		if r.kind == .Write && r.offset >= 2 * ps {
			for p in 0 ..< i64(len(r.bytes)) / ps {
				written += 1
				overwritten += int(failed_pages[r.offset / ps + p])
			}
		}
	}
	log.infof("%s, unpoisoned: the next transaction wrote %d pages, %d of them written by the failed commit (of %d)", name, written, overwritten, len(failed_pages))
	crash_image_check(t, &run, image, {prev + 1}, "killed before the next commit's meta page, unpoisoned")
	return false
}
