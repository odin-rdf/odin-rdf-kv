package kv_tests

import "core:bytes"
import "core:log"
import "core:testing"
import "core:time"

import kv "../kv"

// The dirty-page pool (KV-I-0004 D1, KV-T-0020): its budget, the live
// figures in env_stats, and the release of its memory when a write
// transaction ends. Spilling, which keeps a transaction of any size within
// the pool, is in spill_test.odin.

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

// dirty_pages counts the slots the writer holds while the transaction runs;
// every slot is page-aligned; an overflow run takes no slot once written;
// and commit and abort both leave nothing in use and nothing committed.
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

	// An overflow run is written straight to the file (KV-I-0004 D5): it
	// holds no slot, and its value is read from the map.
	big := transmute([]byte)string("big")
	value := patterned(5 * ps, 1)
	before := kv.env_stats(env).dirty_pages
	testing.expect_value(t, kv.put(&txn, big, value), kv.Error.None)
	testing.expect_value(t, kv.env_stats(env).dirty_pages, before)
	got, _ := kv.get(&txn, big)
	testing.expect(t, bytes.equal(got, value), "overflow value differs")
	testing.expect_value(t, uintptr(raw_data(got)) % 16, 0)
	testing.expect(t, uintptr(raw_data(got)) >= uintptr(env.map_base) && uintptr(raw_data(got)) < uintptr(env.map_base) + uintptr(env.map_size), "overflow value not in the map")
	for _, d in txn.write.dirty {
		testing.expect_value(t, d.pages, 1)
	}
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
// afterwards (/proc/self/pagemap on Linux, mach_vm_region on macOS). The
// transaction fills 3 MiB of the pool with small values; a large value
// would go straight to the file.
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

	fill :: proc(t: ^testing.T, txn: ^kv.Txn, size: int) {
		key: [8]byte
		for i := 0; kv.env_stats(txn.env).dirty_pages * txn.env.page_size < size; i += 1 {
			testing.expect_value(t, kv.put(txn, u64_key(&key, u64(i)), patterned(1000, u32(i))), kv.Error.None)
		}
		testing.expect_value(t, kv.env_stats(txn.env).spills, 0)
	}
	for commit in ([]bool{true, false}) {
		txn, _ := kv.txn_begin(env, read_only = false)
		fill(t, &txn, SIZE)
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
	start := time.tick_now()
	fill(t, &txn, SIZE)
	log.infof("puts filling %d KiB of the released pool (faults included): %.1f µs", SIZE >> 10, time.duration_microseconds(time.tick_since(start)))
	key: [8]byte
	got, _ := kv.get(&txn, u64_key(&key, 7))
	testing.expect(t, bytes.equal(got, patterned(1000, 7)), "value differs after the pool was released")
}

// Bytes of the pool the OS reports resident in the process.
@(private = "file")
pool_resident :: proc(env: ^kv.Env) -> int {
	r := platform_residency(env.pool.base, env.pool.reserved)
	return r.present if r.present >= 0 else r.region
}
