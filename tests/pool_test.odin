package kv_tests

import "core:bytes"
import "core:log"
import "core:testing"
import "core:time"

import kv "../kv"

// The dirty-page pool (KV-I-0004 D1, KV-T-0020): its budget, the live
// figures in env_stats, the release of its memory when a write transaction
// ends, and Out_Of_Memory for a transaction that doesn't fit.

// Options.dirty_budget: 0 is the default, other values are rounded up to
// whole pages of the database's own page size, and fewer than
// MIN_DIRTY_PAGES pages is refused. Opening reserves the pool and commits
// none of it.
@(test)
test_dirty_budget_options :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	ps := kv.DEFAULT_PAGE_SIZE
	min_bytes := kv.MIN_DIRTY_PAGES * ps

	cases := []struct {
		budget: int,
		want:   int,
	} {
		{0, kv.DEFAULT_DIRTY_BUDGET},
		{min_bytes, min_bytes},
		{min_bytes - ps + 1, min_bytes},
		{min_bytes + 1, min_bytes + ps},
		{min_bytes - ps, -1},
		{1, -1},
		{-1, -1},
	}
	for c in cases {
		env, err := kv.env_open(path, kv.Options{dirty_budget = c.budget})
		if c.want < 0 {
			testing.expectf(t, err == .Invalid_Argument, "budget %d: %v, want Invalid_Argument", c.budget, err)
			if err == .None {
				kv.env_close(env)
			}
			continue
		}
		testing.expectf(t, err == .None, "budget %d: %v", c.budget, err)
		if err != .None {
			continue
		}
		s := kv.env_stats(env)
		testing.expectf(t, s.dirty_budget == c.want, "budget %d: dirty_budget %d, want %d", c.budget, s.dirty_budget, c.want)
		testing.expect_value(t, s.dirty_pages, 0)
		testing.expect_value(t, s.dirty_committed, 0)
		os_ps := kv.os_page_size()
		testing.expect(t, env.pool.reserved >= c.want && env.pool.reserved % os_ps == 0, "reservation not whole OS pages covering the budget")
		testing.expect_value(t, uintptr(env.pool.base) % uintptr(os_ps), 0)
		testing.expect_value(t, pool_resident(env), 0)
		kv.env_close(env)
	}

	// An existing database keeps its page size, and the budget is counted
	// in its pages: 49 pages of 4 KiB are 13 of 16 KiB.
	big := temp_dir_file(dir, "big.db")
	defer temp_dir_destroy(&dir, "big.db")
	env, err := kv.env_open(big, kv.Options{page_size = 16384})
	testing.expect_value(t, err, kv.Error.None)
	if err == .None {
		testing.expect_value(t, kv.env_stats(env).dirty_budget, kv.DEFAULT_DIRTY_BUDGET)
		kv.env_close(env)
	}
	env, err = kv.env_open(big, kv.Options{dirty_budget = min_bytes})
	testing.expect_value(t, err, kv.Error.Invalid_Argument)
	if err == .None {
		kv.env_close(env)
	}
}

// dirty_pages counts the slots the writer holds, runs included, while the
// transaction runs; slots of a page dropped within the transaction are free
// again; every slot is page-aligned and a run's slots are consecutive; and
// commit and abort both leave nothing in use and nothing committed.
@(test)
test_dirty_pages_live :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)
	defer kv.txn_abort(&txn)
	ps := env.page_size

	expect_live :: proc(t: ^testing.T, txn: ^kv.Txn, loc := #caller_location) {
		held := 0
		for pgno, d in txn.write.dirty {
			held += int(d.pages)
			buf, _ := dirty_buf(txn, pgno)
			testing.expect_value(t, uintptr(raw_data(buf)) % uintptr(txn.env.page_size), 0, loc = loc)
		}
		s := kv.env_stats(txn.env)
		testing.expect_value(t, s.dirty_pages, held, loc = loc)
		testing.expect(t, s.dirty_committed >= held * txn.env.page_size, "fewer bytes committed than pages held", loc = loc)
	}

	key: [8]byte
	testing.expect_value(t, kv.put(&txn, u64_key(&key, 0), transmute([]byte)string("a")), kv.Error.None)
	testing.expect_value(t, kv.env_stats(env).dirty_pages, 1)
	for i in 1 ..< 300 {
		kv.put(&txn, u64_key(&key, u64(i)), patterned(100, u32(i)))
	}
	expect_live(t, &txn)
	// The root was touched by the last put, and records it.
	root := txn.write.dirty[txn.snapshot.root]
	testing.expect_value(t, env.pool.touched[root.slot], txn.mods)

	// An overflow run takes consecutive slots, and gives them back when
	// the value is replaced in the same transaction.
	big := transmute([]byte)string("big")
	value := patterned(5 * ps, 1)
	testing.expect_value(t, kv.put(&txn, big, value), kv.Error.None)
	got, _ := kv.get(&txn, big)
	testing.expect(t, bytes.equal(got, value), "overflow value differs")
	testing.expect_value(t, uintptr(raw_data(got)) % 16, 0)
	run_pgno := kv.Pgno(0)
	for pgno, d in txn.write.dirty {
		if int(d.pages) == kv.overflow_pages(ps, len(value)) {
			run_pgno = pgno
		}
	}
	testing.expect(t, run_pgno != 0, "no dirty run of the value's length")
	expect_live(t, &txn)
	before := kv.env_stats(env).dirty_pages
	testing.expect_value(t, kv.put(&txn, big, transmute([]byte)string("small")), kv.Error.None)
	testing.expect(t, run_pgno not_in txn.write.dirty, "replaced run still dirty")
	testing.expect_value(t, kv.env_stats(env).dirty_pages, before - kv.overflow_pages(ps, len(value)))
	expect_live(t, &txn)

	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	s := kv.env_stats(env)
	testing.expect(t, s.dirty_pages == 0 && s.dirty_committed == 0, "pool in use after the commit")

	// The same after an abort.
	err: kv.Error
	txn, err = kv.txn_begin(env, read_only = false)
	testing.expect_value(t, err, kv.Error.None)
	for i in 0 ..< 300 {
		kv.put(&txn, u64_key(&key, u64(i)), patterned(200, u32(i)))
	}
	expect_live(t, &txn)
	testing.expect(t, kv.env_stats(env).dirty_pages > 0, "nothing dirty")
	kv.txn_abort(&txn)
	s = kv.env_stats(env)
	testing.expect(t, s.dirty_pages == 0 && s.dirty_committed == 0, "pool in use after the abort")
	testing.expect(t, expect_latest_ok(t, env), "database damaged")
}

// The pool's memory leaves the process when the write transaction ends,
// by commit or by abort: the OS reports none of the pool's pages resident
// afterwards (/proc/self/pagemap on Linux, mach_vm_region on macOS).
@(test)
test_dirty_pool_released :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	env, err := kv.env_open(temp_dir_file(dir, DB))
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	SIZE :: 3 << 20

	for commit in ([]bool{true, false}) {
		txn, _ := kv.txn_begin(env, read_only = false)
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), patterned(SIZE, 3)), kv.Error.None)
		resident := pool_resident(env)
		testing.expectf(t, resident >= SIZE, "%d bytes of the pool resident during the transaction, want at least %d", resident, SIZE)
		testing.expect(t, kv.env_stats(env).dirty_committed >= SIZE, "committed bytes not reported")

		start := time.tick_now()
		if commit {
			testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		} else {
			kv.txn_abort(&txn)
		}
		elapsed := time.tick_since(start)
		resident = pool_resident(env)
		testing.expectf(t, resident == 0, "%d bytes of the pool still resident after %s", resident, "commit" if commit else "abort")
		testing.expect_value(t, kv.env_stats(env).dirty_committed, 0)
		if !commit {
			log.infof("abort releasing %d KiB of the pool: %.1f µs", SIZE >> 10, time.duration_microseconds(elapsed))
		}
	}

	// The released pool is usable again.
	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	value := patterned(SIZE, 4)
	start := time.tick_now()
	testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), value), kv.Error.None)
	log.infof("put of %d KiB into the released pool (faults included): %.1f µs", SIZE >> 10, time.duration_microseconds(time.tick_since(start)))
	got, _ := kv.get(&txn, transmute([]byte)string("big"))
	testing.expect(t, bytes.equal(got, value), "value differs after the pool was released")
}

// A transaction whose pages don't fit in the pool gets Out_Of_Memory from
// put, which changes nothing: the transaction goes on, and commits or
// aborts cleanly.
@(test)
test_dirty_pool_exceeded :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	// A value larger than the whole pool.
	{
		env, txn, ok := open_write(t, temp_dir_file(dir, DB))
		if !ok {
			return
		}
		defer kv.env_close(env)
		defer kv.txn_abort(&txn)
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("small"), transmute([]byte)string("x")), kv.Error.None)
		testing.expect_value(t, kv.put(&txn, transmute([]byte)string("big"), patterned(kv.DEFAULT_DIRTY_BUDGET + 1, 5)), kv.Error.Out_Of_Memory)
		testing.expect_value(t, txn.err, kv.Error.None)
		testing.expect_value(t, kv.env_stats(env).dirty_pages, 1)
		testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)

		r, _ := kv.txn_begin(env)
		defer kv.txn_abort(&r)
		_, get_err := kv.get(&r, transmute([]byte)string("big"))
		testing.expect_value(t, get_err, kv.Error.Not_Found)
		v, _ := kv.get(&r, transmute([]byte)string("small"))
		testing.expect_value(t, string(v), "x")
		expect_space_ok(t, &r)
	}

	// Many puts into the smallest pool, until one doesn't fit; then abort,
	// and the database is as it was.
	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = kv.MIN_DIRTY_PAGES * kv.DEFAULT_PAGE_SIZE})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	txn, _ := kv.txn_begin(env, read_only = false)
	key: [8]byte
	put_err := kv.Error.None
	n := 0
	for ; n < 100_000; n += 1 {
		put_err = kv.put(&txn, u64_key(&key, u64(n)), patterned(500, u32(n)))
		if put_err != .None {
			break
		}
		testing.expect(t, kv.env_stats(env).dirty_pages <= kv.MIN_DIRTY_PAGES, "more pages dirty than the pool has")
	}
	testing.expect_value(t, put_err, kv.Error.Out_Of_Memory)
	testing.expect(t, n > 0, "nothing fit")
	testing.expect_value(t, txn.err, kv.Error.None)
	v, get_err := kv.get(&txn, u64_key(&key, u64(n - 1)))
	testing.expect(t, get_err == .None && bytes.equal(v, patterned(500, u32(n - 1))), "last put lost")
	kv.txn_abort(&txn)
	s := kv.env_stats(env)
	testing.expect(t, s.dirty_pages == 0 && s.dirty_committed == 0, "pool in use after the abort")

	r, _ := kv.txn_begin(env)
	testing.expect_value(t, r.snapshot.entries, 1)
	kv.txn_abort(&r)

	// A transaction that fits commits.
	txn, _ = kv.txn_begin(env, read_only = false)
	for i in 0 ..< n / 2 {
		testing.expect_value(t, kv.put(&txn, u64_key(&key, u64(i)), patterned(500, u32(i))), kv.Error.None)
	}
	testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	expect_latest_ok(t, env)
}

// Bytes of the pool the OS reports resident in the process.
@(private = "file")
pool_resident :: proc(env: ^kv.Env) -> int {
	r := platform_residency(env.pool.base, env.pool.reserved)
	return r.present if r.present >= 0 else r.region
}
