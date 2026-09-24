package kv_tests

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import "core:time"

import kv "../kv"

/*
The cost of the flat free list (KV-I-0002, "Costs, to be measured"): how a
one-key update's commit time grows with the size of the free list, which
every commit rewrites in full, including the search for a run to place it
in. Timing depends on the machine, so this is not part of the normal suite:

	odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_free_list_cost

Only the registration is guarded: the procedures below are compiled and
type-checked by every run, so the measurement can't rot.
*/
when #config(KV_BENCH, false) {
	@(test)
	test_bench_free_list_cost :: proc(t: ^testing.T) {
		bench_free_list_cost(t)
	}
}

// How the free pages lie in the file.
Bench_Layout :: enum {
	// One run of consecutive pages.
	Runs,
	// Every other page, so no two free pages are adjacent and a run search
	// scans the whole list.
	Scattered,
}

Bench_Result :: struct {
	layout:     Bench_Layout,
	// Records on the free list during the measured commits, and the pages
	// of its run.
	free:       int,
	run_pages:  int,
	// txn_begin (write) releasing the whole list from pending into ready.
	release:    time.Duration,
	// Medians over the one-key updates.
	begin:      time.Duration,
	put:        time.Duration,
	commit:     time.Duration,
	// Median page_alloc of a 2-page run in an aborted transaction.
	run_search: time.Duration,
	// Pages the measured commits added to the file.
	growth:     int,
}

bench_free_list_cost :: proc(t: ^testing.T) {
	results := make([dynamic]Bench_Result, context.temp_allocator)
	for n in ([]int{0, 100, 1_000, 10_000, 100_000}) {
		for layout in Bench_Layout {
			if n == 0 && layout != .Runs {
				continue
			}
			r, ok := bench_one(t, layout, n)
			if !ok {
				return
			}
			append(&results, r)
		}
	}
	us :: proc(d: time.Duration) -> f64 {
		return time.duration_microseconds(d)
	}
	// Each cell is formatted first and then padded, because a width on a
	// number pads it with zeros.
	log.info("   layout    free  run pages  release µs  begin µs  put µs  commit µs  2-page search µs  growth")
	for r in results {
		log.info(fmt.tprintf("%9s %7s %10s %11s %9s %7s %10s %17s %7s",
			fmt.tprint(r.layout), fmt.tprint(r.free), fmt.tprint(r.run_pages), fmt.tprintf("%.1f", us(r.release)), fmt.tprintf("%.1f", us(r.begin)),
			fmt.tprintf("%.1f", us(r.put)), fmt.tprintf("%.1f", us(r.commit)), fmt.tprintf("%.1f", us(r.run_search)), fmt.tprint(r.growth)))
	}
}

/*
Opens a database whose tree is one leaf and whose free list is `n` records
written by hand, laid out as `layout` and all freed by the last commit, so
that they are pending at open. The first commit writes the list; the next
write transaction's begin releases all of it into `ready`, and is timed.
Then 40 commits each update the one key, and a 2-page page_alloc is timed
in aborted transactions.

The pages between scattered free pages belong to nothing: space_check
would fail, but nothing else looks at them.
*/
@(private = "file")
bench_one :: proc(t: ^testing.T, layout: Bench_Layout, n: int) -> (r: Bench_Result, ok: bool) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)

	stride := 1 if layout == .Runs else 2
	records := make([]kv.Free_Record, n, context.temp_allocator)
	for &rec, i in records {
		rec = {pgno = u64le(3 + stride * i), txn_id = HAND_TXN}
	}
	run := kv.Pgno(3 + stride * n)
	last := run + kv.Pgno(kv.freelist_run_pages(kv.DEFAULT_PAGE_SIZE, n)) - 1 if n > 0 else 2
	env, err := open_hand_list(t, temp_dir_file(dir, DB), {records = records, run = run if n > 0 else 0, count = -1, overflow_count = -1, last_pgno = last, root = 2, options = {map_size = 2 << 30}})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	r.layout = layout

	M :: 40
	begins := make([]time.Duration, M, context.temp_allocator)
	puts := make([]time.Duration, M, context.temp_allocator)
	commits := make([]time.Duration, M, context.temp_allocator)
	start: kv.Pgno
	for i in -1 ..< M {
		t0 := time.tick_now()
		txn, _ := kv.txn_begin(env, read_only = false)
		t1 := time.tick_now()
		kv.put(&txn, transmute([]byte)string("k"), transmute([]byte)fmt.tprintf("update %d", i))
		t2 := time.tick_now()
		if err = kv.txn_commit(&txn); err != .None {
			testing.expectf(t, false, "commit: %v", err)
			return
		}
		t3 := time.tick_now()
		switch i {
		case -1:
			// The first commit writes the list; nothing is released yet.
		case 0:
			r.release = time.tick_diff(t0, t1)
			start = kv.env_snapshot(env).last_pgno
			s := kv.env_stats(env)
			r.free = s.free_ready + s.free_pending
		case:
			begins[i], puts[i], commits[i] = time.tick_diff(t0, t1), time.tick_diff(t1, t2), time.tick_diff(t2, t3)
		}
	}
	snap := kv.env_snapshot(env)
	r.growth = int(snap.last_pgno - start)
	r.run_pages = freelist_run_len(t, env, snap)

	searches := make([]time.Duration, M, context.temp_allocator)
	for &d in searches {
		txn, _ := kv.txn_begin(env, read_only = false)
		t0 := time.tick_now()
		kv.page_alloc(&txn, 2)
		d = time.tick_since(t0)
		kv.txn_abort(&txn)
	}

	median :: proc(d: []time.Duration) -> time.Duration {
		slice.sort(d)
		return d[len(d) / 2]
	}
	r.begin, r.put, r.commit, r.run_search = median(begins[1:]), median(puts[1:]), median(commits[1:]), median(searches)
	return r, true
}
