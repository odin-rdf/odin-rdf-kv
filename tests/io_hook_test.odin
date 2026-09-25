package kv_tests

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:thread"

import kv "../kv"

/*
The I/O hook and the journal (KV-I-0005 D1, D3, KV-T-0026). Only
registered in a build with `-define:KV_IO_HOOK=true` (scripts/test.sh runs
one, with KV_NO_SYNC as well); the procedures compile in every build.
test_no_sync_skips_call is registered in every build.
*/
when kv.IO_HOOK {
	@(test)
	test_journal_commit_shape :: proc(t: ^testing.T) {
		journal_commit_shape(t)
	}

	@(test)
	test_journal_spill_overflow_before_sync :: proc(t: ^testing.T) {
		journal_spill_overflow_before_sync(t)
	}

	@(test)
	test_journal_kill_image_is_file :: proc(t: ^testing.T) {
		journal_kill_image_is_file(t)
	}

	@(test)
	test_io_hook_fails_operation :: proc(t: ^testing.T) {
		io_hook_fails_operation(t)
	}

	@(test)
	test_io_hook_per_thread :: proc(t: ^testing.T) {
		io_hook_per_thread(t)
	}
}

/*
Under NO_SYNC, os_sync makes no system call: a sync of a file descriptor
that isn't open succeeds, where the real call fails with EBADF. That is the
check that needs neither timing nor a syscall tracer, and it holds on both
platforms. Without NO_SYNC the same call must fail, so the check can't pass
vacuously. The journal still records the sync (test_journal_commit_shape
counts two per commit).
*/
@(test)
test_no_sync_skips_call :: proc(t: ^testing.T) {
	want := kv.Error.None if kv.NO_SYNC else kv.Error.Io
	testing.expect_value(t, kv.os_sync(-1), want)
}

// Keys 0, 2, 4, … in a committed tree of several leaves.
@(private = "file")
HOOK_TREE_KEYS :: 600

// Puts `n` keys spread over the tree built from even_entries, each into a
// different leaf, so the commit writes several data pages.
@(private = "file")
hook_put_spread :: proc(txn: ^kv.Txn, n: int) -> kv.Error {
	for i in 0 ..< n {
		key: [8]byte
		kv.put(txn, u64_key(&key, u64(2 * (i * HOOK_TREE_KEYS / n) + 1)), transmute([]byte)fmt.tprintf("new%d", i)) or_return
	}
	return .None
}

// The txn_id of the meta page a recorded write holds.
@(private = "file")
record_meta_txn_id :: proc(r: Io_Record) -> (txn_id: u64, ok: bool) {
	if r.kind != .Write || len(r.bytes) < kv.META_OFFSET + size_of(kv.Meta) {
		return 0, false
	}
	meta: kv.Meta
	mem.copy(&meta, &r.bytes[kv.META_OFFSET], size_of(kv.Meta))
	return u64(meta.txn_id), u32(meta.magic) == kv.MAGIC
}

/*
One commit on a committed tree: optionally a truncate (file growth), the
free-list run and the data pages, the latter in page order, then a sync,
one write of the meta page into slot txn_id & 1, and a sync. Nothing else.
*/
@(private = "file")
journal_commit_shape :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "db")
	path := temp_dir_file(dir, "db")
	build_tree_file(t, path, even_entries(HOOK_TREE_KEYS))

	env, err := kv.env_open(path)
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)
	ps := i64(env.page_size)

	j: Journal
	journal_start(&j)
	txn, _ := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, hook_put_spread(&txn, 8), kv.Error.None)
	testing.expect_value(t, len(j.ops), 0) // nothing spills with the default pool
	dirty := len(txn.write.dirty)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	journal_stop()
	defer journal_destroy(&j)

	snap := kv.env_snapshot(env)
	run := i64(snap.freelist_pgno)
	run_len := i64(freelist_run_len(t, env, snap))
	testing.expect(t, run_len > 0, "the commit freed pages, so it has a free-list run")

	ops := j.ops[:]
	n := len(ops)
	if !testing.expectf(t, n >= 4, "journal too short: %d operations", n) {
		return
	}
	// The tail: sync, meta page, sync.
	testing.expect_value(t, ops[n - 3].kind, kv.Io_Kind.Sync)
	testing.expect_value(t, ops[n - 1].kind, kv.Io_Kind.Sync)
	meta := ops[n - 2]
	testing.expect_value(t, meta.kind, kv.Io_Kind.Write)
	testing.expect_value(t, meta.offset, i64(snap.txn_id & 1) * ps)
	testing.expect(t, i64(len(meta.bytes)) < ps, "a meta page write is its header and meta, not the page")
	id, ok := record_meta_txn_id(meta)
	testing.expect(t, ok, "the meta page write holds no meta")
	testing.expect_value(t, id, u64(snap.txn_id))

	// The head: a truncate or page writes past the meta pages, data pages in
	// ascending order, and the whole free-list run.
	data_pages, run_pages := 0, i64(0)
	last := i64(-1)
	for r, i in ops[:n - 3] {
		switch r.kind {
		case .Sync:
			testing.expectf(t, false, "operation %d: a sync before the data pages are written", i)
		case .Truncate:
			testing.expectf(t, r.size % ps == 0 && r.size > 2 * ps, "operation %d: truncate to %d", i, r.size)
		case .Write:
			pgno := r.offset / ps
			testing.expectf(t, r.offset % ps == 0 && pgno >= 2 && i64(len(r.bytes)) % ps == 0,
				"operation %d: write of %d bytes at %d", i, len(r.bytes), r.offset)
			if pgno >= run && pgno < run + run_len {
				run_pages += i64(len(r.bytes)) / ps
				continue
			}
			testing.expectf(t, pgno > last, "operation %d: page %d written after page %d", i, pgno, last)
			last = pgno
			data_pages += 1
		}
	}
	testing.expect_value(t, run_pages, run_len)
	// Every dirty page once, and at least a leaf and the root.
	testing.expect_value(t, data_pages, dirty)
	testing.expectf(t, data_pages >= 2, "%d data pages written", data_pages)
}

/*
With the smallest pool, pages spill while the puts run, and an overflow
value is written straight to the file: all before the commit, and so before
its first sync. The commit still syncs exactly twice.
*/
@(private = "file")
journal_spill_overflow_before_sync :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "db")
	path := temp_dir_file(dir, "db")
	build_tree_file(t, path, even_entries(HOOK_TREE_KEYS))

	env, err := kv.env_open(path, {dirty_budget = MIN_DIRTY_BUDGET})
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)
	ps := env.page_size

	j: Journal
	journal_start(&j)
	defer journal_destroy(&j)
	defer journal_stop()
	txn, _ := kv.txn_begin(env, read_only = false)

	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 1), patterned(3 * ps, 7)), kv.Error.None)
	overflow_ops := len(j.ops)
	testing.expect(t, overflow_ops > 0, "the overflow value wasn't written at put")

	for i in 0 ..< 3000 {
		if kv.put(&txn, u64_key(&key, u64(10_000 + i)), patterned(200, u32(i))) != .None {
			testing.expectf(t, false, "put %d failed", i)
			break
		}
	}
	before_commit := len(j.ops)
	testing.expectf(t, before_commit - overflow_ops > kv.MIN_DIRTY_PAGES, "only %d operations of spilling", before_commit - overflow_ops)
	for r in j.ops[:before_commit] {
		testing.expect(t, r.kind != .Sync, "a sync before the commit")
	}
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)

	syncs := 0
	for r in j.ops[before_commit:] {
		syncs += int(r.kind == .Sync)
	}
	testing.expect_value(t, syncs, 2)
	testing.expect_value(t, j.ops[len(j.ops) - 1].kind, kv.Io_Kind.Sync)
}

/*
The kill image after the whole journal is the real file, byte for byte:
from no file (so env_open's truncate and meta pages are in the journal)
through several commits, spilling and overflow runs included.
*/
@(private = "file")
journal_kill_image_is_file :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "db", "image")
	path := temp_dir_file(dir, "db")
	image := strings.clone(temp_dir_file(dir, "image"), context.temp_allocator)

	base, ok := baseline_take(path)
	testing.expect(t, ok && !base.exists, "baseline of a missing file")
	defer baseline_destroy(&base)

	j: Journal
	journal_start(&j)
	defer journal_destroy(&j)
	env, err := kv.env_open(path, {dirty_budget = MIN_DIRTY_BUDGET})
	if !testing.expect_value(t, err, kv.Error.None) {
		journal_stop()
		return
	}
	for round in 0 ..< 3 {
		txn, _ := kv.txn_begin(env, read_only = false)
		for i in 0 ..< 1500 {
			key: [8]byte
			v := patterned(3 * env.page_size, u32(i)) if i % 97 == 0 else patterned(100 + i % 200, u32(i + round))
			if kv.put(&txn, u64_key(&key, u64(i * 7 % 1500 + round * 500)), v) != .None {
				testing.expectf(t, false, "round %d: put %d failed", round, i)
				break
			}
		}
		for i in 0 ..< 200 * round {
			key: [8]byte
			kv.del(&txn, u64_key(&key, u64(i * 3)))
		}
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	}
	kv.env_close(env)
	journal_stop()

	file, file_ok := baseline_take(path)
	defer baseline_destroy(&file)
	testing.expect(t, file_ok, "reading the database file")
	testing.expect(t, journal_image_kill(base, j, len(j.ops), image), "writing the image")
	img, img_ok := baseline_take(image)
	defer baseline_destroy(&img)
	testing.expect(t, img_ok, "reading the image")
	testing.expectf(t, bytes.equal(img.bytes, file.bytes), "the image (%d bytes) differs from the file (%d bytes)", len(img.bytes), len(file.bytes))
	testing.expect_value(t, j.ops[0].kind, kv.Io_Kind.Truncate)
}

/*
A hook returning an error at operation i makes the store call performing
it return that error, without performing it and without going on: tried at
every operation of one commit, and at env_open's truncate. A commit whose
meta page write failed reopens at the previous commit.
*/
@(private = "file")
io_hook_fails_operation :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "db", "new")
	path := temp_dir_file(dir, "db")

	// A dry run gives the commit's operations.
	build_tree_file(t, path, even_entries(HOOK_TREE_KEYS))
	dry: Journal
	{
		env, err := kv.env_open(path)
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		journal_start(&dry)
		txn, _ := kv.txn_begin(env, read_only = false)
		hook_put_spread(&txn, 8)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		journal_stop()
		kv.env_close(env)
	}
	defer journal_destroy(&dry)
	meta_write := len(dry.ops) - 2

	for i in 0 ..< len(dry.ops) {
		// build_tree_file writes one meta slot: the other must not keep the
		// last round's commit.
		file_remove(path)
		build_tree_file(t, path, even_entries(HOOK_TREE_KEYS))
		env, err := kv.env_open(path)
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		j: Journal
		journal_start(&j)
		j.fail_at, j.fail_with = i, .Io
		txn, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, hook_put_spread(&txn, 8), kv.Error.None)
		testing.expectf(t, kv.txn_commit(&txn) == .Io, "failing operation %d (%v) didn't fail the commit", i, dry.ops[i].kind)
		journal_stop()
		testing.expectf(t, len(j.ops) == i && j.calls == i + 1, "failing operation %d: %d performed after %d calls", i, len(j.ops), j.calls)
		journal_destroy(&j)
		kv.env_close(env)

		if i == meta_write {
			env, err = kv.env_open(path)
			if testing.expect_value(t, err, kv.Error.None) {
				testing.expect_value(t, kv.env_snapshot(env).txn_id, kv.Txn_Id(1))
				kv.env_close(env)
			}
		}
	}

	// env_open of a new file: its first operation is the truncate.
	j: Journal
	journal_start(&j)
	j.fail_at, j.fail_with = 0, .Io
	env, err := kv.env_open(temp_dir_file(dir, "new"))
	journal_stop()
	testing.expect_value(t, err, kv.Error.Io)
	testing.expect_value(t, len(j.ops), 0)
	journal_destroy(&j)
	if env != nil {
		kv.env_close(env)
	}
}

@(private = "file")
Hook_Thread :: struct {
	path:      string,
	commits:   int,
	allocator: mem.Allocator,
	// Results, checked on the test's thread.
	fd:        int,
	ops:       int,
	syncs:     int,
	other_fd:  int,
	err:       kv.Error,
	image_ok:  bool,
}

// Creates a database and commits into it with a journal on this thread,
// then checks the journal against the file it made. No testing calls: an
// assert on a thread other than the test's hangs the runner.
@(private = "file")
hook_thread_run :: proc(h: ^Hook_Thread) {
	context.allocator = h.allocator
	defer free_all(context.temp_allocator)
	j: Journal
	journal_start(&j)
	defer journal_destroy(&j)
	env, err := kv.env_open(h.path)
	if err != .None {
		journal_stop()
		h.err = err
		return
	}
	h.fd = int(env.fd)
	for c in 0 ..< h.commits {
		txn, _ := kv.txn_begin(env, read_only = false)
		for i in 0 ..< 50 {
			key: [8]byte
			kv.put(&txn, u64_key(&key, u64(c * 50 + i)), patterned(64, u32(i)))
		}
		if err = kv.txn_commit(&txn); err != .None {
			h.err = err
			break
		}
	}
	kv.env_close(env)
	journal_stop()

	h.ops = len(j.ops)
	for r in j.ops {
		h.syncs += int(r.kind == .Sync)
		h.other_fd += int(int(r.fd) != h.fd)
	}
	image := strings.concatenate({h.path, ".image"}, context.temp_allocator)
	file, _ := baseline_take(h.path)
	defer baseline_destroy(&file)
	if journal_image_kill({}, j, len(j.ops), image) {
		img, _ := baseline_take(image)
		defer baseline_destroy(&img)
		h.image_ok = bytes.equal(img.bytes, file.bytes)
	}
}

/*
Two threads, two envs, a journal each, running at once: each journal holds
its own env's operations and all of them (its kill image is its file), and
the test's own thread sees no hook.
*/
@(private = "file")
io_hook_per_thread :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, "a", "a.image", "b", "b.image")

	hs := [2]Hook_Thread {
		{path = strings.clone(temp_dir_file(dir, "a"), context.temp_allocator), commits = 20, allocator = context.allocator},
		{path = strings.clone(temp_dir_file(dir, "b"), context.temp_allocator), commits = 35, allocator = context.allocator},
	}
	threads: [2]^thread.Thread
	for &h, i in hs {
		threads[i] = thread.create_and_start_with_poly_data(&h, hook_thread_run)
	}
	thread.join_multiple(..threads[:])
	for th in threads {
		thread.destroy(th)
	}

	testing.expect(t, kv.io_hook == nil, "a hook on the test's thread")
	for h, i in hs {
		testing.expectf(t, h.err == .None, "thread %d: %v", i, h.err)
		testing.expectf(t, h.other_fd == 0, "thread %d: %d operations on another fd", i, h.other_fd)
		// env_open's sync, then two per commit.
		testing.expectf(t, h.syncs == 1 + 2 * h.commits, "thread %d: %d syncs for %d commits", i, h.syncs, h.commits)
		testing.expectf(t, h.image_ok, "thread %d: the kill image differs from the file", i)
	}
	testing.expect(t, hs[0].fd != hs[1].fd, "the two envs share a file descriptor")
}
