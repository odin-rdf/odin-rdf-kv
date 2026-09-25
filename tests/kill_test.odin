package kv_tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import kv "../kv"
import "killer/workload"

// Kills per run, all on the same file.
KILL_REPEATS :: #config(KV_KILL_REPEATS, 20)

// The longest a helper runs before it is killed, in milliseconds; each run
// draws its delay uniformly from 0 to this.
KILL_MAX_DELAY_MS :: #config(KV_KILL_MAX_DELAY_MS, 250)

#assert(KILL_REPEATS >= 1 && KILL_MAX_DELAY_MS >= 0)

/*
The real-kill test (KV-I-0005 D1, KV-T-0032): the vision's own words, a
process killed during commit, with real syncs. Not part of the ordinary
suite or CI; run it with -define:KV_KILL=true, and never with KV_NO_SYNC
(it refuses):

	odin test tests -define:KV_KILL=true -define:ODIN_TEST_NAMES=kv_tests.test_kill_real

The test builds the helper in tests/killer (`odin build`, so `odin` must be
on PATH) into a temporary directory, then KILL_REPEATS times on one
database file: starts it with core:os's process API (not fork(): the test
runner is multithreaded), reads the commit numbers it prints after each
txn_commit returns, sends SIGKILL after a delay drawn from the test's seed,
waits for it and reads what it printed before dying. Then it opens the file
and checks that the committed number is the last one printed or the one
after (a kill after the meta-page write, before the number was printed),
that every slot holds exactly what the workload's replay to that number
says, and tree_check and space_check. The next helper resumes from that
number. Odd runs use the smallest dirty-page pool, so the workload's large
commits spill.

The sweep (crash_sweep_test.odin) is the stronger test: it cuts at every
operation, and simulates power loss. This one keeps what a simulation
can't: the real mmap, page cache, flock and process death.
*/
when #config(KV_KILL, false) {
	@(test)
	test_kill_real :: proc(t: ^testing.T) {
		kill_real(t)
	}
}

@(private = "file")
kill_real :: proc(t: ^testing.T) {
	if kv.NO_SYNC {
		testing.fail_now(t, "KV_NO_SYNC is set: the real-kill test needs real syncs, build it without -define:KV_NO_SYNC=true")
	}
	dir := temp_dir_create(t)
	defer {
		os.remove_all(dir.path)
		delete(dir.path)
	}
	bin := temp_dir_file(dir, "killer")
	path := temp_dir_file(dir, DB)

	start := time.tick_now()
	if !kill_build_helper(t, bin) {
		return
	}
	log.infof("helper built in %v", time.tick_since(start))

	state := make([]workload.Slot_State, workload.SLOTS)
	defer delete(state)
	committed: u64 // the committed number the last check found
	after_meta := 0 // kills after the meta-page write, before the print
	silent := 0 // kills before the run printed anything
	start = time.tick_now()
	for run in 0 ..< KILL_REPEATS {
		budget := MIN_DIRTY_BUDGET if run % 2 == 1 else 0
		delay := time.Duration(rand.int_max(KILL_MAX_DELAY_MS + 1)) * time.Millisecond
		printed, ok := kill_run(t, bin, path, budget, delay, run, committed)
		if !ok {
			return
		}
		last := printed[len(printed) - 1] if len(printed) > 0 else committed

		n, diff := kill_check(path, state)
		if !testing.expectf(t, diff == "", "run %d (killed after %v): %s", run, delay, diff) {
			return
		}
		if !testing.expectf(t, n == last || n == last + 1, "run %d (killed after %v): committed %d, last printed %d", run, delay, n, last) {
			return
		}
		if n == last + 1 {
			after_meta += 1
		}
		if len(printed) == 0 {
			silent += 1
		}
		log.debugf("run %d: killed after %v, %d commits printed, committed %d", run, delay, len(printed), n)
		committed = n
	}
	log.infof("%d kills in %v: %d commits, %d kills after the meta-page write and before the print, %d before anything was printed",
		KILL_REPEATS, time.tick_since(start), committed, after_meta, silent)
}

// Builds tests/killer into `bin`, with real syncs and the suite's checks.
@(private = "file")
kill_build_helper :: proc(t: ^testing.T, bin: string) -> bool {
	src := #directory + "/killer"
	desc := os.Process_Desc {
		command = {"odin", "build", src, fmt.tprintf("-out:%s", bin), "-o:speed", "-vet", "-strict-style"},
	}
	state, stdout, stderr, err := os.process_exec(desc, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	return testing.expectf(t, err == nil && state.success, "odin build %s: %v, exit %d:\n%s%s", src, err, state.exit_code, stdout, stderr)
}

/*
Runs the helper on `path` for `delay`, kills it and waits for it. Returns the
commit numbers it printed, in order (temp allocator), after checking that
they count up from `committed` + 1 and that the helper died of SIGKILL and
not of an error of its own.
*/
@(private = "file")
kill_run :: proc(t: ^testing.T, bin, path: string, budget: int, delay: time.Duration, run: int, committed: u64) -> (printed: []u64, ok: bool) {
	r, w, perr := os.pipe()
	if !testing.expectf(t, perr == nil, "run %d: pipe: %v", run, perr) {
		return nil, false
	}
	defer os.close(r)
	process, serr := os.process_start({command = {bin, path, fmt.tprintf("%d", budget)}, stdout = w, stderr = os.stderr})
	os.close(w)
	if !testing.expectf(t, serr == nil, "run %d: process_start: %v", run, serr) {
		return nil, false
	}

	out: [dynamic]byte
	out.allocator = context.temp_allocator
	buf: [4096]byte
	deadline := time.tick_now()
	for time.tick_since(deadline) < delay {
		has, _ := os.pipe_has_data(r)
		if !has {
			time.sleep(time.Millisecond)
			continue
		}
		n, _ := os.read(r, buf[:])
		append(&out, ..buf[:n])
	}
	kerr := os.process_kill(process)
	state, werr := os.process_wait(process)
	// Everything the helper wrote before it died, up to EOF.
	for {
		n, rerr := os.read(r, buf[:])
		if n > 0 {
			append(&out, ..buf[:n])
		}
		if rerr != nil || n == 0 {
			break
		}
	}
	if !testing.expectf(t, kerr == nil && werr == nil, "run %d: kill: %v, wait: %v", run, kerr, werr) {
		return nil, false
	}
	// The helper runs until it is killed: an exit of its own is a failure,
	// reported on stderr.
	if !testing.expectf(t, !state.success && state.exit_code == 9, "run %d: the helper exited with status %d before the kill (see its stderr)", run, state.exit_code) {
		return nil, false
	}

	numbers := make([dynamic]u64, context.temp_allocator)
	text := string(out[:])
	for line in strings.split_lines_iterator(&text) {
		c, cok := strconv.parse_u64(line)
		if !testing.expectf(t, cok && c == committed + u64(len(numbers)) + 1, "run %d: printed %q, want %d", run, line, committed + u64(len(numbers)) + 1) {
			return nil, false
		}
		append(&numbers, c)
	}
	return numbers[:], true
}

/*
Opens the database at `path` and checks it against the workload: the
counter's number N, then every key in order, each slot's value exactly what
the replay to N says it is, and no other key; then tree_check and
space_check. Returns N, and a description of the first difference or "".
*/
@(private = "file")
kill_check :: proc(path: string, state: []workload.Slot_State) -> (n: u64, diff: string) {
	env, err := kv.env_open(path)
	if err != .None {
		return 0, fmt.tprintf("env_open: %v", err)
	}
	defer kv.env_close(env)
	txn, berr := kv.txn_begin(env)
	if berr != .None {
		return 0, fmt.tprintf("txn_begin: %v", berr)
	}
	defer kv.txn_abort(&txn)

	v, gerr := kv.get(&txn, transmute([]byte)string(workload.COUNTER_KEY))
	switch {
	case gerr == .Not_Found:
		n = 0
	case gerr != .None:
		return 0, fmt.tprintf("get counter: %v", gerr)
	case len(v) != 8:
		return 0, fmt.tprintf("the counter is %d bytes", len(v))
	case:
		n = endian.unchecked_get_u64be(v)
	}

	workload.replay(n, state)
	want := make([]byte, 30_000, context.temp_allocator)
	key_buf: [8]byte
	cursor := kv.cursor_open(&txn)
	key, value, cerr := kv.cursor_first(&cursor)
	if n > 0 {
		// The counter sorts first.
		if cerr != .None || string(key) != workload.COUNTER_KEY {
			return n, fmt.tprintf("commit %d: first key %q, %v", n, key, cerr)
		}
		key, value, cerr = kv.cursor_next(&cursor)
	}
	for s, slot in state {
		if s.len < 0 {
			continue
		}
		want_key := workload.slot_key(key_buf[:], slot)
		if cerr != .None || !bytes.equal(key, want_key) {
			return n, fmt.tprintf("commit %d: key %q (%v) where %q was expected", n, key, cerr, want_key)
		}
		workload.value_fill(want[:s.len], s.commit, slot)
		if !bytes.equal(value, want[:s.len]) {
			return n, fmt.tprintf("commit %d: %s holds %d bytes, want the %d of commit %d", n, want_key, len(value), s.len, s.commit)
		}
		key, value, cerr = kv.cursor_next(&cursor)
	}
	if cerr != .Not_Found {
		return n, fmt.tprintf("commit %d: key %q after the last expected one (%v)", n, key, cerr)
	}

	if ok, reason := kv.tree_check(&txn); !ok {
		return n, fmt.tprintf("commit %d: tree_check: %s", n, reason)
	}
	if ok, reason := kv.space_check(&txn); !ok {
		return n, fmt.tprintf("commit %d: space_check: %s", n, reason)
	}
	return n, ""
}
