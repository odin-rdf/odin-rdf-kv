package kv_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import kv "../kv"

/*
The memory-budget criterion (KV-I-0004, the vision's success criterion;
KV-T-0024), and the capacity-planning figures for the first deployment.

A database of about 100 MB of AI agent conversations (CRIT_CONV_MSGS
messages per conversation, one entry per message, most of a few hundred
bytes and one in ten an overflow value of a few KiB, like a tool's output)
is built once per run in a temporary directory. Then, for each setting in
CRIT_SETTINGS (a mapped budget and a chunk size, with the default 4 MiB
dirty pool):

1. **The criterion:** reader, scanner and writer threads for
   CRIT_SECONDS, with no env_sweep call: the budget is kept by the end of
   every transaction and by inline eviction alone (D8, D9 as amended). A
   sampler thread reads the resident figure throughout, and asserts that it
   plus the dirty pool stays within 2 chunks of the total budget
   (mapped_budget + dirty_budget). **Linux:** env_resident_check (pagemap)
   plus Stats.dirty_committed. **macOS:** the process's file-backed
   resident size (task_info `external`) above a baseline taken right after
   env_open, plus Stats.dirty_committed. The process-wide resident_size
   the task first named is logged too, but not asserted: it also carries
   the test's own threads and the pages macOS malloc keeps resident after a
   free (up to about 8 MiB in this test, staying after env_close), which
   are the process's and not the store's. The pool's own release is exact
   (KV-T-0020). The drift between the estimate and the OS's figure is
   reported (Q4).
2. **Typical:** single requests, one at a time, reading or writing one
   message (the first deployment's load, without the pauses: the store has
   no time-driven behaviour, so only the sequence of requests matters),
   starting asleep; the figures once it has settled.
3. **The end-of-transaction check:** what txn_abort costs under the budget,
   and when it evicts.
4. **Sleep:** what env_sweep(env, 0) takes, and what the store still holds
   afterwards, against env_close.
A brief warm-up pass of the first setting runs before them, unreported, so
that the test process's one-time allocations precede every baseline. Then
**wake**: what env_open takes, with the free list as built (short) and
after deleting half the conversations while a reader was held (long).

Everything is reported in the log; only the criterion (and correctness) is
asserted. Resident sizes are process-wide, so run it alone, and with
-o:speed for the timings:

	odin test tests -o:speed -define:KV_CRITERION=true -define:ODIN_TEST_THREADS=1 \
		-define:ODIN_TEST_NAMES=kv_tests.test_memory_criterion
	scripts/test-linux.sh arm64 -define:KV_CRITERION=true -define:ODIN_TEST_THREADS=1 \
		-define:ODIN_TEST_NAMES=kv_tests.test_memory_criterion

Only the registration is guarded: the procedures are compiled and
type-checked by every run.
*/
when #config(KV_CRITERION, false) {
	@(test)
	test_memory_criterion :: proc(t: ^testing.T) {
		memory_criterion(t)
	}
}

// Seconds of mixed load per setting.
@(private = "file")
CRIT_SECONDS :: #config(KV_CRITERION_SECONDS, 10)

// Microseconds the reader and scanner threads pause between requests
// (the writer is paced by its synced commits). Without it they make some
// 35,000 requests a second each, and on Linux almost no pagemap walk runs
// without a chunk faulted in or evicted meanwhile, so almost no sample is
// consistent (see Crit_Sampler).
@(private = "file")
CRIT_PAUSE_US :: #config(KV_CRITERION_PAUSE_US, 200)

// The database is built until its tree reaches this size.
@(private = "file")
CRIT_DB_BYTES :: 100 << 20

@(private = "file")
CRIT_CONV_MSGS :: 40

@(private = "file")
Crit_Setting :: struct {
	chunk_size:    int,
	mapped_budget: int,
}

@(private = "file")
CRIT_SETTINGS :: [2]Crit_Setting{{256 << 10, 15 << 20}, {64 << 10, 8 << 20}}

// Largest message.
@(private = "file")
CRIT_MAX_VALUE :: 16 << 10

// The key of message `seq` of conversation `conv`, in `buf`.
@(private = "file")
crit_key :: proc(buf: []byte, conv, seq: int) -> []byte {
	return transmute([]byte)fmt.bprintf(buf, "c%05d/%05d", conv, seq)
}

@(private = "file")
crit_hash :: proc(key: []byte) -> u64 {
	h := u64(0xcbf2_9ce4_8422_2325)
	for b in key {
		h = (h ~ u64(b)) * 0x100_0000_01b3
	}
	h ~= h >> 29
	h *= 0x94D0_49BB_1331_11EB
	return h ~ h >> 32
}

// A message's size: nine in ten are 100–899 bytes, the rest 2–16 KiB.
@(private = "file")
crit_size :: proc(h: u64) -> int {
	if h % 10 == 0 {
		return 2_000 + int(h >> 8 % 14_000)
	}
	return 100 + int(h >> 8 % 800)
}

@(private = "file")
crit_byte :: #force_inline proc(h: u64, i: int) -> byte {
	return byte(h >> uint(i & 7 * 8)) ~ byte(i)
}

// The value of `key`, in `buf`: a function of the key alone, so that any
// thread can check any message it finds.
@(private = "file")
crit_value :: proc(buf: []byte, key: []byte) -> []byte {
	h := crit_hash(key)
	v := buf[:crit_size(h)]
	for &b, i in v {
		b = crit_byte(h, i)
	}
	return v
}

@(private = "file")
crit_value_ok :: proc(key, v: []byte) -> bool {
	h := crit_hash(key)
	if len(v) != crit_size(h) {
		return false
	}
	for b, i in v {
		if b != crit_byte(h, i) {
			return false
		}
	}
	return true
}

// Builds the database: conversations of CRIT_CONV_MSGS messages, 100 to a
// commit, until the tree reaches CRIT_DB_BYTES. Returns the number of
// conversations.
@(private = "file")
crit_build :: proc(t: ^testing.T, path: string) -> (convs: int, ok: bool) {
	env, err := kv.env_open(path)
	if !testing.expect_value(t, err, kv.Error.None) {
		return 0, false
	}
	defer kv.env_close(env)
	key_buf: [32]byte
	val_buf := make([]byte, CRIT_MAX_VALUE)
	defer delete(val_buf)
	start := time.tick_now()
	for int(kv.env_snapshot(env).last_pgno) * env.page_size < CRIT_DB_BYTES {
		txn, _ := kv.txn_begin(env, read_only = false)
		for _ in 0 ..< 100 {
			for seq in 0 ..< CRIT_CONV_MSGS {
				key := crit_key(key_buf[:], convs, seq)
				if !testing.expect_value(t, kv.put(&txn, key, crit_value(val_buf, key)), kv.Error.None) {
					kv.txn_abort(&txn)
					return 0, false
				}
			}
			convs += 1
		}
		if !testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None) {
			return 0, false
		}
	}
	s := kv.env_stats(env)
	log.infof("built %d conversations, %d messages, %.1f MB of tree (%d pages), file %.1f MB, in %v; free list %d records", convs, convs * CRIT_CONV_MSGS, mb(int(s.last_pgno) * env.page_size), s.last_pgno, mb(s.file_pages * env.page_size), time.tick_since(start), s.free_ready + s.free_pending)
	return convs, true
}

@(private = "file")
mb :: proc(bytes: int) -> f64 {
	return f64(bytes) / f64(1 << 20)
}

// The process's resident size: task_info resident_size on macOS,
// /proc/self/statm on Linux.
@(private = "file")
process_rss :: proc() -> int {
	return platform_residency(nil, 0).rss
}

@(private = "file")
Crit_Kind :: enum {
	Reader,
	Scanner,
	Writer,
}

@(private = "file")
Crit_Worker :: struct {
	env:      ^kv.Env,
	kind:     Crit_Kind,
	convs:    int,
	stop:     ^bool,
	// Results, read after the thread is joined.
	requests: int,
	entries:  int,
	problem:  string,
}

@(private = "file")
crit_worker_run :: proc(w: ^Crit_Worker) {
	key_buf: [32]byte
	val_buf := make([]byte, CRIT_MAX_VALUE)
	defer delete(val_buf)
	// The writer appends to conversations: the next message of each.
	next: []int
	if w.kind == .Writer {
		next = make([]int, w.convs)
		for &n in next {
			n = CRIT_CONV_MSGS
		}
	}
	defer delete(next)
	fail :: proc(w: ^Crit_Worker, txn: ^kv.Txn, what: string, key: []byte) {
		w.problem = fmt.aprintf("%v: %s %s", w.kind, what, string(key))
		kv.txn_abort(txn)
	}
	for ; !sync.atomic_load(w.stop); w.requests += 1 {
		txn, err := kv.txn_begin(w.env, read_only = w.kind != .Writer)
		if err != .None {
			w.problem = fmt.aprintf("%v: txn_begin %v", w.kind, err)
			return
		}
		switch w.kind {
		case .Reader:
			// Three messages of one conversation.
			conv := rand.int_max(w.convs)
			for _ in 0 ..< 3 {
				key := crit_key(key_buf[:], conv, rand.int_max(CRIT_CONV_MSGS))
				v, gerr := kv.get(&txn, key)
				if gerr != .None || !crit_value_ok(key, v) {
					fail(w, &txn, "wrong or missing", key)
					return
				}
				w.entries += 1
			}
		case .Scanner:
			// A whole conversation; one request in 50 reads 4,000
			// messages in a row, far past any budget here.
			long := w.requests % 50 == 49
			n := 4_000
			prefix := string(crit_key(key_buf[:], rand.int_max(w.convs), 0)[:7])
			c := kv.cursor_open(&txn)
			for k, v, cerr := kv.cursor_seek(&c, transmute([]byte)prefix); cerr == .None && n > 0; k, v, cerr = kv.cursor_next(&c) {
				if !long && !strings.has_prefix(string(k), prefix) {
					break
				}
				if !crit_value_ok(k, v) {
					fail(w, &txn, "wrong value", k)
					return
				}
				w.entries += 1
				n -= 1
			}
		case .Writer:
			// One to three messages appended to one conversation; one
			// request in 100 appends 1,500 to random conversations, more
			// than the dirty pool holds.
			n := 1_500 if w.requests % 100 == 99 else 1 + rand.int_max(3)
			conv := rand.int_max(w.convs)
			for _ in 0 ..< n {
				if n > 3 {
					conv = rand.int_max(w.convs)
				}
				key := crit_key(key_buf[:], conv, next[conv])
				if perr := kv.put(&txn, key, crit_value(val_buf, key)); perr != .None {
					fail(w, &txn, fmt.tprintf("put %v", perr), key)
					return
				}
				next[conv] += 1
				w.entries += 1
			}
			if cerr := kv.txn_commit(&txn); cerr != .None {
				w.problem = fmt.aprintf("writer: commit %v", cerr)
				return
			}
		}
		kv.txn_abort(&txn)
		if w.kind != .Writer {
			time.sleep(CRIT_PAUSE_US * time.Microsecond)
		}
	}
}

/*
Samples the resident figure (see the file comment) until told to stop.

On Linux a sample is a pagemap walk over the file (about 0.2 ms at 100 MB)
and is not atomic: chunks faulted in and evicted while it runs can all be
counted, though they were never resident at the same time (up to about
3,000 chunks faulted in during one walk were seen at full speed, the
sampler being descheduled). So a sample counts only if no chunk was
faulted in or evicted during its walk (chunk_faults and evictions
unchanged): then the map's residency didn't change while it ran, and the
walk read one instant. The others are counted as inconsistent and dropped.
On macOS task_info is one call, and every sample counts.
*/
@(private = "file")
Crit_Sampler :: struct {
	env:          ^kv.Env,
	// macOS: the process's file-backed and whole resident sizes right after
	// env_open.
	baseline:     int,
	baseline_rss: int,
	stop:         ^bool,
	// Results, read after the thread is joined. Bytes, except the chunks.
	samples:      int,
	// macOS: the highest process-wide resident size above its baseline,
	// the pool and malloc's retained pages included; logged, not asserted.
	peak_rss:     int,
	// The highest figure (resident + dirty), and its parts' highest.
	peak:         int,
	peak_mapped:  int,
	peak_dirty:   int,
	peak_chunks:  int,
	// Samples whose figure was above `limit`.
	limit:        int,
	over:         int,
	// The OS's mapped figure against the estimate (chunks × chunk size):
	// sums for the mean, and the most the OS was above it.
	sum_mapped:   f64,
	sum_estimate: f64,
	max_excess:   int,
	// Linux: how long a pagemap walk took; the samples dropped because a
	// chunk was faulted in or evicted while their walk ran, and the most
	// chunks faulted in during one.
	walk_time:    time.Duration,
	inconsistent: int,
	walk_faults:  int,
	err:          kv.Error,
}

@(private = "file")
crit_sampler_run :: proc(s: ^Crit_Sampler) {
	for !sync.atomic_load(s.stop) {
		st := kv.env_stats(s.env)
		mapped, total: int
		when ODIN_OS == .Linux {
			err: kv.Error
			start := time.tick_now()
			mapped, err = kv.env_resident_check(s.env)
			s.walk_time += time.tick_since(start)
			after := kv.env_stats(s.env)
			if err != .None {
				s.err = err
				return
			}
			total = mapped + st.dirty_committed
			if after.chunk_faults != st.chunk_faults || after.evictions != st.evictions {
				// Not a consistent reading: the walk may have counted
				// chunks that were never resident at the same time.
				s.inconsistent += 1
				s.walk_faults = max(s.walk_faults, after.chunk_faults - st.chunk_faults)
				time.sleep(100 * time.Microsecond)
				continue
			}
		} else {
			mapped = process_file_resident() - s.baseline
			total = mapped + st.dirty_committed
			s.peak_rss = max(s.peak_rss, process_rss() - s.baseline_rss)
		}
		estimate := st.resident_chunks * st.chunk_size
		s.samples += 1
		s.peak = max(s.peak, total)
		s.peak_mapped = max(s.peak_mapped, mapped)
		s.peak_dirty = max(s.peak_dirty, st.dirty_committed)
		s.peak_chunks = max(s.peak_chunks, st.resident_chunks)
		if total > s.limit {
			s.over += 1
		}
		s.sum_mapped += f64(mapped)
		s.sum_estimate += f64(estimate)
		s.max_excess = max(s.max_excess, mapped - estimate)
		time.sleep(100 * time.Microsecond)
	}
}

/*
Makes the temporary allocator's first block resident and empties it. The
block (4 MiB, from calloc) becomes resident a page at a time as the
allocator's bump pointer first walks through it, which would count against
the store in the process-wide figures on macOS. Called before a baseline is
taken, and after expect_latest_ok's checks, so that this test's own
temporary allocations reuse pages already counted in the baseline.
*/
@(private = "file")
temp_warm :: proc() {
	free_all(context.temp_allocator)
	_ = make([]byte, 3 << 20, context.temp_allocator)
	free_all(context.temp_allocator)
}

// The store's fixed structures, from its own sizes (bytes).
@(private = "file")
Crit_Fixed :: struct {
	env, chunk_table, reader_table, free_list, pool_bookkeeping: int,
}

@(private = "file")
crit_fixed :: proc(env: ^kv.Env) -> Crit_Fixed {
	p := &env.pool
	return Crit_Fixed {
		env              = size_of(kv.Env),
		chunk_table      = env.chunks.count,
		reader_table     = cap(env.readers) * size_of(kv.Reader_Slot),
		free_list        = kv.env_stats(env).free_list_bytes,
		pool_bookkeeping = len(p.used) * 8 + len(p.committed) * 8 + len(p.touched) * 4 + len(p.spill_list) * size_of(p.spill_list[0]),
	}
}

@(private = "file")
fixed_total :: proc(f: Crit_Fixed) -> int {
	return f.env + f.chunk_table + f.reader_table + f.free_list + f.pool_bookkeeping
}

// The resident figure of the map alone: env_resident_check on Linux, the
// process's file-backed resident size above `baseline` on macOS.
@(private = "file")
mapped_figure :: proc(env: ^kv.Env, baseline: int) -> int {
	when ODIN_OS == .Linux {
		r, _ := kv.env_resident_check(env)
		return r
	} else {
		return process_file_resident() - baseline
	}
}

// macOS: the baseline mapped_figure takes. Linux: unused.
@(private = "file")
mapped_baseline :: proc() -> int {
	when ODIN_OS == .Linux {
		return 0
	} else {
		return process_file_resident()
	}
}

@(private = "file")
memory_criterion :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	// Not in the temporary allocator, which the phases below free.
	path := strings.clone(temp_dir_file(dir, DB))
	defer delete(path)

	convs, ok := crit_build(t, path)
	if !ok {
		return
	}

	// Wake with the free list as built.
	short_open, short_records := crit_open_time(t, path)
	log.infof("wake (env_open), free list as built (%d records): %v median of 5", short_records, short_open)

	// A warm-up pass of the first setting, briefly and not reported: the
	// test process's own one-time allocations (malloc's regions for the
	// threads, measured at about 8 MiB on macOS, which stay after
	// env_close) then happen before any baseline is taken.
	if !crit_setting(t, path, convs, CRIT_SETTINGS[0], 1, warm_up = true) {
		return
	}
	for setting in CRIT_SETTINGS {
		if !crit_setting(t, path, convs, setting, CRIT_SECONDS) {
			return
		}
	}

	// Wake with a long free list: half the conversations deleted while a
	// reader was held, so every page they used is on the list.
	{
		env, err := kv.env_open(path)
		if !testing.expect_value(t, err, kv.Error.None) {
			return
		}
		reader, _ := kv.txn_begin(env)
		key_buf: [32]byte
		for first := 0; first < convs; first += 200 {
			txn, _ := kv.txn_begin(env, read_only = false)
			for conv in first ..< min(first + 200, convs) {
				if conv % 2 != 0 {
					continue
				}
				prefix := crit_key(key_buf[:], conv, 0)[:7]
				c := kv.cursor_open(&txn)
				keys := make([dynamic]string, context.temp_allocator)
				for k, _, cerr := kv.cursor_seek(&c, prefix); cerr == .None && strings.has_prefix(string(k), string(prefix)); k, _, cerr = kv.cursor_next(&c) {
					append(&keys, strings.clone(string(k), context.temp_allocator))
				}
				for k in keys {
					kv.del(&txn, transmute([]byte)k)
				}
			}
			testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
			free_all(context.temp_allocator)
		}
		kv.txn_abort(&reader)
		kv.env_close(env)
	}
	long_open, long_records := crit_open_time(t, path)
	log.infof("wake (env_open), long free list (%d records, %d bytes in RAM): %v median of 5", long_records, long_records * 16, long_open)
}

// The median time of five env_open calls, each followed by env_close, and
// the free list's length.
@(private = "file")
crit_open_time :: proc(t: ^testing.T, path: string) -> (median: time.Duration, records: int) {
	times: [5]time.Duration
	for &d in times {
		start := time.tick_now()
		env, err := kv.env_open(path)
		d = time.tick_since(start)
		if !testing.expect_value(t, err, kv.Error.None) {
			return 0, -1
		}
		s := kv.env_stats(env)
		records = s.free_ready + s.free_pending
		kv.env_close(env)
	}
	slice.sort(times[:])
	return times[2], records
}

@(private = "file")
crit_setting :: proc(t: ^testing.T, path: string, convs: int, setting: Crit_Setting, seconds: int, warm_up := false) -> bool {
	log.infof("==== %schunk size %d KiB, mapped budget %.0f MiB, dirty budget %.0f MiB ====", "WARM-UP, not measured: " if warm_up else "", setting.chunk_size >> 10, mb(setting.mapped_budget), mb(kv.DEFAULT_DIRTY_BUDGET))
	temp_warm()
	rss_closed := process_rss()
	env, err := kv.env_open(path, kv.Options{chunk_size = setting.chunk_size, mapped_budget = setting.mapped_budget})
	if !testing.expect_value(t, err, kv.Error.None) {
		return false
	}
	baseline, baseline_rss := mapped_baseline(), process_rss()
	st := kv.env_stats(env)
	budget := setting.mapped_budget + st.dirty_budget
	limit := budget + 2 * setting.chunk_size

	// 1. The criterion.
	stop := false
	sampler := Crit_Sampler{env = env, baseline = baseline, baseline_rss = baseline_rss, stop = &stop, limit = limit}
	sampler_thread := thread.create_and_start_with_poly_data(&sampler, crit_sampler_run)
	kinds := [?]Crit_Kind{.Reader, .Reader, .Scanner, .Writer}
	workers: [len(kinds)]Crit_Worker
	threads: [len(kinds)]^thread.Thread
	for kind, i in kinds {
		workers[i] = {env = env, kind = kind, convs = convs, stop = &stop}
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], crit_worker_run)
	}
	time.sleep(time.Duration(seconds) * time.Second)
	sync.atomic_store(&stop, true)
	thread.join_multiple(..threads[:])
	thread.join(sampler_thread)
	thread.destroy(sampler_thread)
	good := true
	for &w, i in workers {
		thread.destroy(threads[i])
		if w.problem != "" {
			good = testing.expectf(t, false, "%s", w.problem)
			delete(w.problem)
		}
	}
	st = kv.env_stats(env)
	log.infof("mixed load, %d s: requests %d/%d readers, %d scanner, %d writer (%d entries read or written); %d chunk faults, %d chunks evicted by %d transaction ends and %d inline evictions, %d sweeps; %d pages spilled", seconds, workers[0].requests, workers[1].requests, workers[2].requests, workers[3].requests, workers[0].entries + workers[1].entries + workers[2].entries + workers[3].entries, st.chunk_faults, st.evictions, st.txn_end_evictions, st.inline_evictions, st.sweeps, st.spills)
	log.infof("criterion: %d samples; peak %.2f MiB (mapped %.2f, dirty %.2f), limit %.2f MiB (budget %.2f + 2 chunks); %d samples over; estimate peak %d chunks (budget %d)", sampler.samples, mb(sampler.peak), mb(sampler.peak_mapped), mb(sampler.peak_dirty), mb(limit), mb(budget), sampler.over, sampler.peak_chunks, setting.mapped_budget / setting.chunk_size)
	when ODIN_OS != .Linux {
		log.infof("macOS, process-wide: resident_size peaked %.2f MiB above its baseline (the store, the test's threads and malloc's retained pages)", mb(sampler.peak_rss))
	}
	log.infof("drift: the OS's mapped figure averaged %.2f MiB against an estimate of %.2f MiB (%.0f%%); at most %.2f MiB above the estimate", mb(int(sampler.sum_mapped / f64(sampler.samples))), mb(int(sampler.sum_estimate / f64(sampler.samples))), 100 * sampler.sum_mapped / sampler.sum_estimate, mb(sampler.max_excess))
	when ODIN_OS == .Linux {
		log.infof("pagemap walks: %v each on average; %d inconsistent samples dropped (at most %d chunks faulted in during one walk), %d consistent", sampler.walk_time / time.Duration(max(1, sampler.samples + sampler.inconsistent)), sampler.inconsistent, sampler.walk_faults, sampler.samples)
	}
	if present, present_ok := chunks_present(env.map_base, (int(env.file_size) + env.chunks.size - 1) / env.chunks.size * env.chunks.size, env.chunks.size); present_ok {
		uncounted, counted_absent := 0, 0
		for p, i in present {
			counted := sync.atomic_load(&env.chunks.bits[i]) & kv.CHUNK_RESIDENT != 0
			if p && !counted {
				uncounted += 1
			} else if counted && !p {
				counted_absent += 1
			}
		}
		log.infof("drift at the end: %d chunks present and not counted (Q4), %d counted and not present, %d counted", uncounted, counted_absent, st.resident_chunks)
	}
	good &= testing.expect_value(t, sampler.err, kv.Error.None)
	good &= testing.expect(t, sampler.samples > 100, "too few samples")
	good &= testing.expectf(t, sampler.peak <= limit, "resident figure plus dirty pool reached %.2f MiB, limit %.2f MiB (%d of %d samples over)", mb(sampler.peak), mb(limit), sampler.over, sampler.samples)
	good &= testing.expect_value(t, st.sweeps, 0)
	good &= testing.expect(t, st.txn_end_evictions > 0 && st.inline_evictions > 0, "an eviction path unused")
	good &= testing.expect(t, st.spills > 0, "the writer never filled the pool")
	expect_latest_ok(t, env)
	free_all(context.temp_allocator)
	worst_mapped, worst_dirty, worst := sampler.peak_mapped, sampler.peak_dirty, sampler.peak

	// Test overhead on macOS: what is left above the baseline once the
	// store holds nothing.
	kv.env_sweep(env, 0)
	overhead := process_rss() - baseline_rss

	// 2. Typical: single requests from sleep, four reads to one write.
	key_buf: [32]byte
	val_buf := make([]byte, CRIT_MAX_VALUE)
	defer delete(val_buf)
	REQUESTS :: 2_000
	settled_mapped := make([]int, REQUESTS / 2, context.temp_allocator)
	settled_chunks := make([]int, REQUESTS / 2, context.temp_allocator)
	typical_dirty := 0
	for n in 0 ..< REQUESTS {
		conv := rand.int_max(convs)
		if n % 5 != 4 {
			txn, _ := kv.txn_begin(env)
			key := crit_key(key_buf[:], conv, rand.int_max(CRIT_CONV_MSGS))
			v, gerr := kv.get(&txn, key)
			if gerr != .None || !crit_value_ok(key, v) {
				good = testing.expectf(t, false, "typical: wrong or missing %s", string(key))
			}
			kv.txn_abort(&txn)
		} else {
			txn, _ := kv.txn_begin(env, read_only = false)
			key := crit_key(key_buf[:], conv, 100_000 + n)
			kv.put(&txn, key, crit_value(val_buf, key))
			typical_dirty = max(typical_dirty, kv.env_stats(env).dirty_committed)
			good &= testing.expect_value(t, kv.txn_commit(&txn), kv.Error.None)
		}
		if n >= REQUESTS / 2 {
			settled_mapped[n - REQUESTS / 2] = mapped_figure(env, baseline)
			settled_chunks[n - REQUESTS / 2] = kv.env_stats(env).resident_chunks
		}
	}
	slice.sort(settled_mapped)
	slice.sort(settled_chunks)
	typical_median, typical_max := settled_mapped[len(settled_mapped) / 2], settled_mapped[len(settled_mapped) - 1]
	log.infof("typical (%d single-entry requests from sleep, the last %d sampled): mapped %.2f MiB median, %.2f MiB max; estimate %d chunks median, %d max; dirty %.0f KiB committed at most during a write, 0 between requests", REQUESTS, REQUESTS / 2, mb(typical_median), mb(typical_max), settled_chunks[len(settled_chunks) / 2], settled_chunks[len(settled_chunks) - 1], f64(typical_dirty) / 1024)

	// 3. The end-of-transaction check: a request reading one message, the
	// estimate climbing by a chunk or two each time until the end of a
	// transaction finds it above the budget and evicts to 7/8 of it.
	{
		N :: 1_000_000
		start := time.tick_now()
		for _ in 0 ..< N {
			kv.env_sweep(env)
		}
		noop := f64(time.duration_nanoseconds(time.tick_since(start))) / N
		kv.env_sweep(env, 0)
		under, evicting: [dynamic]time.Duration
		under.allocator = context.temp_allocator
		evicting.allocator = context.temp_allocator
		before := kv.env_stats(env)
		for _ in 0 ..< 3_000 {
			txn, _ := kv.txn_begin(env)
			kv.get(&txn, crit_key(key_buf[:], rand.int_max(convs), rand.int_max(CRIT_CONV_MSGS)))
			ends := kv.env_stats(env).txn_end_evictions
			start = time.tick_now()
			kv.txn_abort(&txn)
			d := time.tick_since(start)
			append(&evicting if kv.env_stats(env).txn_end_evictions > ends else &under, d)
		}
		after := kv.env_stats(env)
		slice.sort(under[:])
		slice.sort(evicting[:])
		evicted := after.evictions - before.evictions
		log.infof("end of a transaction: the check alone %.2f ns (env_sweep's default target, the same load and compare); txn_abort of a read-only transaction %v median under the budget (%d), %v median when it evicts (%d, %.1f chunks each, %d inline evictions meanwhile)", noop, under[len(under) / 2] if len(under) > 0 else 0, len(under), evicting[len(evicting) / 2] if len(evicting) > 0 else 0, len(evicting), f64(evicted) / f64(max(1, after.txn_end_evictions - before.txn_end_evictions + after.inline_evictions - before.inline_evictions)), after.inline_evictions - before.inline_evictions)
	}

	// 4. Sleep: the time to put a store at its budget to sleep, and what
	// it holds afterwards, against env_close.
	sleep_times: [5]time.Duration
	sleep_chunks := 0
	for &d in sleep_times {
		for kv.env_stats(env).resident_chunks < setting.mapped_budget / setting.chunk_size {
			txn, _ := kv.txn_begin(env)
			kv.get(&txn, crit_key(key_buf[:], rand.int_max(convs), rand.int_max(CRIT_CONV_MSGS)))
			kv.txn_abort(&txn)
		}
		start := time.tick_now()
		sleep_chunks = kv.env_sweep(env, 0)
		d = time.tick_since(start)
	}
	slice.sort(sleep_times[:])
	asleep_mapped := mapped_figure(env, baseline)
	asleep_rss := process_rss() - rss_closed
	fixed := crit_fixed(env)
	st = kv.env_stats(env)
	log.infof("sleep: env_sweep(env, 0) of %d chunks at the budget %v median of 5; asleep: mapped %d bytes, dirty %d, process +%.2f MiB above before env_open", sleep_chunks, sleep_times[2], asleep_mapped, st.dirty_committed, mb(asleep_rss))
	log.infof("fixed structures: Env %d, chunk table %d, reader table %d, free list %d (%d records), pool bookkeeping %d: %d bytes", fixed.env, fixed.chunk_table, fixed.reader_table, fixed.free_list, st.free_ready + st.free_pending, fixed.pool_bookkeeping, fixed_total(fixed))
	log.infof("reserved address space (virtual, not RAM): map %.0f MiB + pool %.0f MiB", mb(env.map_size), mb(env.pool.reserved))
	kv.env_close(env)
	closed_rss := process_rss() - rss_closed
	log.infof("closed: the store holds nothing; process %+.2f MiB against before env_open", mb(closed_rss))

	bound := setting.mapped_budget + 2 * setting.chunk_size + st.dirty_budget + fixed_total(fixed)
	log.infof("CAPACITY | %s | %d KiB | %.0f MiB | worst %.2f MiB (mapped %.2f + dirty %.2f) vs bound %.2f MiB | typical mapped %.2f median %.2f max, dirty 0 idle / %.0f KiB in a write | asleep mapped %d, fixed %d bytes | closed 0 | test overhead %.2f MiB",
		ODIN_OS, setting.chunk_size >> 10, mb(setting.mapped_budget), mb(worst), mb(worst_mapped), mb(worst_dirty), mb(bound), mb(typical_median), mb(typical_max), f64(typical_dirty) / 1024, asleep_mapped, fixed_total(fixed), mb(overhead))
	return good
}
