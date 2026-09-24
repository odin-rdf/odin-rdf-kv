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
	testing.expect_value(t, int(h.overflow_count), kv.freelist_run_pages(env.page_size, int(snap.freelist_count)), loc = loc)

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
	loose_seen, freed_seen, runs_seen := 0, 0, 0

	for commit in 1 ..= 60 {
		txn, begin_err := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, begin_err, kv.Error.None)
		if begin_err != .None {
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

		// What the commit should add: loose pages as reusable, and the
		// freed pages plus the previous run tagged with the new txn_id.
		tag := u64le(txn.snapshot.txn_id + 1)
		append(&want.ready, ..txn.write.loose[:])
		added := make([dynamic]kv.Pgno, context.temp_allocator)
		append(&added, ..txn.write.freed[:])
		if run := txn.snapshot.freelist_pgno; run != 0 {
			for i in 0 ..< kv.freelist_run_pages(ps, int(txn.snapshot.freelist_count)) {
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
			s := u64le(kv.env_snapshot(env).txn_id)
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
			testing.expect(t, kept > 0, "nothing pending after reopen")
			testing.expect(t, slice.equal(read_freelist(t, env, kv.env_snapshot(env)), disk), "run changed by reopening")
			if !expect_free(t, env, want, on_disk = false) || !expect_committed_space_ok(t, env) {
				return
			}
		}
	}
	testing.expect(t, loose_seen > 0 && freed_seen > 0 && runs_seen > 0, "the free list was not exercised")
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
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	pending := slice.clone(env.free.pending[:], context.temp_allocator)
	testing.expect(t, len(pending) > 0, "nothing on the free list")

	txn, _ := kv.txn_begin(env, read_only = false)
	for i in 0 ..< 2_000 {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(i)), transmute([]byte)string("lost"))
	}
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
	// nowhere to go.
	txn, _ := kv.txn_begin(env, read_only = false)
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
// meta fields that default to what a commit would write.
@(private = "file")
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
}

@(private = "file")
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

// Writes an empty database whose newest meta page (txn 5, last_pgno 40)
// holds `list`, and whose older one (txn 4) has no free list, then opens
// it. Returns the env on success.
@(private = "file")
open_hand_list :: proc(t: ^testing.T, path: string, list: Hand_List) -> (env: ^kv.Env, err: kv.Error) {
	count := len(list.records) if list.count == -1 else list.count
	flags := list.flags if list.flags != 0 else kv.PAGE_FREELIST
	header_pgno := list.header_pgno if list.header_pgno != 0 else list.run
	overflow_count := list.overflow_count if list.overflow_count != -1 else kv.freelist_run_pages(kv.DEFAULT_PAGE_SIZE, count)

	{
		w, open_err := kv.env_open(path)
		testing.expect_value(t, open_err, kv.Error.None)
		if open_err != .None {
			return nil, open_err
		}
		defer kv.env_close(w)
		testing.expect_value(t, kv.os_truncate(w.fd, (HAND_LAST_PGNO + 1) * kv.DEFAULT_PAGE_SIZE), kv.Error.None)
		if list.run >= 2 && list.run <= HAND_LAST_PGNO {
			buf: Page_Buf
			page := buf.bytes[:]
			h := kv.page_header(page)
			h.pgno = u64le(header_pgno)
			h.flags = u16le(flags)
			h.overflow_count = u32le(overflow_count)
			records := ([^]kv.Free_Record)(&page[kv.PAGE_HEADER_SIZE])[:len(list.records)]
			copy(records, list.records)
			write_page(t, w, list.run, page)
		}
		older := make_meta(HAND_TXN - 1, last_pgno = HAND_LAST_PGNO)
		newer := make_meta(HAND_TXN, last_pgno = HAND_LAST_PGNO)
		newer.freelist_pgno = u64le(list.run)
		newer.freelist_count = u64le(count)
		testing.expect_value(t, kv.meta_write(w, 0, older), kv.Error.None)
		testing.expect_value(t, kv.meta_write(w, 1, newer), kv.Error.None)
	}
	return kv.env_open(path)
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
		{"header page count", proc(l: ^Hand_List) {l.overflow_count = 2}},
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
