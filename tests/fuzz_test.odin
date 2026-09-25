package kv_tests

import "core:log"
import "core:math/rand"
import "core:testing"
import "core:time"

import kv "../kv"

// Operations per seed. At 10⁶ a seed is 8 s of CPU at 3,000 keys and 16 s
// at 10,000 with KV_NO_SYNC on macOS arm64 (KV-T-0031's measurements).
FUZZ_OPS :: #config(KV_FUZZ_OPS, 1_000_000)

// Consecutive seeds, from the runner's.
FUZZ_SEEDS :: #config(KV_FUZZ_SEEDS, 1)

// The full check of the last commit every this many transactions
// (run_model's check_every).
FUZZ_CHECK_EVERY :: #config(KV_FUZZ_CHECK_EVERY, 1)

#assert(FUZZ_OPS >= 1 && FUZZ_SEEDS >= 1 && FUZZ_CHECK_EVERY >= 1)

// The key counts a seed chooses from: few keys empty the tree and collapse
// the root often, many make it deep.
@(private = "file")
FUZZ_KEYS :: [?]int{100, 500, 1_000, 3_000, 10_000}

/*
The seeded fuzz mode (KV-I-0005 D4, D5): run_model for KV_FUZZ_OPS
operations over KV_FUZZ_SEEDS consecutive seeds from the runner's, each on a
new database. Not part of the ordinary suite or CI; run it with
-define:KV_FUZZ=true, and with KV_NO_SYNC, so that it is CPU-bound and uses
exactly the threads it is given:

	odin test tests -o:speed -define:KV_FUZZ=true -define:KV_NO_SYNC=true \
		-define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=kv_tests.test_fuzz_model \
		-define:KV_FUZZ_SEEDS=8 -define:KV_FUZZ_CHECK_EVERY=10

A seed's options come from the seed alone, not from its place in the run:
an odd seed opens with the smallest dirty-page pool (MIN_DIRTY_BUDGET) and
an even one with the default, so consecutive seeds alternate, and the key
count is picked from FUZZ_KEYS by a hash of the seed. So a failure reported
as `[seed N]` reproduces alone with the same command and
-define:ODIN_TEST_RANDOM_SEED=N -define:KV_FUZZ_SEEDS=1, keeping KV_FUZZ_OPS.
KV_FUZZ_CHECK_EVERY may change: the checks draw no random numbers, so the
same operations run, and at 1 the failure is reported at the transaction
that caused it rather than up to k transactions later.

Only the registration is guarded: the procedures are compiled and
type-checked by every run.
*/
when #config(KV_FUZZ, false) {
	@(test)
	test_fuzz_model :: proc(t: ^testing.T) {
		fuzz_model(t)
	}
}

@(private = "file")
fuzz_model :: proc(t: ^testing.T) {
	if kv.NO_SYNC {
		log.infof("KV_NO_SYNC is set: commits are not synced")
	} else {
		log.warnf("KV_NO_SYNC is not set: every commit pays two syncs (F_FULLFSYNC on macOS); pass -define:KV_NO_SYNC=true to fuzz on CPU alone")
	}
	log.infof("fuzzing %d seed(s) from %d, %d operations each, full check every %d transactions", FUZZ_SEEDS, t.seed, FUZZ_OPS, FUZZ_CHECK_EVERY)

	total_ops := 0
	start := time.tick_now()
	for i in 0 ..< FUZZ_SEEDS {
		seed := t.seed + u64(i)
		options, keys := fuzz_seed_config(seed)
		pool := "smallest pool" if options.dirty_budget != 0 else "default pool"

		dir := temp_dir_create(t)
		// Every seed starts from the runner's state for that seed, as a run
		// with ODIN_TEST_RANDOM_SEED set to it would.
		rand.reset(seed)
		seed_start := time.tick_now()
		stats, _ := run_model(t, temp_dir_file(dir, DB), options, ops = FUZZ_OPS, keys = keys, check_every = FUZZ_CHECK_EVERY, run_seed = seed)
		secs := time.duration_seconds(time.tick_since(seed_start))
		temp_dir_destroy(&dir, DB)
		free_all(context.temp_allocator)

		if testing.failed(t) {
			log.errorf("[seed %d] failed (%s, %d keys); reproduce alone with -define:ODIN_TEST_RANDOM_SEED=%d -define:KV_FUZZ_SEEDS=1 -define:KV_FUZZ_OPS=%d", seed, pool, keys, seed, FUZZ_OPS)
			return
		}
		log.infof("[seed %d] %s, %d keys: %d ops in %.1f s, %.0f ops/s; %v", seed, pool, keys, FUZZ_OPS, secs, f64(FUZZ_OPS) / secs, stats)
		total_ops += FUZZ_OPS
	}
	secs := time.duration_seconds(time.tick_since(start))
	log.infof("%d seed(s), %d ops in %.1f s, %.0f ops/s", FUZZ_SEEDS, total_ops, secs, f64(total_ops) / secs)
}

// A seed's options and key count, from the seed alone so that it reproduces
// outside a multi-seed run.
@(private = "file")
fuzz_seed_config :: proc(seed: u64) -> (options: kv.Options, keys: int) {
	options = kv.Options{map_size = 4 << 30}
	if seed % 2 == 1 {
		options.dirty_budget = MIN_DIRTY_BUDGET
	}
	key_counts := FUZZ_KEYS
	keys = key_counts[((seed * 0x9E37_79B9_7F4A_7C15) >> 32) % u64(len(key_counts))]
	return
}
