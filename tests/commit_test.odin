package kv_tests

import "core:bytes"
import "core:fmt"
import "core:slice"
import "core:sync"
import "core:sys/posix"
import "core:testing"

import kv "../kv"

// Reads meta page `slot` straight from the file and reports whether its
// checksum is valid.
read_meta :: proc(t: ^testing.T, env: ^kv.Env, slot: int) -> (meta: kv.Meta, valid: bool) {
	buf: Page_Buf
	page := read_page(t, env, kv.Pgno(slot), &buf)
	meta = kv.page_meta(page)^
	return meta, meta.magic == kv.MAGIC && u64(meta.checksum) == kv.meta_checksum(&meta)
}

// Puts even_entries(n) in one write transaction and commits it.
commit_entries :: proc(t: ^testing.T, env: ^kv.Env, entries: []Entry) -> bool {
	txn, err := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return false
	}
	defer kv.txn_abort(&txn)
	for e in entries {
		if put_err := kv.put(&txn, e.key, e.value); put_err != .None {
			testing.expectf(t, false, "put failed: %v", put_err)
			return false
		}
	}
	commit_err := kv.txn_commit(&txn)
	testing.expect_value(t, commit_err, kv.Error.None)
	return commit_err == .None
}

@(test)
test_commit_and_reopen :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	n := 20_000
	big := patterned(5 * kv.DEFAULT_PAGE_SIZE, 99)
	{
		env, err := kv.env_open(path)
		testing.expect_value(t, err, kv.Error.None)
		if err != .None {
			return
		}
		testing.expect(t, commit_entries(t, env, even_entries(n)), "commit failed")

		txn, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), big), kv.Error.None)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		kv.txn_abort(&txn) // no-op after commit

		snap := kv.env_snapshot(env)
		testing.expect_value(t, snap.txn_id, 2)
		testing.expect_value(t, snap.entries, u64(n + 1))
		testing.expect_value(t, sync.atomic_load(&env.active_txns), 0)
		kv.env_close(env)
	}

	env, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	testing.expect_value(t, txn.snapshot.txn_id, 2)
	expect_even_entries(t, &txn, n)

	// The overflow value comes back as one slice straight from the map.
	got, err := kv.get(&txn, transmute([]byte)string("big"))
	testing.expect_value(t, err, kv.Error.None)
	testing.expect(t, bytes.equal(got, big), "overflow value differs after reopen")
	p := uintptr(raw_data(got))
	testing.expect(t, p >= uintptr(env.map_base) && p + uintptr(len(got)) <= uintptr(env.map_base) + uintptr(env.map_size), "overflow value not in the map")
	testing.expect(t, expect_tree_ok(t, &txn), "tree invalid after reopen")
}

@(test)
test_commits_alternate_meta_pages :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	for i in 1 ..= 100 {
		txn, _ := kv.txn_begin(env, read_only = false)
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(i)), transmute([]byte)fmt.tprintf("%d", i))
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)

		// Commit i went to slot i & 1; the other slot holds commit i - 1.
		newer, newer_ok := read_meta(t, env, i & 1)
		older, older_ok := read_meta(t, env, 1 - i & 1)
		if !newer_ok || !older_ok || newer.txn_id != u64le(i) || older.txn_id != u64le(i - 1) {
			testing.expectf(t, false, "commit %d: slot %d has txn %d (%v), slot %d has txn %d (%v)",
				i, i & 1, newer.txn_id, newer_ok, 1 - i & 1, older.txn_id, older_ok)
			break
		}
	}
	kv.env_close(env)

	snap, _ := reopen_snapshot(t, path)
	testing.expect_value(t, snap.txn_id, 100)
	testing.expect_value(t, snap.entries, 100)
}

@(test)
test_commit_falls_back_when_newest_meta_damaged :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	commit_entries(t, env, even_entries(500))
	// A second commit changes every value and adds more keys.
	second := make([]Entry, 800, context.temp_allocator)
	for &e, i in second {
		key := make([]byte, 8, context.temp_allocator)
		u64_key((^[8]byte)(raw_data(key)), u64(2 * i))
		e = {key, transmute([]byte)string("second")}
	}
	commit_entries(t, env, second)
	testing.expect_value(t, kv.env_snapshot(env).txn_id, 2)
	kv.env_close(env)

	// Damage the newest meta page (txn 2, in slot 0): the database opens at
	// the first commit, exactly as it was.
	corrupt_meta(t, path, 0)
	env2, txn, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env2)
	defer kv.txn_abort(&txn)
	testing.expect_value(t, txn.snapshot.txn_id, 1)
	testing.expect_value(t, txn.snapshot.entries, 500)
	expect_even_entries(t, &txn, 500)
	expect_tree_ok(t, &txn)
}

@(test)
test_commit_map_full_then_abort :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	options := kv.Options{map_size = 256 * 1024}

	env, err := kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	commit_entries(t, env, even_entries(200))

	txn, _ := kv.txn_begin(env, read_only = false)
	value: [200]byte
	put_err: kv.Error
	for i in 0 ..< 100_000 {
		key: [8]byte
		put_err = kv.put(&txn, u64_key(&key, u64(1_000_000 + i)), value[:])
		if put_err != .None {
			break
		}
	}
	testing.expect_value(t, put_err, kv.Error.Map_Full)
	kv.txn_abort(&txn)

	// A smaller transaction still commits.
	txn2, _ := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, kv.put(&txn2, transmute([]byte)string("after"), transmute([]byte)string("full")), kv.Error.None)
	testing.expect_value(t, kv.txn_commit(&txn2), kv.Error.None)
	testing.expect(t, env.file_size <= i64(env.map_size), "file grew past the map")
	kv.env_close(env)

	env3, reader, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env3)
	defer kv.txn_abort(&reader)
	expect_even_entries(t, &reader, 200)
	value_after, get_err := kv.get(&reader, transmute([]byte)string("after"))
	testing.expect(t, get_err == .None && string(value_after) == "full", "last commit lost")
	testing.expect_value(t, reader.snapshot.entries, 201)
}

@(test)
test_commit_without_changes :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	commit_entries(t, env, even_entries(10))
	before := kv.env_snapshot(env)
	size_before := env.file_size
	meta0, _ := read_meta(t, env, 0)
	meta1, _ := read_meta(t, env, 1)

	// A write transaction that changes nothing.
	txn, _ := kv.txn_begin(env, read_only = false)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	// A read-only transaction: commit just ends it.
	reader, _ := kv.txn_begin(env)
	testing.expect_value(t, kv.txn_commit(&reader), kv.Error.None)
	testing.expect(t, reader.done, "read-only commit did not end the transaction")

	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect_value(t, env.file_size, size_before)
	after0, _ := read_meta(t, env, 0)
	after1, _ := read_meta(t, env, 1)
	testing.expect(t, after0 == meta0 && after1 == meta1, "meta pages changed")
	testing.expect_value(t, sync.atomic_load(&env.active_txns), 0)
}

@(test)
test_commit_poisoned_txn :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	before := kv.env_snapshot(env)

	txn, _ := kv.txn_begin(env, read_only = false)
	kv.put(&txn, transmute([]byte)string("k"), transmute([]byte)string("v"))
	// As if a put had failed part-way.
	txn.err = .Out_Of_Memory
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("k2"), nil), kv.Error.Out_Of_Memory)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.Out_Of_Memory)

	testing.expect(t, txn.done, "failed commit must end the transaction")
	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, sync.mutex_try_lock(&env.writer_mutex), "writer lock not released")
	sync.mutex_unlock(&env.writer_mutex)
}

@(test)
test_commit_io_error_rolls_back :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)

	env, err := kv.env_open(path)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	commit_entries(t, env, even_entries(100))
	before := kv.env_snapshot(env)

	txn, _ := kv.txn_begin(env, read_only = false)
	for i in 0 ..< 5_000 {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(2 * i + 1)), transmute([]byte)string("lost"))
	}
	// Make every write fail.
	fd := env.fd
	env.fd = posix.FD(-1)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.Io)
	env.fd = fd

	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, sync.mutex_try_lock(&env.writer_mutex), "writer lock not released")
	sync.mutex_unlock(&env.writer_mutex)
	kv.env_close(env)

	env2, reader, ok := open_read(t, path)
	if !ok {
		return
	}
	defer kv.env_close(env2)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, reader.snapshot.txn_id, before.txn_id)
	expect_even_entries(t, &reader, 100)
}

@(test)
test_commit_file_growth :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ps := i64(env.page_size)
	testing.expect_value(t, env.file_size, 2 * ps)

	// The first commit grows the file by at least FILE_GROWTH_MIN.
	commit_entries(t, env, even_entries(10))
	testing.expect_value(t, env.file_size, 2 * ps + kv.FILE_GROWTH_MIN)
	size, _ := kv.os_file_size(env.fd)
	testing.expect_value(t, size, env.file_size)

	// Small commits fit in the space already there.
	commit_entries(t, env, even_entries(20))
	testing.expect_value(t, env.file_size, 2 * ps + kv.FILE_GROWTH_MIN)

	// A large commit grows it to cover everything, page-aligned.
	commit_entries(t, env, {{transmute([]byte)string("huge"), patterned(3 << 20, 5)}})
	snap := kv.env_snapshot(env)
	testing.expect(t, env.file_size >= (i64(snap.last_pgno) + 1) * ps, "file smaller than the snapshot")
	testing.expect_value(t, env.file_size % ps, 0)
}

@(test)
test_commit_replaces_committed_overflow :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	key := transmute([]byte)string("big")
	commit_entries(t, env, {{key, patterned(4 * env.page_size, 1)}})

	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	path: kv.Path
	kv.tree_search(&txn, key, &path)
	e := kv.path_leaf(&path)
	_, run, _ := kv.leaf_value(kv.page_ptr(&txn, e.pgno), e.idx)

	testing.expect_value(t, kv.put(&txn, key, transmute([]byte)string("small now")), kv.Error.None)
	// The committed run's pages are freed (not loose: readers may see them).
	for p in 0 ..< kv.overflow_pages(env.page_size, 4 * env.page_size) {
		testing.expect(t, slice.contains(txn.write.freed[:], run + kv.Pgno(p)), "committed run page not freed")
	}
	testing.expect_value(t, len(txn.write.loose), 0)
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)

	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	got, get_err := kv.get(&reader, key)
	testing.expect(t, get_err == .None && string(got) == "small now", "overwrite lost")
	expect_tree_ok(t, &reader)
}

@(test)
test_commit_snapshot_isolation :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	commit_entries(t, env, even_entries(1_000))

	old_reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&old_reader)

	txn, _ := kv.txn_begin(env, read_only = false)
	for i in 0 ..< 1_000 {
		key: [8]byte
		kv.put(&txn, u64_key(&key, u64(2 * i)), transmute([]byte)string("new"))
		kv.put(&txn, u64_key(&key, u64(2 * i + 1)), transmute([]byte)string("added"))
	}
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)

	// The reader that began before the commit still sees the old state...
	expect_even_entries(t, &old_reader, 1_000)
	testing.expect_value(t, old_reader.snapshot.entries, 1_000)

	// ...and a new one sees the new state.
	new_reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&new_reader)
	testing.expect_value(t, new_reader.snapshot.entries, 2_000)
	key: [8]byte
	value, get_err := kv.get(&new_reader, u64_key(&key, 1))
	testing.expect(t, get_err == .None && string(value) == "added", "new reader sees old state")
	expect_tree_ok(t, &new_reader)
}
