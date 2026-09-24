package kv_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import kv "../kv"

/*
Read throughput, for the cost of chunk accounting (KV-I-0004 NFR-002,
KV-T-0022): run it twice, with accounting and with it compiled out, and
compare. Reported, not asserted:

	odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_read
	odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_read -define:KV_NO_CHUNK_ACCOUNTING=true

Every workload reads a database already in the page cache, after a warm-up
pass, so with accounting on every chunk is already resident and referenced
and page_ptr takes its fast path: the steady state of a store under its
budget. Only the registration is guarded, as for the free-list cost.
*/
when #config(KV_BENCH, false) {
	@(test)
	test_bench_read :: proc(t: ^testing.T) {
		bench_read(t)
	}
}

@(private = "file")
READ_BENCH_KEYS :: 200_000
@(private = "file")
READ_BENCH_BIG_KEYS :: 5_000
@(private = "file")
READ_BENCH_THREADS :: 4

@(private = "file")
Read_Workload :: enum {
	// Random gets over every key (100-byte values): a path of pages per get.
	Get_Random,
	// Random gets over the first 1,000 keys: a few hot chunks.
	Get_Hot,
	// A forward cursor over every key.
	Scan,
	// Random gets of 8 KiB overflow values, reading each value's first and
	// last byte.
	Get_Overflow,
	// Get_Random on READ_BENCH_THREADS threads at once, each with its own
	// read transaction: the time per get of all of them together.
	Get_Random_Threads,
}

@(private = "file")
Read_Bench :: struct {
	env:     ^kv.Env,
	keys:    []u64,
	gets:    int,
	sink:    int,
	barrier: ^sync.Barrier,
}

@(private = "file")
bench_read :: proc(t: ^testing.T) {
	RUNS :: 9
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, err := kv.env_open(temp_dir_file(dir, DB), kv.Options{map_size = 1 << 30})
	if !testing.expect_value(t, err, kv.Error.None) {
		return
	}
	defer kv.env_close(env)

	// Small values under keys 0 ..< READ_BENCH_KEYS, 8 KiB values after.
	{
		txn, _ := kv.txn_begin(env, read_only = false)
		for k in 0 ..< READ_BENCH_KEYS + READ_BENCH_BIG_KEYS {
			key: [8]byte
			size := 100 if k < READ_BENCH_KEYS else 8 * 1024
			if put_err := kv.put(&txn, u64_key(&key, u64(k)), patterned(size, u32(k))); put_err != .None {
				testing.expectf(t, false, "put: %v", put_err)
				kv.txn_abort(&txn)
				return
			}
		}
		if !testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None) {
			return
		}
	}
	small := make([]u64, READ_BENCH_KEYS, context.temp_allocator)
	for &k, i in small {
		k = u64(i)
	}
	rand.shuffle(small)
	hot := make([]u64, READ_BENCH_KEYS, context.temp_allocator)
	for &k in hot {
		k = u64(rand.int_max(1_000))
	}
	big := make([]u64, READ_BENCH_BIG_KEYS * 20, context.temp_allocator)
	for &k in big {
		k = u64(READ_BENCH_KEYS + rand.int_max(READ_BENCH_BIG_KEYS))
	}

	sink := 0
	per_op: [Read_Workload][RUNS]f64
	for w in Read_Workload {
		for run in -1 ..< RUNS { // run -1 warms up
			ops: int
			start := time.tick_now()
			switch w {
			case .Get_Random:
				ops = read_gets(env, small, &sink)
			case .Get_Hot:
				ops = read_gets(env, hot, &sink)
			case .Get_Overflow:
				ops = read_gets(env, big, &sink)
			case .Scan:
				txn, _ := kv.txn_begin(env)
				c := kv.cursor_open(&txn)
				for k, _, e := kv.cursor_first(&c); e == .None; k, _, e = kv.cursor_next(&c) {
					sink += int(k[7])
					ops += 1
				}
				kv.txn_abort(&txn)
			case .Get_Random_Threads:
				ops = read_gets_threaded(env, small)
			}
			elapsed := time.tick_since(start)
			if run >= 0 {
				per_op[w][run] = f64(time.duration_nanoseconds(elapsed)) / f64(ops)
			}
		}
	}

	log.infof("read throughput, chunk accounting %s (sink %d), %v", "ON" if kv.CHUNK_ACCOUNTING else "OFF", sink, kv.env_stats(env))
	for w in Read_Workload {
		slice.sort(per_op[w][:])
		log.infof("%-20v ns/op median %7s  min %7s  max %7s", w,
			fmt.tprintf("%.1f", per_op[w][RUNS / 2]), fmt.tprintf("%.1f", per_op[w][0]), fmt.tprintf("%.1f", per_op[w][RUNS - 1]))
	}
}

// Gets every key in `keys` in one read transaction; returns the number of
// gets.
@(private = "file")
read_gets :: proc(env: ^kv.Env, keys: []u64, sink: ^int) -> int {
	txn, _ := kv.txn_begin(env)
	defer kv.txn_abort(&txn)
	for k in keys {
		key: [8]byte
		v, err := kv.get(&txn, u64_key(&key, k))
		if err == .None {
			sink^ += int(v[0]) + int(v[len(v) - 1])
		}
	}
	return len(keys)
}

@(private = "file")
read_gets_threaded :: proc(env: ^kv.Env, keys: []u64) -> int {
	barrier: sync.Barrier
	sync.barrier_init(&barrier, READ_BENCH_THREADS)
	benches: [READ_BENCH_THREADS]Read_Bench
	threads: [READ_BENCH_THREADS]^thread.Thread
	for i in 0 ..< READ_BENCH_THREADS {
		// Each thread its own rotation of the keys.
		benches[i] = {env = env, keys = keys, gets = i * len(keys) / READ_BENCH_THREADS, barrier = &barrier}
		threads[i] = thread.create_and_start_with_poly_data(&benches[i], proc(b: ^Read_Bench) {
			from := b.gets
			rotated := make([]u64, len(b.keys))
			defer delete(rotated)
			copy(rotated, b.keys[from:])
			copy(rotated[len(b.keys) - from:], b.keys[:from])
			sync.barrier_wait(b.barrier)
			b.gets = read_gets(b.env, rotated, &b.sink)
		})
	}
	thread.join_multiple(..threads[:])
	total := 0
	for th, i in threads {
		thread.destroy(th)
		total += benches[i].gets
	}
	return total
}
