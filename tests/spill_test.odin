package kv_tests

import "core:bytes"
import "core:slice"
import "core:testing"

import kv "../kv"

// Spilling (KV-I-0004 D2–D6, KV-T-0021): with the smallest dirty-page pool
// (MIN_DIRTY_PAGES, 49 pages), transactions many times larger than the pool
// commit and read back, spilled pages stay the transaction's own, and an
// abort after spilling leaves the database and its free list as they were.

// The value of key `i` after round `round`: 1 in 16 is an overflow value of
// 1–3 pages, the rest are 50–300 bytes (temp allocator).
@(private = "file")
spill_value :: proc(i, round: int, ps: int) -> []byte {
	h := u32(i) * 2654435761 + u32(round) * 40503
	if i % 16 == 5 {
		return patterned(ps + int(h % u32(2 * ps)), h)
	}
	return patterned(50 + int(h % 251), h)
}

// Puts keys [from, to) with round `round`'s values, checking after every put
// that the pool is within its budget.
@(private = "file")
spill_put_range :: proc(t: ^testing.T, txn: ^kv.Txn, from, to, round: int, loc := #caller_location) -> bool {
	for i in from ..< to {
		key: [8]byte
		if err := kv.put(txn, u64_key(&key, u64(i)), spill_value(i, round, txn.env.page_size)); err != .None {
			testing.expectf(t, false, "put %d: %v", i, err, loc = loc)
			return false
		}
		if !expect_pool_within(t, txn.env, loc) {
			return false
		}
	}
	return true
}

// Checks that `txn` holds exactly keys [0, n), each with round `round`'s
// value, through get and through a cursor walking forward and backward; and
// that its tree and pages check out.
@(private = "file")
expect_spill_keys :: proc(t: ^testing.T, txn: ^kv.Txn, n, round: int, loc := #caller_location) -> bool {
	ps := txn.env.page_size
	if !testing.expect_value(t, txn.snapshot.entries, u64(n), loc = loc) {
		return false
	}
	for i in 0 ..< n {
		key: [8]byte
		got, err := kv.get(txn, u64_key(&key, u64(i)))
		if err != .None || !bytes.equal(got, spill_value(i, round, ps)) {
			testing.expectf(t, false, "get %d: %v, or a wrong value", i, err, loc = loc)
			return false
		}
	}
	c := kv.cursor_open(txn)
	i := 0
	for key, value, err := kv.cursor_first(&c); err != .Not_Found; key, value, err = kv.cursor_next(&c) {
		want: [8]byte
		if err != .None || i >= n || !bytes.equal(key, u64_key(&want, u64(i))) || !bytes.equal(value, spill_value(i, round, ps)) {
			testing.expectf(t, false, "forward cursor at %d: %v, or a wrong entry", i, err, loc = loc)
			return false
		}
		i += 1
	}
	for key, value, err := kv.cursor_last(&c); err != .Not_Found; key, value, err = kv.cursor_prev(&c) {
		i -= 1
		want: [8]byte
		if err != .None || i < 0 || !bytes.equal(key, u64_key(&want, u64(i))) || !bytes.equal(value, spill_value(i, round, ps)) {
			testing.expectf(t, false, "backward cursor at %d: %v, or a wrong entry", i, err, loc = loc)
			return false
		}
	}
	return testing.expectf(t, i == 0, "backward cursor stopped at %d", i, loc = loc) && expect_tree_ok(t, txn, loc) && expect_space_ok(t, txn, loc)
}

// Checks that the file was grown before anything was written past its end:
// every page the transaction spilled is inside the size the Env records
// (and env_stats reports), and that size is the file's.
@(private = "file")
expect_file_covers_spills :: proc(t: ^testing.T, txn: ^kv.Txn, loc := #caller_location) -> bool {
	size, err := kv.os_file_size(txn.env.fd)
	ok := testing.expect_value(t, err, kv.Error.None, loc = loc)
	ok &&= testing.expectf(t, size == txn.env.file_size, "the file has %d bytes, the Env records %d", size, txn.env.file_size, loc = loc)
	ok &&= testing.expect_value(t, i64(kv.env_stats(txn.env).file_pages) * i64(txn.env.page_size), txn.env.file_size, loc = loc)
	for pgno, pages in txn.write.spilled {
		end := (i64(pgno) + i64(pages)) * i64(txn.env.page_size)
		if !testing.expectf(t, end <= txn.env.file_size, "spilled page %d ends past the file's %d bytes", pgno, txn.env.file_size, loc = loc) {
			return false
		}
	}
	return ok
}

// Transactions writing ten times the smallest pool, and more, commit: an
// insert of 3,000 keys into an empty database, an overwrite of every key
// (copy-on-write of a committed tree, with spilled copies re-touched), and a
// delete of half of them. Every key reads back through get and both cursor
// directions before and after each commit, and the pool never holds more
// than its budget.
@(test)
test_spill_ten_times_the_pool :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB), kv.Options{dirty_budget = MIN_DIRTY_BUDGET})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	testing.expect_value(t, env.pool.slots, kv.MIN_DIRTY_PAGES)
	N :: 3_000

	// Round 0: insert.
	if !spill_put_range(t, &txn, 0, N, 0) {
		return
	}
	written := len(dirty_pages(&txn))
	testing.expectf(t, written >= 10 * kv.MIN_DIRTY_PAGES, "the transaction wrote only %d pages", written)
	testing.expect(t, kv.env_stats(env).spills > 0, "nothing was spilled")
	testing.expect(t, len(txn.write.spilled) > 0, "no page is spilled")
	if !expect_file_covers_spills(t, &txn) || !expect_spill_keys(t, &txn, N, 0) || !commit_ok(t, env, &txn) {
		return
	}
	check_committed :: proc(t: ^testing.T, env: ^kv.Env, n, round: int) -> bool {
		r, _ := kv.txn_begin(env)
		defer kv.txn_abort(&r)
		return expect_spill_keys(t, &r, n, round)
	}
	if !check_committed(t, env, N, 0) {
		return
	}

	// Round 1: overwrite every key.
	spills := kv.env_stats(env).spills
	txn, _ = kv.txn_begin(env, read_only = false)
	if !spill_put_range(t, &txn, 0, N, 1) {
		return
	}
	testing.expectf(t, len(dirty_pages(&txn)) >= 10 * kv.MIN_DIRTY_PAGES, "the overwrite wrote only %d pages", len(dirty_pages(&txn)))
	testing.expect(t, kv.env_stats(env).spills > spills, "the overwrite spilled nothing")
	if !expect_spill_keys(t, &txn, N, 1) || !commit_ok(t, env, &txn) || !check_committed(t, env, N, 1) {
		return
	}

	// Round 1 still: delete the upper half, odd keys first, so every leaf
	// of that half is copied before any empties.
	spills = kv.env_stats(env).spills
	txn, _ = kv.txn_begin(env, read_only = false)
	for parity in 0 ..< 2 {
		for i := N / 2 + 1 - parity; i < N; i += 2 {
			if !testing.expect_value(t, del_u64(&txn, i), kv.Error.None) || !expect_pool_within(t, env) {
				return
			}
		}
	}
	testing.expect(t, kv.env_stats(env).spills > spills, "the delete spilled nothing")
	if !expect_spill_keys(t, &txn, N / 2, 1) || !commit_ok(t, env, &txn) {
		return
	}
	check_committed(t, env, N / 2, 1)
	s := kv.env_stats(env)
	testing.expect(t, s.dirty_pages == 0 && s.dirty_committed == 0, "pool in use after the commit")
}

// A spilled page is still the transaction's own: touching it again brings
// it back into the pool under the same page number, with no copy-on-write,
// and freeing it (a spilled sibling merged into a page on the path, or a
// spilled overflow run replaced) puts it on `loose`, not `freed`.
@(test)
test_spill_retouch_and_free :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	ps := kv.DEFAULT_PAGE_SIZE

	// Three leaves under a root: A (keys 0–5), B (6–15), C (16–25). A leaf
	// of 4 is under a quarter and merges with one of up to 14.
	leaves := [][]Entry{sized_entries(0, 6), sized_entries(6, 10), sized_entries(16, 10)}
	build_tree_shape(t, path, leaves, {{3}})
	env, txn, ok := open_write(t, path, kv.Options{dirty_budget = MIN_DIRTY_BUDGET})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)

	leaf_of :: proc(txn: ^kv.Txn, k: int) -> kv.Pgno {
		key: [8]byte
		p: kv.Path
		kv.tree_search(txn, u64_key(&key, u64(k)), &p)
		return kv.path_leaf(&p).pgno
	}
	put_shape :: proc(txn: ^kv.Txn, k: int) -> kv.Error {
		key: [8]byte
		return kv.put(txn, u64_key(&key, u64(k)), sized_entries(k, 1)[0].value)
	}

	// B is copied by an overwrite, then left alone while keys added after C
	// fill the pool, until it is spilled: it was touched first.
	testing.expect_value(t, put_shape(&txn, 6), kv.Error.None)
	b := leaf_of(&txn, 6)
	testing.expect(t, b in txn.write.dirty, "B not dirty after the overwrite")
	added := 0
	for added < 5_000 && (b not_in txn.write.spilled) {
		if put_shape(&txn, 1_000 + added) != .None || !expect_pool_within(t, env) {
			testing.fail_now(t, "put failed")
		}
		added += 1
	}
	testing.expect(t, b in txn.write.spilled && b not_in txn.write.dirty, "B never spilled")
	expect_space_ok(t, &txn)
	// The values are inline, so the spills alone took the file past its
	// end.
	expect_file_covers_spills(t, &txn)

	// Touching a spilled page (one the puts above created) keeps its page
	// number: nothing is freed, nothing allocated.
	retouched := false
	for pgno, pages in txn.write.spilled {
		page := kv.page_ptr(&txn, pgno)
		if pgno == b || pages != 1 || !kv.page_is_leaf(page) {
			continue
		}
		k := int(u64_from_key(kv.node_key(page, 0)))
		freed, loose, last := len(txn.write.freed), len(txn.write.loose), txn.snapshot.last_pgno
		testing.expect_value(t, put_shape(&txn, k), kv.Error.None)
		testing.expect_value(t, leaf_of(&txn, k), pgno)
		testing.expect(t, pgno in txn.write.dirty && pgno not_in txn.write.spilled, "re-touched page not back in the pool")
		testing.expect_value(t, len(txn.write.freed), freed)
		testing.expect_value(t, len(txn.write.loose), loose)
		testing.expect_value(t, txn.snapshot.last_pgno, last)
		retouched = true
		break
	}
	testing.expect(t, retouched, "no spilled leaf to touch")
	testing.expect(t, b in txn.write.spilled, "B no longer spilled")

	// Deleting from A until it is underfull merges B, still spilled, into
	// A's copy: B is dropped without being touched, and is loose.
	testing.expect_value(t, del_u64(&txn, 0), kv.Error.None)
	testing.expect_value(t, del_u64(&txn, 1), kv.Error.None)
	testing.expect_value(t, leaf_of(&txn, 6), leaf_of(&txn, 2))
	testing.expect(t, slice.contains(txn.write.loose[:], b), "the merged spilled page is not loose")
	testing.expect(t, !slice.contains(txn.write.freed[:], b), "the merged spilled page was freed")
	testing.expect(t, b not_in txn.write.spilled && b not_in txn.write.dirty, "the merged page is still the transaction's")
	expect_space_ok(t, &txn)

	// An overflow run is written straight to the file, and is spilled from
	// the start; replacing its value makes its pages loose.
	big := transmute([]byte)string("big")
	dirty_before := kv.env_stats(env).dirty_pages
	value := patterned(3 * ps, 9)
	testing.expect_value(t, kv.put(&txn, big, value), kv.Error.None)
	run := kv.Pgno(0)
	for pgno, pages in txn.write.spilled {
		if int(pages) == kv.overflow_pages(ps, len(value)) {
			run = pgno
		}
	}
	testing.expect(t, run != 0 && run not_in txn.write.dirty, "the run is not spilled")
	testing.expect(t, kv.env_stats(env).dirty_pages <= dirty_before + 2 * int(txn.snapshot.depth) + 1, "the run went through the pool")
	got, _ := kv.get(&txn, big)
	testing.expect(t, bytes.equal(got, value), "overflow value differs")
	offset := uintptr(raw_data(got)) - uintptr(env.map_base)
	testing.expect_value(t, offset, uintptr(run) * uintptr(ps) + kv.PAGE_HEADER_SIZE)
	testing.expect_value(t, kv.put(&txn, big, transmute([]byte)string("small")), kv.Error.None)
	for i in 0 ..< kv.overflow_pages(ps, len(value)) {
		p := run + kv.Pgno(i)
		testing.expectf(t, slice.contains(txn.write.loose[:], p) && !slice.contains(txn.write.freed[:], p), "run page %d not loose", p)
	}
	testing.expect(t, run not_in txn.write.spilled, "replaced run still spilled")
	expect_space_ok(t, &txn)

	// The commit lists B and the run's pages as reusable at once.
	if !commit_ok(t, env, &txn) {
		return
	}
	for r in env.free.pending {
		p := kv.Pgno(r.pgno)
		testing.expectf(t, p != b && (p < run || p >= run + kv.Pgno(kv.overflow_pages(ps, len(value)))), "page %d pending, want reusable", p)
	}
	reader, _ := kv.txn_begin(env)
	defer kv.txn_abort(&reader)
	testing.expect_value(t, reader.snapshot.entries, u64(26 - 2 + added + 1))
	for k in 2 ..< 26 {
		key: [8]byte
		got_v, err := kv.get(&reader, u64_key(&key, u64(k)))
		testing.expectf(t, err == .None && bytes.equal(got_v, sized_entries(k, 1)[0].value), "key %d: %v", k, err)
	}
	v, _ := kv.get(&reader, big)
	testing.expect_value(t, string(v), "small")
}

// The key's integer, as u64_key writes it.
@(private = "file")
u64_from_key :: proc(key: []byte) -> u64 {
	v: u64
	for b in key {
		v = v << 8 | u64(b)
	}
	return v
}

// An abort after spilling leaves the database and the free list as they
// were: the spilled pages are free pages of the last commit, or past its
// last page, and nothing refers to them. The next commit is clean.
@(test)
test_spill_abort :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = MIN_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	N :: 2_000
	// Two commits, so that the second frees pages and the free list has
	// something in it.
	for round in 0 ..< 2 {
		txn, _ := kv.txn_begin(env, read_only = false)
		if !spill_put_range(t, &txn, 0, N, round) || !commit_ok(t, env, &txn) {
			kv.txn_abort(&txn)
			return
		}
	}
	before := kv.env_snapshot(env)
	ready := slice.clone(env.free.ready[:], context.temp_allocator)
	pending := slice.clone(env.free.pending[:], context.temp_allocator)
	testing.expect(t, len(ready) + len(pending) > 0, "empty free list")

	// Overwrite and add keys, spilling many times, then abort.
	spills := kv.env_stats(env).spills
	txn, _ := kv.txn_begin(env, read_only = false)
	if !spill_put_range(t, &txn, 0, 2 * N, 2) {
		kv.txn_abort(&txn)
		return
	}
	for i in 0 ..< N / 4 {
		testing.expect_value(t, del_u64(&txn, 4 * i), kv.Error.None)
	}
	testing.expect(t, kv.env_stats(env).spills > spills, "nothing was spilled")
	expect_space_ok(t, &txn)
	expect_file_covers_spills(t, &txn)
	kv.txn_abort(&txn)

	testing.expect_value(t, kv.env_snapshot(env), before)
	testing.expect(t, slice.equal(env.free.ready[:], ready), "ready pages changed")
	testing.expect(t, slice.equal(env.free.pending[:], pending), "pending records changed")
	s := kv.env_stats(env)
	testing.expect(t, s.dirty_pages == 0 && s.dirty_committed == 0, "pool in use after the abort")
	{
		r, _ := kv.txn_begin(env)
		defer kv.txn_abort(&r)
		expect_spill_keys(t, &r, N, 1)
	}

	// Commit something else: a new key.
	txn, _ = kv.txn_begin(env, read_only = false)
	if !spill_put_range(t, &txn, N, N + 1, 1) {
		kv.txn_abort(&txn)
		return
	}
	commit_ok(t, env, &txn)
	r, _ := kv.txn_begin(env)
	defer kv.txn_abort(&r)
	expect_spill_keys(t, &r, N + 1, 1)
}

// A reader holding a snapshot across transactions that spill still reads
// its data: spilled pages are never pages of a snapshot anyone can read.
@(test)
test_spill_reader_keeps_snapshot :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = MIN_DIRTY_BUDGET})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	N :: 1_500

	txn, _ := kv.txn_begin(env, read_only = false)
	if !spill_put_range(t, &txn, 0, N, 0) || !commit_ok(t, env, &txn) {
		kv.txn_abort(&txn)
		return
	}
	// Held from round 0, and a second reader from round 2.
	held, _ := kv.txn_begin(env)
	defer kv.txn_abort(&held)
	later: kv.Txn
	defer kv.txn_abort(&later)
	spills := kv.env_stats(env).spills
	for round in 1 ..= 5 {
		txn, _ = kv.txn_begin(env, read_only = false)
		// Overwrite, then delete a third and put it back: pages are copied,
		// merged and split, freed, and reused once no reader holds them.
		if !spill_put_range(t, &txn, 0, N, round) {
			kv.txn_abort(&txn)
			return
		}
		for i := 0; i < N; i += 3 {
			testing.expect_value(t, del_u64(&txn, i), kv.Error.None)
		}
		if !spill_put_range(t, &txn, 0, N, round) || !commit_ok(t, env, &txn) {
			kv.txn_abort(&txn)
			return
		}
		if !expect_spill_keys(t, &held, N, 0) {
			return
		}
		if round == 2 {
			later, _ = kv.txn_begin(env)
		}
		if round > 2 && !expect_spill_keys(t, &later, N, 2) {
			return
		}
	}
	testing.expect(t, kv.env_stats(env).spills > spills, "nothing was spilled")
}

// A value much larger than the pool commits: it is written straight to the
// file from the caller's buffer, through one slot, and reads back whole
// before and after the commit.
@(test)
test_spill_value_larger_than_pool :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB), kv.Options{dirty_budget = MIN_DIRTY_BUDGET})
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	ps := env.page_size

	// Runs ending at a page boundary and one byte past it, a run of one
	// page, and short runs whose last page is mostly padding, so that the
	// first, whole and last pages are all exercised.
	sizes := []int{10 * MIN_DIRTY_BUDGET - kv.PAGE_HEADER_SIZE, 10 * MIN_DIRTY_BUDGET + 1, ps - kv.PAGE_HEADER_SIZE - 100, ps, 2 * ps + 7}
	for size, i in sizes {
		key: [8]byte
		testing.expect_value(t, kv.put(&txn, u64_key(&key, u64(i)), patterned(size, u32(i))), kv.Error.None)
		testing.expect(t, expect_pool_within(t, env), "pool over budget")
		testing.expect(t, kv.env_stats(env).dirty_pages <= 2, "the value went through the pool")
	}
	expect_file_covers_spills(t, &txn)
	check :: proc(t: ^testing.T, txn: ^kv.Txn, sizes: []int) {
		for size, i in sizes {
			key: [8]byte
			got, err := kv.get(txn, u64_key(&key, u64(i)))
			testing.expectf(t, err == .None && bytes.equal(got, patterned(size, u32(i))), "value %d (%d bytes): %v", i, size, err)
			testing.expect_value(t, uintptr(raw_data(got)) % 16, 0)
		}
		expect_space_ok(t, txn)
	}
	check(t, &txn, sizes)
	if !commit_ok(t, env, &txn) {
		return
	}
	r, _ := kv.txn_begin(env)
	defer kv.txn_abort(&r)
	check(t, &r, sizes)
	// The bytes after each value, to the end of its run, are zero.
	for size, i in sizes {
		key: [8]byte
		got, _ := kv.get(&r, u64_key(&key, u64(i)))
		pad := kv.overflow_pages(ps, size) * ps - kv.PAGE_HEADER_SIZE - size
		tail := ([^]byte)(raw_data(got))[size:size + pad]
		testing.expectf(t, pad == 0 || slice.all_of(tail, 0), "value %d: padding not zero", i)
	}
}
