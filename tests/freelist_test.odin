package kv_tests

import "core:fmt"
import "core:mem"
import "core:math/rand"
import "core:slice"
import "core:sync"
import "core:sys/posix"
import "core:testing"

import kv "../kv"

// Reads the free-list run of `snap` straight from the file, checking its
// header, and returns its records (temp allocator).
@(private = "file")
read_freelist :: proc(t: ^testing.T, env: ^kv.Env, snap: kv.Snapshot, loc := #caller_location) -> []kv.Free_Record {
	if snap.freelist_pgno == 0 {
		testing.expect_value(t, snap.freelist_count, 0, loc = loc)
		return nil
	}
	buf: Page_Buf
	page := read_page(t, env, snap.freelist_pgno, &buf)
	h := kv.page_header(page)
	testing.expect_value(t, kv.Pgno(h.pgno), snap.freelist_pgno, loc = loc)
	testing.expect_value(t, u16(h.flags), kv.PAGE_FREELIST, loc = loc)
	needed := kv.freelist_run_pages(env.page_size, int(snap.freelist_count))
	pages := int(h.overflow_count)
	testing.expectf(t, pages >= needed && pages <= needed + kv.FREELIST_RUN_SLACK, "run of %d pages for %d records, which need %d", pages, snap.freelist_count, needed, loc = loc)

	records := make([]kv.Free_Record, snap.freelist_count, context.temp_allocator)
	off := i64(snap.freelist_pgno) * i64(env.page_size) + kv.PAGE_HEADER_SIZE
	testing.expect_value(t, kv.os_pread(env.fd, mem.slice_to_bytes(records), off), kv.Error.None, loc = loc)
	return records
}

// The free list as the tests expect it: the reusable pages, and the pending
// records in (txn_id, pgno) order.
@(private = "file")
Expected_Free :: struct {
	ready:   [dynamic]kv.Pgno,
	pending: [dynamic]kv.Free_Record,
}

// Compares the env's free list, and unless `on_disk` is false the run the
// last commit wrote, with `want`.
@(private = "file")
expect_free :: proc(t: ^testing.T, env: ^kv.Env, want: Expected_Free, on_disk := true, loc := #caller_location) -> bool {
	slice.sort(want.ready[:])
	ok := slice.equal(env.free.ready[:], want.ready[:])
	testing.expectf(t, ok, "ready pages differ: %d, want %d", len(env.free.ready), len(want.ready), loc = loc)
	pending_ok := slice.equal(env.free.pending[:], want.pending[:])
	testing.expectf(t, pending_ok, "pending records differ: %d, want %d", len(env.free.pending), len(want.pending), loc = loc)

	if !on_disk {
		return ok && pending_ok
	}
	// On disk: every reusable page tagged 0, then the pending records.
	snap := kv.env_snapshot(env)
	disk := read_freelist(t, env, snap, loc)
	disk_ok := len(disk) == len(want.ready) + len(want.pending)
	for r, i in disk {
		if !disk_ok {
			break
		}
		if i < len(want.ready) {
			disk_ok = r == kv.Free_Record{pgno = u64le(want.ready[i])}
		} else {
			disk_ok = r == want.pending[i - len(want.ready)]
		}
	}
	testing.expect(t, disk_ok, "free list on disk differs", loc = loc)
	return ok && pending_ok && disk_ok
}

// Checks every page of the latest snapshot with a new read transaction.
@(private = "file")
expect_committed_space_ok :: proc(t: ^testing.T, env: ^kv.Env, loc := #caller_location) -> bool {
	reader, err := kv.txn_begin(env)
	testing.expect_value(t, err, kv.Error.None, loc = loc)
	if err != .None {
		return false
	}
	defer kv.txn_abort(&reader)
	return expect_space_ok(t, &reader, loc) && expect_tree_ok(t, &reader, loc)
}

@(test)
test_freelist_round_trip :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ps := env.page_size

	want: Expected_Free
	want.ready = make([dynamic]kv.Pgno, context.temp_allocator)
	want.pending = make([dynamic]kv.Free_Record, context.temp_allocator)
	loose_seen, freed_seen, runs_seen, reused_seen, runs_reused := 0, 0, 0, 0, 0

	for commit in 1 ..= 60 {
		txn, begin_err := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, begin_err, kv.Error.None)
		if begin_err != .None {
			return
		}
		// With no readers, beginning makes every page freed before the
		// snapshot reusable: all but the ones the snapshot itself freed.
		s := u64le(txn.snapshot.txn_id)
		testing.expect_value(t, txn.write.oldest, kv.Txn_Id(max(s, 1) - 1))
		release_before(&want, s)
		if !expect_free(t, env, want, on_disk = false) {
			return
		}
		for _ in 0 ..< 1 + rand.int_max(200) {
			key: [8]byte
			value := patterned(rand.int_max(200), u32(commit))
			if rand.int_max(20) == 0 {
				value = patterned(ps + rand.int_max(2 * ps), u32(commit))
			}
			kv.put(&txn, u64_key(&key, u64(rand.int_max(2_000))), value)
		}
		if commit % 3 == 0 {
			// Write an overflow run and replace it: its pages become loose.
			key := transmute([]byte)fmt.tprintf("loose%d", commit)
			kv.put(&txn, key, patterned(2 * ps, 1))
			kv.put(&txn, key, patterned(3 * ps, 2))
			testing.expect(t, len(txn.write.loose) >= 2, "no loose pages")
		}
		testing.expect_value(t, txn.err, kv.Error.None)
		expect_space_ok(t, &txn)

		// What the commit should leave: the reusable pages and the loose
		// ones, less every page the transaction wrote and the new run; and
		// the freed pages plus the previous run tagged with the new txn_id.
		tag := u64le(txn.snapshot.txn_id + 1)
		last_before := txn.snapshot.last_pgno
		written := dirty_pages(&txn)
		for p in want.ready {
			if slice.contains(written, p) {
				reused_seen += 1
			}
		}
		for p in txn.write.loose {
			if !slice.contains(want.ready[:], p) {
				append(&want.ready, p)
			}
		}
		remove_pages(&want.ready, written)
		added := make([dynamic]kv.Pgno, context.temp_allocator)
		append(&added, ..txn.write.freed[:])
		if run := txn.snapshot.freelist_pgno; run != 0 {
			for i in 0 ..< freelist_run_len(t, env, txn.snapshot) {
				append(&added, run + kv.Pgno(i))
			}
			runs_seen += 1
		}
		slice.sort(added[:])
		for p in added {
			append(&want.pending, kv.Free_Record{pgno = u64le(p), txn_id = tag})
		}
		loose_seen += len(txn.write.loose)
		freed_seen += len(txn.write.freed)

		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		// The new run is in reusable pages, or at the end of the file.
		snap := kv.env_snapshot(env)
		if snap.freelist_pgno != 0 {
			run := make([]kv.Pgno, freelist_run_len(t, env, snap), context.temp_allocator)
			for &p, i in run {
				p = snap.freelist_pgno + kv.Pgno(i)
			}
			if snap.freelist_pgno <= last_before {
				runs_reused += 1
				for p in run {
					testing.expectf(t, slice.contains(want.ready[:], p), "run page %d was not reusable", p)
				}
			}
			remove_pages(&want.ready, run)
		}
		if !expect_free(t, env, want) || !expect_committed_space_ok(t, env) {
			return
		}

		if commit % 20 == 0 {
			// After a reopen, only pages the last commit freed stay pending.
			// The run on disk is read as it is, tags and all.
			disk := read_freelist(t, env, kv.env_snapshot(env))
			kv.env_close(env)
			env, err = kv.env_open(path)
			testing.expect_value(t, err, kv.Error.None)
			if err != .None {
				env = nil
				return
			}
			release_before(&want, u64le(kv.env_snapshot(env).txn_id))
			testing.expect(t, len(want.pending) > 0, "nothing pending after reopen")
			testing.expect(t, slice.equal(read_freelist(t, env, kv.env_snapshot(env)), disk), "run changed by reopening")
			if !expect_free(t, env, want, on_disk = false) || !expect_committed_space_ok(t, env) {
				return
			}
		}
	}
	testing.expect(t, loose_seen > 0 && freed_seen > 0 && runs_seen > 0, "the free list was not exercised")
	testing.expect(t, reused_seen > 0 && runs_reused > 0, "no page was reused")
}

// Moves the expected pending records tagged before `s` to the ready pages,
// as a write transaction beginning from `s` with no readers does.
@(private = "file")
release_before :: proc(want: ^Expected_Free, s: u64le) {
	kept := 0
	for r in want.pending {
		if r.txn_id < s {
			append(&want.ready, kv.Pgno(r.pgno))
		} else {
			want.pending[kept] = r
			kept += 1
		}
	}
	resize(&want.pending, kept)
	slice.sort(want.ready[:])
}

// Every page a write transaction has written so far, overflow runs
// included (temp allocator).
dirty_pages :: proc(txn: ^kv.Txn) -> []kv.Pgno {
	pages := make([dynamic]kv.Pgno, context.temp_allocator)
	for pgno, buf in txn.write.dirty {
		for i in 0 ..< len(buf) / txn.env.page_size {
			append(&pages, pgno + kv.Pgno(i))
		}
	}
	slice.sort(pages[:])
	return pages[:]
}

// Removes every page in `pages` from `list`, keeping its order.
@(private = "file")
remove_pages :: proc(list: ^[dynamic]kv.Pgno, pages: []kv.Pgno) {
	kept := 0
	for p in list {
		if !slice.contains(pages, p) {
			list[kept] = p
			kept += 1
		}
	}
	resize(list, kept)
}

@(test)
test_freelist_empty_list_writes_no_run :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	// The first commit replaces nothing, so it has no free list.
	commit_entries(t, env, even_entries(100))
	snap := kv.env_snapshot(env)
	meta, _ := read_meta(t, env, 1)
	testing.expect_value(t, meta.freelist_pgno, 0)
	testing.expect_value(t, meta.freelist_count, 0)
	testing.expect_value(t, snap.freelist_pgno, 0)
	testing.expect_value(t, len(env.free.ready) + len(env.free.pending), 0)
	expect_committed_space_ok(t, env)

	// The second one frees the leaf it rewrites, and places the run last.
	txn, _ := kv.txn_begin(env, read_only = false)
	key: [8]byte
	kv.put(&txn, u64_key(&key, 0), transmute([]byte)string("changed"))
	freed := len(txn.write.freed)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	snap = kv.env_snapshot(env)
	meta, _ = read_meta(t, env, 0)
	testing.expect_value(t, meta.freelist_count, u64le(freed))
	testing.expect_value(t, meta.freelist_pgno, u64le(snap.freelist_pgno))
	testing.expect_value(t, snap.freelist_pgno, snap.last_pgno)
	testing.expect_value(t, len(env.free.pending), freed)
	expect_committed_space_ok(t, env)
}

// A database written before the free list existed has both meta fields at
// 0. It opens with an empty list, and its first commit starts one.
@(test)
test_freelist_opens_file_without_list :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	tree := build_tree_file(t, path, even_entries(2_000))
	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	snap := kv.env_snapshot(env)
	testing.expect_value(t, snap.freelist_pgno, 0)
	testing.expect_value(t, snap.freelist_count, 0)
	testing.expect_value(t, len(env.free.ready) + len(env.free.pending), 0)
	expect_committed_space_ok(t, env)

	txn, _ := kv.txn_begin(env, read_only = false)
	key: [8]byte
	kv.put(&txn, u64_key(&key, 2), transmute([]byte)string("changed"))
	testing.expect_value(t, len(txn.write.freed), tree.depth)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	testing.expect_value(t, len(env.free.pending), tree.depth)
	for r in env.free.pending {
		testing.expect_value(t, r.txn_id, 2)
	}
	expect_committed_space_ok(t, env)
}

@(test)
test_freelist_io_error_leaves_free_unchanged :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	for i in 0 ..< 5 {
		commit_entries(t, env, even_entries(500 + 100 * i))
	}
	before := kv.env_snapshot(env)

	// The list as it is once the transaction has begun: beginning moves the
	// newly reusable records to `ready`, the one change it may make.
	txn, _ := kv.txn_begin(env, read_only = false)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	pending := slice.clone(env.free.pending[:], context.temp_allocator)
	testing.expect(t, len(ready) > 0 && len(pending) > 0, "nothing on the free list")
	for i in 0 ..< 2_000 {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(i)), transmute([]byte)string("lost"))
	}
	testing.expect_value(t, txn.write.ready_taken, len(ready))
	expect_space_ok(t, &txn)
	fd := env.fd
	env.fd = posix.FD(-1)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.Io)
	env.fd = fd

	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, slice.equal(env.free.ready[:], ready), "ready pages changed")
	testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records changed")
	expect_committed_space_ok(t, env)

	// The next commit starts from the same list.
	commit_entries(t, env, even_entries(10))
	testing.expect(t, len(env.free.pending) > len(pending), "commit after the failure added nothing")
	testing.expect(t, slice.equal(env.free.pending[:len(pending)], pending), "earlier records changed")
	expect_committed_space_ok(t, env)
	kv.env_close(env)

	env2, err2 := kv.env_open(path)
	testing.expect_value(t, err2, kv.Error.None)
	if err2 != .None {
		return
	}
	defer kv.env_close(env2)
	expect_committed_space_ok(t, env2)
}

// A commit whose free-list run doesn't fit in the map fails with Map_Full
// and leaves everything at the previous commit.
@(test)
test_freelist_run_map_full :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	options := kv.Options{map_size = 256 * 1024}

	env, err := kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	commit_entries(t, env, even_entries(300))
	commit_entries(t, env, even_entries(300))
	before := kv.env_snapshot(env)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	pending := slice.clone(env.free.pending[:], context.temp_allocator)

	// Change one key, then take every page left in the map, so the run has
	// nowhere to go. Nothing is reusable yet: the only freed pages are the
	// ones commit 2 freed, which snapshot 1 still uses (KV-I-0002 D1).
	txn, _ := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, len(env.free.ready), 0)
	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 0), transmute([]byte)string("x")), kv.Error.None)
	left := env.map_size / env.page_size - int(txn.snapshot.last_pgno) - 1
	testing.expect(t, left > 0, "the map is already full")
	_, _, alloc_err := kv.page_alloc(&txn, left)
	testing.expect_value(t, alloc_err, kv.Error.None)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.Map_Full)

	testing.expect(t, txn.done, "failed commit must end the transaction")
	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, slice.equal(env.free.ready[:], ready), "ready pages changed")
	testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records changed")
	testing.expect(t, sync.mutex_try_lock(&env.writer_mutex), "writer lock not released")
	sync.mutex_unlock(&env.writer_mutex)
	expect_committed_space_ok(t, env)
	kv.env_close(env)

	env2, reader, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env2)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, reader.snapshot, before)
	expect_even_entries(t, &reader, 300)
	expect_space_ok(t, &reader)
}

@(test)
test_space_check_catches_leak_and_double :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	commit_entries(t, env, even_entries(1_000))
	commit_entries(t, env, even_entries(1_000))

	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	key: [8]byte
	kv.put(&txn, u64_key(&key, 1), transmute([]byte)string("new"))
	expect_space_ok(t, &txn)

	// A freed page that no list mentions is leaked.
	leaked := pop(&txn.write.freed)
	ok, reason := kv.space_check(&txn)
	testing.expect(t, !ok && reason == "page owned by nothing", reason)
	append(&txn.write.freed, leaked)

	// One on two lists is owned twice: here a tree page also freed.
	append(&txn.write.freed, txn.snapshot.root)
	ok, reason = kv.space_check(&txn)
	testing.expect(t, !ok && reason == "page owned twice", reason)
	pop(&txn.write.freed)

	// And a page both on the committed free list and loose.
	append(&txn.write.loose, kv.Pgno(env.free.pending[0].pgno))
	ok, reason = kv.space_check(&txn)
	testing.expect(t, !ok && reason == "page owned twice", reason)
	pop(&txn.write.loose)

	expect_space_ok(t, &txn)
}

// ---------------------------------------------------------------------------
// Validation at open, with hand-written runs

// A free list written by hand: the run's page, its records, and header and
// meta fields that default to what a commit would write. Also used by
// bench_test.odin.
Hand_List :: struct {
	records:        []kv.Free_Record,
	run:            kv.Pgno,
	// -1: len(records).
	count:          int,
	flags:          u16,
	// 0: the run's page number.
	header_pgno:    kv.Pgno,
	// -1: the pages the records need.
	overflow_count: int,
	// 0: HAND_LAST_PGNO.
	last_pgno:      kv.Pgno,
	// If not 0, the tree is one leaf at this page holding the key "k".
	root:           kv.Pgno,
	// Passed to env_open when the database is opened.
	options:        kv.Options,
}

HAND_TXN :: 5
@(private = "file")
HAND_LAST_PGNO :: 40

// Records for a valid list at txn 5 with the run at page 30: reusable pages
// 3 and 9, pages freed by txns 2 and 4, and pages 5 and 8 freed by txn 5.
@(private = "file")
hand_records :: proc() -> []kv.Free_Record {
	records := []kv.Free_Record{{3, 0}, {9, 0}, {4, 2}, {12, 4}, {5, 5}, {8, 5}}
	return slice.clone(records, context.temp_allocator)
}

// Writes a database whose newest meta page (txn 5, last_pgno 40 unless the
// list says otherwise) holds `list`, and whose older one (txn 4) has no free
// list, then opens it. The tree is empty unless the list gives a root.
// Returns the env on success.
open_hand_list :: proc(t: ^testing.T, path: string, list: Hand_List) -> (env: ^kv.Env, err: kv.Error) {
	ps := kv.DEFAULT_PAGE_SIZE
	count := len(list.records) if list.count == -1 else list.count
	flags := list.flags if list.flags != 0 else kv.PAGE_FREELIST
	header_pgno := list.header_pgno if list.header_pgno != 0 else list.run
	overflow_count := list.overflow_count if list.overflow_count != -1 else kv.freelist_run_pages(ps, count)
	last := list.last_pgno if list.last_pgno != 0 else HAND_LAST_PGNO

	{
		w, open_err := kv.env_open(path)
		testing.expect_value(t, open_err, kv.Error.None)
		if open_err != .None {
			return nil, open_err
		}
		defer kv.env_close(w)
		testing.expect_value(t, kv.os_truncate(w.fd, (i64(last) + 1) * i64(ps)), kv.Error.None)
		if list.run >= 2 && list.run <= last {
			// The records may span several pages.
			pages := kv.freelist_run_pages(ps, len(list.records))
			bufs := make([]Page_Buf, pages, context.temp_allocator)
			run := mem.slice_to_bytes(bufs)
			h := kv.page_header(run)
			h.pgno = u64le(header_pgno)
			h.flags = u16le(flags)
			h.overflow_count = u32le(overflow_count)
			records := ([^]kv.Free_Record)(&run[kv.PAGE_HEADER_SIZE])[:len(list.records)]
			copy(records, list.records)
			for i in 0 ..< pages {
				write_page(t, w, list.run + kv.Pgno(i), run[i * ps:][:ps])
			}
		}
		older := make_meta(HAND_TXN - 1, last_pgno = u64(last))
		newer := make_meta(HAND_TXN, last_pgno = u64(last))
		newer.freelist_pgno = u64le(list.run)
		newer.freelist_count = u64le(count)
		if list.root != 0 {
			buf: Page_Buf
			leaf := buf.bytes[:]
			kv.page_init(leaf, list.root, kv.PAGE_LEAF)
			kv.leaf_insert(leaf, 0, transmute([]byte)string("k"), transmute([]byte)string("v"))
			write_page(t, w, list.root, leaf)
			newer.root, newer.depth, newer.entries = u64le(list.root), 1, 1
		}
		testing.expect_value(t, kv.meta_write(w, 0, older), kv.Error.None)
		testing.expect_value(t, kv.meta_write(w, 1, newer), kv.Error.None)
	}
	return kv.env_open(path, list.options)
}

@(test)
test_freelist_load_valid :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := open_hand_list(t, temp_dir_file(dir, DB), {records = hand_records(), run = 30, count = -1, overflow_count = -1})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	testing.expect_value(t, kv.env_snapshot(env).txn_id, HAND_TXN)
	// Everything freed before txn 5 is reusable; what txn 5 freed is not.
	testing.expect(t, slice.equal(env.free.ready[:], []kv.Pgno{3, 4, 9, 12}), "wrong ready pages")
	testing.expect(t, slice.equal(env.free.pending[:], []kv.Free_Record{{5, 5}, {8, 5}}), "wrong pending records")
}

// A run may have one page more than its records need, which placement
// leaves when no length fits exactly (KV-T-0014). The records are read as
// usual, and the slack page belongs to the run.
@(test)
test_freelist_load_accepts_a_page_of_slack :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := open_hand_list(t, temp_dir_file(dir, DB), {records = hand_records(), run = 30, count = -1, overflow_count = 1 + kv.FREELIST_RUN_SLACK})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	testing.expect(t, slice.equal(env.free.ready[:], []kv.Pgno{3, 4, 9, 12}), "wrong ready pages")
	testing.expect(t, slice.equal(env.free.pending[:], []kv.Free_Record{{5, 5}, {8, 5}}), "wrong pending records")
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, freelist_run_len(t, env, reader.snapshot), 2)
}

@(test)
test_freelist_load_rejects_bad_lists :: proc(t: ^testing.T) {
	Case :: struct {
		name: string,
		edit: proc(list: ^Hand_List),
	}
	cases := []Case {
		{"tag after the snapshot", proc(l: ^Hand_List) {l.records[5].txn_id = HAND_TXN + 1}},
		{"tags out of order", proc(l: ^Hand_List) {l.records[2], l.records[3] = l.records[3], l.records[2]}},
		{"pages out of order", proc(l: ^Hand_List) {l.records[0], l.records[1] = l.records[1], l.records[0]}},
		{"same record twice", proc(l: ^Hand_List) {l.records[1] = l.records[0]}},
		{"page reusable twice", proc(l: ^Hand_List) {l.records[3].pgno = 3}},
		{"page reusable and pending", proc(l: ^Hand_List) {l.records[4].pgno = 3}},
		{"page inside the run", proc(l: ^Hand_List) {l.records[5].pgno = 30}},
		{"page past last_pgno", proc(l: ^Hand_List) {l.records[5].pgno = HAND_LAST_PGNO + 1}},
		{"meta page", proc(l: ^Hand_List) {l.records[0].pgno = 1}},
		{"page 0", proc(l: ^Hand_List) {l.records[0].pgno = 0}},
		{"header flags", proc(l: ^Hand_List) {l.flags = kv.PAGE_OVERFLOW}},
		{"header page number", proc(l: ^Hand_List) {l.header_pgno = 31}},
		{"header page count, too many", proc(l: ^Hand_List) {l.overflow_count = 1 + kv.FREELIST_RUN_SLACK + 1}},
		{"count needs more pages than the header says", proc(l: ^Hand_List) {l.count = 300; l.overflow_count = 1}},
		{"count but no run", proc(l: ^Hand_List) {l.run = 0; l.count = 3}},
		{"run but no records", proc(l: ^Hand_List) {l.count = 0; l.overflow_count = 1}},
	}
	for c in cases {
		dir := temp_dir_create(t)
		list := Hand_List{records = hand_records(), run = 30, count = -1, overflow_count = -1}
		c.edit(&list)
		env, err := open_hand_list(t, temp_dir_file(dir, DB), list)
		testing.expectf(t, err == .Corrupted, "%s: env_open returned %v", c.name, err)
		if env != nil {
			kv.env_close(env)
		}
		temp_dir_destroy(&dir, DB)
	}
}

// page_alloc hands out the lowest reusable page, or the lowest run of
// consecutive ones, skipping what the transaction took; never a pending
// page; and extends the file only when nothing reusable fits. Env.free is
// not changed.
@(test)
test_page_alloc_reuses_lowest_first :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// Reusable: 3 4 | 6 7 8 | 11 12 13 14 | 16. Pending (tag 5): 9 and 10.
	records := []kv.Free_Record{{3, 0}, {4, 0}, {6, 0}, {7, 0}, {8, 0}, {11, 0}, {12, 0}, {13, 0}, {14, 0}, {16, 0}, {9, 5}, {10, 5}}
	env, err := open_hand_list(t, temp_dir_file(dir, DB), {records = slice.clone(records, context.temp_allocator), run = 30, count = -1, overflow_count = -1})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	pending := slice.clone(env.free.pending[:], context.temp_allocator)
	testing.expect(t, slice.equal(ready, []kv.Pgno{3, 4, 6, 7, 8, 11, 12, 13, 14, 16}), "wrong ready pages")

	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	// The snapshot is txn 5, so what it freed stays pending.
	testing.expect_value(t, txn.write.oldest, HAND_TXN - 1)
	testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records released")

	Step :: struct {
		n:    int,
		want: kv.Pgno,
	}
	steps := []Step {
		{1, 3}, // the lowest page
		{2, 6}, // 4 alone is too short
		{1, 4},
		{1, 8}, // 6 and 7 are taken
		{4, 11},
		{2, HAND_LAST_PGNO + 1}, // only 16 is left: extend
		{1, 16},
		{1, HAND_LAST_PGNO + 3},
	}
	for step, i in steps {
		pgno, buf, alloc_err := kv.page_alloc(&txn, step.n)
		testing.expectf(t, alloc_err == .None && pgno == step.want, "step %d: page_alloc(%d) = %d, %v; want %d", i, step.n, pgno, alloc_err, step.want)
		testing.expectf(t, len(buf) == step.n * env.page_size && raw_data(txn.write.dirty[pgno]) == raw_data(buf), "step %d: buffer not registered", i)
	}
	testing.expect(t, slice.equal(txn.write.taken[:], []kv.Pgno{6, 7, 11, 12, 13, 14}), "wrong runs taken")
	testing.expect_value(t, txn.write.ready_next, len(ready))
	testing.expect_value(t, txn.write.ready_taken, len(ready))
	testing.expect_value(t, txn.snapshot.last_pgno, HAND_LAST_PGNO + 3)
	testing.expect(t, slice.equal(env.free.ready[:], ready), "ready pages changed")
	testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records changed")
}

// `n` tag-0 records for pages first, first + stride, ... (temp allocator).
@(private = "file")
ready_records :: proc(first: kv.Pgno, n: int, stride := 1) -> []kv.Free_Record {
	records := make([]kv.Free_Record, n, context.temp_allocator)
	for &r, i in records {
		r.pgno = u64le(first + kv.Pgno(stride * i))
	}
	return records
}

// The commit's run goes into reusable pages when a run of them is at least
// as long as the records left after taking it need, taking the shortest
// such length; otherwise it extends the file. Either way the list it writes
// opens again, and the next commit frees every page of the run, a page of
// slack included.
@(test)
test_freelist_run_length_fits_its_records :: proc(t: ^testing.T) {
	Case :: struct {
		// Reusable pages 2, 2 + stride, ..., and how many single pages
		// the transaction takes from the front of them.
		ready, taken: int,
		stride:       int,
		// Where the new run should go, its records and pages, and
		// last_pgno after.
		run:          kv.Pgno,
		count:        u64,
		pages:        int,
		last:         kv.Pgno,
	}
	LAST :: 600
	OLD_RUN :: 590
	cases := []Case {
		// 99 left plus the old run's page: 100 records, 1 page. Taking a
		// page leaves 99, which still need 1.
		{ready = 100, taken = 1, stride = 1, run = 3, count = 99, pages = 1, last = LAST},
		// 254 left plus the old run's 2 pages: 256 records need 2 pages,
		// but taking 2 leaves 254, which need 1, and taking 1 leaves 255,
		// which need 1: a 1-page run in reusable pages.
		{ready = 256, taken = 2, stride = 1, run = 4, count = 255, pages = 1, last = LAST},
		// 255 left plus 2: 257 records. Taking 1 leaves 256, which need
		// 2; taking 2 leaves 255, which need 1. No length fits exactly, so
		// the run takes 2 pages and has one of slack (KV-T-0014).
		{ready = 256, taken = 1, stride = 1, run = 3, count = 255, pages = 2, last = LAST},
		// The same 257 records, but no two reusable pages are consecutive,
		// so the run extends the file at the length they all need.
		{ready = 256, taken = 1, stride = 2, run = LAST + 1, count = 257, pages = 2, last = LAST + 2},
	}
	for c in cases {
		dir := temp_dir_create(t)
		path := temp_dir_file(dir, DB)
		env, err := open_hand_list(t, path, {records = ready_records(2, c.ready, c.stride), run = OLD_RUN, count = -1, overflow_count = -1, last_pgno = LAST})
		testing.expectf(t, err == .None, "ready %d: env_open returned %v", c.ready, err)
		if err == .None {
			txn, _ := kv.txn_begin(env, read_only = false)
			for _ in 0 ..< c.taken {
				kv.page_alloc(&txn, 1)
			}
			testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
			snap := kv.env_snapshot(env)
			pages := freelist_run_len(t, env, snap)
			testing.expectf(t, snap.freelist_pgno == c.run && snap.freelist_count == c.count && pages == c.pages && snap.last_pgno == c.last,
				"ready %d, taken %d, stride %d: run %d of %d pages with %d records, last_pgno %d", c.ready, c.taken, c.stride, snap.freelist_pgno, pages, snap.freelist_count, snap.last_pgno)
			read_freelist(t, env, snap)
			kv.env_close(env)
			env, err = kv.env_open(path)
			testing.expectf(t, err == .None, "ready %d, taken %d, stride %d: reopening returned %v", c.ready, c.taken, c.stride, err)
		}
		if err == .None {
			// The next commit frees the whole run, as its header gives it.
			snap := kv.env_snapshot(env)
			txn, _ := kv.txn_begin(env, read_only = false)
			testing.expect_value(t, kv.put(&txn, transmute([]byte)string("k"), transmute([]byte)string("v")), kv.Error.None)
			testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
			for i in 0 ..< c.pages {
				p := u64le(snap.freelist_pgno + kv.Pgno(i))
				testing.expectf(t, slice.contains(env.free.pending[:], kv.Free_Record{pgno = p, txn_id = u64le(snap.txn_id + 1)}), "stride %d: run page %d was not freed", c.stride, p)
			}
		}
		if env != nil {
			kv.env_close(env)
		}
		temp_dir_destroy(&dir, DB)
	}
}

// With the map full, a put of an overflow value is accepted only if a
// reusable run for it survives the single pages the put takes first, which
// come from the lowest reusable pages. Otherwise it is refused up front
// rather than failing part-way.
@(test)
test_put_needs_a_run_the_path_leaves :: proc(t: ^testing.T) {
	Case :: struct {
		ready: []kv.Free_Record,
		want:  kv.Error,
	}
	cases := []Case {
		// Copying the path takes page 2, breaking the only run of 3.
		{{{2, 0}, {3, 0}, {4, 0}, {10, 0}, {20, 0}, {30, 0}}, .Map_Full},
		// The path takes 2; the run 10–12 is left for the value.
		{{{2, 0}, {3, 0}, {4, 0}, {10, 0}, {11, 0}, {12, 0}}, .None},
	}
	for c in cases {
		dir := temp_dir_create(t)
		path := temp_dir_file(dir, DB)
		// 64 pages fill the 256 KiB map exactly.
		env, err := open_hand_list(t, path, {records = slice.clone(c.ready, context.temp_allocator), run = 40, count = -1, overflow_count = -1, last_pgno = 63, root = 63, options = {map_size = 256 * 1024}})
		testing.expect_value(t, err, kv.Error.None)
		if err == .None {
			testing.expect_value(t, env.map_size, 64 * env.page_size)
			txn, _ := kv.txn_begin(env, read_only = false)
			value := patterned(2 * env.page_size, 1)
			testing.expect_value(t, kv.overflow_pages(env.page_size, len(value)), 3)
			put_err := kv.put(&txn, transmute([]byte)string("big"), value)
			testing.expectf(t, put_err == c.want && txn.err == .None, "put returned %v, transaction error %v; want %v", put_err, txn.err, c.want)
			if put_err == .None {
				testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
				reader, _ := kv.txn_begin(env)
				got, get_err := kv.get(&reader, transmute([]byte)string("big"))
				testing.expect(t, get_err == .None && slice.equal(got, value), "value differs")
				kv.txn_abort(&reader)
			}
			kv.txn_abort(&txn)
			kv.env_close(env)
		}
		temp_dir_destroy(&dir, DB)
	}
}

// A run that doesn't lie within the meta page's last_pgno makes that meta
// page invalid, so the database opens at the other one.
@(test)
test_freelist_run_out_of_range_invalidates_meta :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		run:   kv.Pgno,
		count: int,
	}
	cases := []Case {
		{"run on a meta page", 1, 6},
		{"run past last_pgno", HAND_LAST_PGNO + 1, 6},
		{"run ending past last_pgno", HAND_LAST_PGNO, 300},
		{"count larger than the file", 30, 1 << 40},
	}
	for c in cases {
		dir := temp_dir_create(t)
		env, err := open_hand_list(t, temp_dir_file(dir, DB), {records = hand_records(), run = c.run, count = c.count, overflow_count = -1})
		testing.expectf(t, err == .None, "%s: env_open returned %v", c.name, err)
		if env != nil {
			testing.expectf(t, kv.env_snapshot(env).txn_id == HAND_TXN - 1, "%s: opened at txn %d", c.name, kv.env_snapshot(env).txn_id)
			testing.expectf(t, len(env.free.ready) + len(env.free.pending) == 0, "%s: free list loaded", c.name)
			kv.env_close(env)
		}
		temp_dir_destroy(&dir, DB)
	}
}
