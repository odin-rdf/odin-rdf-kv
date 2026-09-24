package kv_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

import kv "../kv"

/*
The cost of spilling (KV-I-0004 D3, KV-T-0021). The same transaction runs
with a small pool (the smallest, 49 pages, where it spills again and again,
and the default, 4 MiB, which it outgrows a little), and with a pool large
enough that it never spills; the difference in time, over the pages
spilled, is the cost of a spilled page, including copying some of them
back when they are touched again. Reported, not asserted:

	odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_spill_cost

Only the registration is guarded, as for the free-list cost.
*/
when #config(KV_BENCH, false) {
	@(test)
	test_bench_spill_cost :: proc(t: ^testing.T) {
		bench_spill_cost(t)
	}
}

// Keys in the measured transaction.
@(private = "file")
SPILL_BENCH_KEYS :: 20_000

@(private = "file")
Spill_Workload :: enum {
	// Keys in ascending order: the tree grows at its right edge, and a page
	// spilled is rarely touched again.
	Append,
	// Keys in random order into a committed tree of the same keys: every
	// put copies a path, and spilled leaves are often touched again.
	Random_Overwrite,
}

@(private = "file")
Spill_Result :: struct {
	workload:        Spill_Workload,
	budget:          int,
	// Pages the transaction wrote, and pages the small pool spilled.
	written, spills: int,
	// Medians: the puts, and the puts and the commit, with each pool.
	puts_small:      time.Duration,
	puts_big:        time.Duration,
	total_small:     time.Duration,
	total_big:       time.Duration,
}

@(private = "file")
bench_spill_cost :: proc(t: ^testing.T) {
	RUNS :: 7
	log.info("        workload  pool KiB  pages written  spilled  puts small ms  puts big ms  µs/spilled page  +commit small ms  +commit big ms  µs/spilled page")
	for workload in Spill_Workload do for budget in ([]int{MIN_DIRTY_BUDGET, kv.DEFAULT_DIRTY_BUDGET}) {
		results: [RUNS]Spill_Result
		for &r in results {
			small, small_ok := bench_spill_one(t, workload, budget)
			big, big_ok := bench_spill_one(t, workload, 64 << 20)
			if !small_ok || !big_ok {
				return
			}
			testing.expectf(t, big.spills == 0, "the big pool spilled %d pages", big.spills)
			r = small
			r.puts_big, r.total_big = big.puts_small, big.total_small
		}
		median :: proc(rs: []Spill_Result, f: proc(r: Spill_Result) -> time.Duration) -> time.Duration {
			d := make([]time.Duration, len(rs), context.temp_allocator)
			for r, i in rs {
				d[i] = f(r)
			}
			slice.sort(d)
			return d[len(d) / 2]
		}
		ps := median(results[:], proc(r: Spill_Result) -> time.Duration {return r.puts_small})
		pb := median(results[:], proc(r: Spill_Result) -> time.Duration {return r.puts_big})
		ts := median(results[:], proc(r: Spill_Result) -> time.Duration {return r.total_small})
		tb := median(results[:], proc(r: Spill_Result) -> time.Duration {return r.total_big})
		r := results[0]
		ms :: proc(d: time.Duration) -> string {
			return fmt.tprintf("%.2f", time.duration_milliseconds(d))
		}
		per :: proc(a, b: time.Duration, n: int) -> string {
			return fmt.tprintf("%.2f", time.duration_microseconds(a - b) / f64(max(n, 1)))
		}
		log.info(fmt.tprintf("%16s %9s %14s %8s %14s %12s %16s %17s %15s %16s",
			fmt.tprint(workload), fmt.tprint(budget >> 10), fmt.tprint(r.written), fmt.tprint(r.spills), ms(ps), ms(pb), per(ps, pb, r.spills), ms(ts), ms(tb), per(ts, tb, r.spills)))
	}
}

// Runs the workload once in a new database with a pool of `budget` bytes,
// and returns its figures in the `_small` fields.
@(private = "file")
bench_spill_one :: proc(t: ^testing.T, workload: Spill_Workload, budget: int) -> (r: Spill_Result, ok: bool) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{dirty_budget = budget})
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)

	keys := make([]u64, SPILL_BENCH_KEYS, context.temp_allocator)
	for &k, i in keys {
		k = u64(i)
	}
	put_all :: proc(t: ^testing.T, env: ^kv.Env, keys: []u64, round: u32) -> bool {
		txn, _ := kv.txn_begin(env, read_only = false)
		defer kv.txn_abort(&txn)
		for k in keys {
			key: [8]byte
			if err := kv.put(&txn, u64_key(&key, k), patterned(100, u32(k) + round)); err != .None {
				testing.expectf(t, false, "put: %v", err)
				return false
			}
		}
		return testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
	}
	if workload == .Random_Overwrite {
		if !put_all(t, env, keys, 0) {
			return
		}
		rand.shuffle(keys)
	}

	spills := kv.env_stats(env).spills
	txn, _ := kv.txn_begin(env, read_only = false)
	defer kv.txn_abort(&txn)
	start := time.tick_now()
	for k in keys {
		key: [8]byte
		if err = kv.put(&txn, u64_key(&key, k), patterned(100, u32(k) + 1)); err != .None {
			testing.expectf(t, false, "put: %v", err)
			return
		}
	}
	r.puts_small = time.tick_since(start)
	r.written = len(written_pgnos(&txn))
	if !testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None) {
		return
	}
	r.total_small = time.tick_since(start)
	r.workload = workload
	r.spills = kv.env_stats(env).spills - spills
	return r, true
}
