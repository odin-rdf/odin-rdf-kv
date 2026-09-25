package kv_tests

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import kv "../kv"

/*
The I/O journal and crash images (KV-I-0005 D1, D2, KV-T-0026).

With `-define:KV_IO_HOOK=true`, journal_start installs a hook (kv.io_hook)
on the calling thread that records every write, sync and truncate the store
makes on that thread, in order, copying each write's bytes, and still lets
the operation happen: spilled pages are read back through the map within
the transaction, so the writes must be real. A crash image is then built
after the fact from a baseline (the database file as it was when the
journal started, fully synced) and a selection of the journal's operations,
and opened with the real env_open.

The hook is thread-local, so a journal sees only the operations of the
thread that started it: the writer's, and env_open's when the env is opened
on that thread. A journal is meant for one database file; nothing here
tells two files apart, except each record's `fd`.

The journal can also fail an operation instead of recording it (fail_at),
which is how a failing write or sync is injected (KV-I-0005 D7). A failure
is not a crash: the process carries on.

Building blocks for the crash sweeps: image_init starts an image from a
baseline, image_apply applies one record to it (a power-loss image applies a
subset, or part of a write), image_write writes it to a file.
journal_image_kill composes them for a process kill.
*/

// One operation the store performed, as the journal recorded it. `bytes`
// is the journal's own copy.
Io_Record :: struct {
	kind:   kv.Io_Kind,
	fd:     posix.FD,
	offset: i64,
	bytes:  []byte,
	size:   i64,
}

Journal :: struct {
	// The operations performed, in order.
	ops:       [dynamic]Io_Record,
	// Calls of the hook so far, failed ones included: the index the next
	// call gets, which is what fail_at counts in.
	calls:     int,
	// The index of the hook call to fail with `fail_with` instead of
	// performing it, or -1. A failed call isn't recorded in `ops`.
	fail_at:   int,
	fail_with: kv.Error,
	allocator: mem.Allocator,
}

@(private = "file", thread_local)
journal_current: ^Journal

// Starts recording this thread's I/O into `j`, which must stay put until
// journal_stop. Only one journal per thread at a time.
journal_start :: proc(j: ^Journal, allocator := context.allocator) {
	assert(kv.IO_HOOK, "the journal needs -define:KV_IO_HOOK=true")
	assert(journal_current == nil, "a journal is already recording on this thread")
	j^ = Journal {
		ops       = make([dynamic]Io_Record, allocator),
		fail_at   = -1,
		allocator = allocator,
	}
	journal_current = j
	kv.io_hook = journal_hook
}

// Stops recording on this thread. The journal keeps what it recorded.
journal_stop :: proc() {
	journal_current = nil
	kv.io_hook = nil
}

// Frees what the journal recorded. Stop it first.
journal_destroy :: proc(j: ^Journal) {
	assert(journal_current != j, "journal_destroy of a journal still recording")
	for r in j.ops {
		delete(r.bytes, j.allocator)
	}
	delete(j.ops)
	j^ = {}
}

@(private = "file")
journal_hook :: proc(op: kv.Io_Op) -> kv.Error {
	j := journal_current
	call := j.calls
	j.calls += 1
	if call == j.fail_at {
		return j.fail_with
	}
	r := Io_Record {
		kind   = op.kind,
		fd     = op.fd,
		offset = op.offset,
		size   = op.size,
	}
	if op.kind == .Write {
		// The store reuses the buffer (a pool slot) once the write returns.
		r.bytes = slice.clone(op.bytes, j.allocator)
	}
	append(&j.ops, r)
	return .None
}

// The database file at the start of a journal: its bytes, or no file.
Baseline :: struct {
	bytes:  []byte,
	exists: bool,
}

// Reads the file at `path` as a baseline. A file that doesn't exist is a
// baseline of no file. Take it while the file is fully synced: after a
// commit returned, or after env_close. Returns false if the file exists
// but can't be read.
baseline_take :: proc(path: string, allocator := context.allocator) -> (b: Baseline, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {.CLOEXEC})
	if fd == -1 {
		return {}, posix.errno() == .ENOENT
	}
	defer posix.close(fd)
	size, err := kv.os_file_size(fd)
	if err != .None {
		return {}, false
	}
	b = {make([]byte, size, allocator), true}
	if size > 0 && kv.os_pread(fd, b.bytes, 0) != .None {
		delete(b.bytes, allocator)
		return {}, false
	}
	return b, true
}

baseline_destroy :: proc(b: ^Baseline, allocator := context.allocator) {
	delete(b.bytes, allocator)
	b^ = {}
}

// Starts an image of the file from `b`. No file is an empty image, which
// env_open treats the same (it creates the file if it is missing).
image_init :: proc(b: Baseline, allocator := context.allocator) -> [dynamic]byte {
	img := make([dynamic]byte, len(b.bytes), allocator)
	copy(img[:], b.bytes)
	return img
}

// Applies one recorded operation to an image as the OS would: a write
// past the end extends the file with zeros up to it, a truncate grows the
// file with zeros or shrinks it, and a sync changes nothing.
image_apply :: proc(img: ^[dynamic]byte, r: Io_Record) {
	switch r.kind {
	case .Write:
		image_resize(img, max(len(img), int(r.offset) + len(r.bytes)))
		copy(img[r.offset:], r.bytes)
	case .Truncate:
		image_resize(img, int(r.size))
	case .Sync:
	}
}

// Resizes an image, zeroing whatever it gains.
@(private = "file")
image_resize :: proc(img: ^[dynamic]byte, n: int) {
	old := len(img)
	resize(img, n)
	if n > old {
		mem.zero_slice(img[old:])
	}
}

// Writes an image to `path`, replacing the file. Returns false on an I/O
// error.
image_write :: proc(path: string, img: []byte) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd == -1 {
		return false
	}
	defer posix.close(fd)
	buf := img
	for len(buf) > 0 {
		n := posix.write(fd, raw_data(buf), c.size_t(len(buf)))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return false
		}
		buf = buf[n:]
	}
	return true
}

// Removes the file at `path`, if there is one.
file_remove :: proc(path: string) {
	posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
}

/*
Writes to `path` the file a process kill after the first `n` operations of
`j` leaves (0 ≤ n ≤ len(j.ops)): the baseline with those operations applied
in order. Everything a write handed to the OS survives a kill, synced or
not; nothing after it exists. n = 0 is the baseline, n = len(j.ops) the
file as the journal left it. Returns false on an I/O error.
*/
journal_image_kill :: proc(b: Baseline, j: Journal, n: int, path: string) -> bool {
	assert(0 <= n && n <= len(j.ops))
	img := image_init(b, context.temp_allocator)
	for r in j.ops[:n] {
		image_apply(&img, r)
	}
	return image_write(path, img[:])
}

// The txn_id of the meta page a recorded operation writes, if it writes one.
// meta_write writes the page header and the meta and nothing else, so its
// write has exactly that length; every other write is whole pages.
record_meta_txn_id :: proc(r: Io_Record) -> (txn_id: u64, ok: bool) {
	if r.kind != .Write || len(r.bytes) != kv.META_OFFSET + size_of(kv.Meta) {
		return 0, false
	}
	meta: kv.Meta
	mem.copy(&meta, &r.bytes[kv.META_OFFSET], size_of(kv.Meta))
	return u64(meta.txn_id), u32(meta.magic) == kv.MAGIC
}

/*
The crash sweeps (KV-I-0005 D1, D2, KV-T-0027).

A workload builds a database, takes its baseline (crash_baseline, which
also starts the journal), makes its commits through crash_put, crash_del
and crash_commit, and ends with crash_finish. What it leaves in a Crash_Run
is everything a sweep needs: the baseline, the journal, and the committed
model after every commit, indexed by txn_id. A sweep then builds images of
the file from the journal, one or more per cut, and checks each with
crash_image_check against the states it is allowed to open at:

- a process kill after the first n operations (crash_sweep_kill): exactly
  crash_kill_txn(run, n), the commit whose meta-page write is the last one
  among them, or the baseline if there is none;
- a power loss (crash_sweep_power): crash_synced_txn(run, n), the last
  commit whose meta page was followed by a sync, or its successor if and
  only if that successor's meta-page write is in the image whole.

Every workload commit is on the thread and the env the journal records,
and the model is the store's contents key by key (see model.odin), so the
check is model_diff, plus space_check, one more commit and a reopen.
*/
Crash_Run :: struct {
	name:      string,
	ks:        Key_Space,
	// The state being built: crash_put and crash_del change it as they
	// change the store, crash_commit copies it.
	model:     Model,
	// Bumped by every crash_put, so no two values are the same.
	version:   u32,
	// Largest value the store has held, for sizing value buffers.
	max_value: int,
	page_size: int,
	// What crash_image_check opens images with: the default options, or
	// the page size a workload created its database at (creation, whose
	// D6 rule is at the page size of the open).
	options:   kv.Options,
	base:      Baseline,
	journal:   Journal,
	// The txn_id of the baseline's snapshot.
	base_txn:  kv.Txn_Id,
	// The committed state of base_txn − 1, if the workload recorded it
	// (crash_pre_baseline), for the meta-corruption images.
	pre:       Model,
	// states[i] is the committed state of txn base_txn + i: states[0] the
	// baseline's, then one per workload commit.
	states:    [dynamic]Model,
	commits:   [dynamic]Crash_Commit,
	// env_stats' spills when the last commit returned.
	spills:    int,
	value_buf: []byte,
}

// One workload commit.
Crash_Commit :: struct {
	txn_id:    kv.Txn_Id,
	// Its operations in the journal, [first, end): from the end of the
	// previous commit, so pages spilled and overflow runs written before
	// the commit are its own.
	first:     int,
	end:       int,
	// The last page of the snapshot the transaction began from: a write at
	// or below it (and past the meta pages) is into a reused page.
	prev_last: kv.Pgno,
	// Pages spilled by the transaction.
	spills:    int,
}

crash_run_init :: proc(run: ^Crash_Run, name: string, ks: Key_Space) {
	run^ = {
		name  = name,
		ks    = ks,
		model = make(Model, len(ks.keys)),
	}
}

crash_run_destroy :: proc(run: ^Crash_Run) {
	journal_destroy(&run.journal)
	baseline_destroy(&run.base)
	for m in run.states {
		delete(m)
	}
	delete(run.states)
	delete(run.commits)
	delete(run.model)
	delete(run.pre)
	delete(run.value_buf)
	run^ = {}
}

// Puts key `id` with a new value of `size` bytes, and records it in the
// model if the put succeeds.
crash_put :: proc(txn: ^kv.Txn, run: ^Crash_Run, id: int, size: int) -> kv.Error {
	run.version += 1
	spec := Val_Spec{present = true, version = run.version, size = size}
	value := model_value(id, spec, make([]byte, size, context.temp_allocator))
	kv.put(txn, run.ks.keys[id], value) or_return
	run.model[id] = spec
	run.max_value = max(run.max_value, size)
	return .None
}

// Deletes key `id`, and records it in the model if the delete succeeds.
crash_del :: proc(txn: ^kv.Txn, run: ^Crash_Run, id: int) -> kv.Error {
	kv.del(txn, run.ks.keys[id]) or_return
	run.model[id] = {}
	return .None
}

/*
Takes the baseline: the file at `path` as the last commit of `env` left
it, its txn_id and the model's state. Then starts the journal on this
thread, so everything the workload does from here is recorded. The env
must be open on this thread with no transaction.
*/
crash_baseline :: proc(t: ^testing.T, run: ^Crash_Run, env: ^kv.Env, path: string) -> bool {
	ok: bool
	run.base, ok = baseline_take(path)
	if !testing.expectf(t, ok && run.base.exists, "%s: taking the baseline", run.name) {
		return false
	}
	run.base_txn = kv.env_snapshot(env).txn_id
	run.page_size = env.page_size
	run.spills = kv.env_stats(env).spills
	append(&run.states, slice.clone(run.model))
	journal_start(&run.journal)
	return true
}

// Commits a workload transaction and records the state it committed.
crash_commit :: proc(t: ^testing.T, run: ^Crash_Run, env: ^kv.Env, txn: ^kv.Txn, loc := #caller_location) -> bool {
	prev_last := kv.env_snapshot(env).last_pgno
	err := kv.txn_commit(txn)
	if !testing.expectf(t, err == .None, "%s: commit %d: %v", run.name, len(run.commits) + 1, err, loc = loc) {
		return false
	}
	snap := kv.env_snapshot(env)
	want := run.base_txn + kv.Txn_Id(len(run.states))
	if !testing.expectf(t, snap.txn_id == want, "%s: committed txn %d, want %d", run.name, snap.txn_id, want, loc = loc) {
		return false
	}
	spills := kv.env_stats(env).spills
	first := 0 if len(run.commits) == 0 else run.commits[len(run.commits) - 1].end
	append(&run.commits, Crash_Commit{snap.txn_id, first, len(run.journal.ops), prev_last, spills - run.spills})
	run.spills = spills
	append(&run.states, slice.clone(run.model))
	return true
}

// Closes the workload's env and stops the journal.
crash_finish :: proc(run: ^Crash_Run, env: ^kv.Env) {
	kv.env_close(env)
	journal_stop()
	// Large enough for crash_image_check's extra commit too.
	run.value_buf = make([]byte, max(run.max_value, CRASH_EXTRA.size))
}

// Records the model as the state of base_txn − 1: call it before the
// changes of the last commit before crash_baseline.
crash_pre_baseline :: proc(run: ^Crash_Run) {
	delete(run.pre)
	run.pre = slice.clone(run.model)
}

// The committed state of `txn_id`, if the run has it.
crash_state :: proc(run: ^Crash_Run, txn_id: kv.Txn_Id) -> (m: Model, ok: bool) {
	if run.pre != nil && txn_id + 1 == run.base_txn {
		return run.pre, true
	}
	if txn_id < run.base_txn || u64(txn_id - run.base_txn) >= u64(len(run.states)) {
		return nil, false
	}
	return run.states[txn_id - run.base_txn], true
}

// The state a process kill after the first `n` operations of the journal
// leaves: the txn_id of the last meta-page write among them, or the
// baseline's. A kill loses nothing a write handed to the OS, so a meta page
// written is a commit made, synced or not.
crash_kill_txn :: proc(run: ^Crash_Run, n: int) -> kv.Txn_Id {
	#reverse for r in run.journal.ops[:n] {
		if id, ok := record_meta_txn_id(r); ok {
			return kv.Txn_Id(id)
		}
	}
	return run.base_txn
}

// The last commit durable after the first `n` operations whatever a power
// loss does to the writes after them: the txn_id of the last meta-page
// write followed by a sync among them, or the baseline's.
crash_synced_txn :: proc(run: ^Crash_Run, n: int) -> kv.Txn_Id {
	synced := false
	#reverse for r in run.journal.ops[:n] {
		if r.kind == .Sync {
			synced = true
		} else if id, ok := record_meta_txn_id(r); ok && synced {
			return kv.Txn_Id(id)
		}
	}
	return run.base_txn
}

// The key crash_image_check's extra commit changes, and its new value.
@(private = "file")
CRASH_EXTRA_ID :: 0
@(private = "file")
CRASH_EXTRA :: Val_Spec{present = true, version = max(u32), size = 64}

/*
Checks the database image at `path` (closed): env_open succeeds, at one of
the `allowed` txn_ids; what it holds is that commit's state, key by key and
in scans both ways (model_diff, which includes tree_check); space_check
passes; one more commit succeeds; and a reopen is at that commit, holding
the state it made. Failures name the run and `what` (the cut). Returns
false on the first failure.
*/
crash_image_check :: proc(t: ^testing.T, run: ^Crash_Run, path: string, allowed: []kv.Txn_Id, what: string, loc := #caller_location) -> bool {
	env, err := kv.env_open(path, run.options)
	if !testing.expectf(t, err == .None, "%s, %s: env_open: %v", run.name, what, err, loc = loc) {
		return false
	}
	txn_id := kv.env_snapshot(env).txn_id
	state, known := crash_state(run, txn_id)
	if !testing.expectf(t, known && slice.contains(allowed, txn_id), "%s, %s: opened at txn %d, allowed %v", run.name, what, txn_id, allowed, loc = loc) {
		kv.env_close(env)
		return false
	}
	if diff := crash_state_diff(env, run, state); diff != "" {
		testing.expectf(t, false, "%s, %s: txn %d: %s", run.name, what, txn_id, diff, loc = loc)
		kv.env_close(env)
		return false
	}

	// One more commit, on whatever free list the image left.
	next := slice.clone(state, context.temp_allocator)
	next[CRASH_EXTRA_ID] = CRASH_EXTRA
	txn, _ := kv.txn_begin(env, read_only = false)
	err = kv.put(&txn, run.ks.keys[CRASH_EXTRA_ID], model_value(CRASH_EXTRA_ID, CRASH_EXTRA, run.value_buf))
	if err == .None {
		err = kv.txn_commit(&txn)
	}
	kv.txn_abort(&txn)
	kv.env_close(env)
	if !testing.expectf(t, err == .None, "%s, %s: the next commit on txn %d: %v", run.name, what, txn_id, err, loc = loc) {
		return false
	}

	env, err = kv.env_open(path, run.options)
	if !testing.expectf(t, err == .None, "%s, %s: reopen after the next commit: %v", run.name, what, err, loc = loc) {
		return false
	}
	defer kv.env_close(env)
	reopened := kv.env_snapshot(env).txn_id
	if !testing.expectf(t, reopened == txn_id + 1, "%s, %s: reopened at txn %d after committing %d", run.name, what, reopened, txn_id + 1, loc = loc) {
		return false
	}
	if diff := crash_state_diff(env, run, next); diff != "" {
		testing.expectf(t, false, "%s, %s: after the next commit: %s", run.name, what, diff, loc = loc)
		return false
	}
	return true
}

// model_diff and space_check on a new read transaction of `env`.
@(private = "file")
crash_state_diff :: proc(env: ^kv.Env, run: ^Crash_Run, m: Model) -> string {
	txn, err := kv.txn_begin(env)
	if err != .None {
		return fmt.tprintf("txn_begin: %v", err)
	}
	defer kv.txn_abort(&txn)
	if diff := model_diff(&txn, run.ks, m, run.value_buf); diff != "" {
		return diff
	}
	if ok, reason := kv.space_check(&txn); !ok {
		return fmt.tprintf("space_check: %s", reason)
	}
	return ""
}

// What a sweep covered.
Crash_Sweep :: struct {
	// Images checked.
	cuts:           int,
	// Cuts right after a truncate (file growth).
	after_truncate: int,
	// Cuts that open at one of the workload's commits, not the baseline
	// (for a power-loss sweep: images).
	committed:      int,
	// A power-loss sweep's cuts with unsynced operations, its power-loss
	// images, and its meta-corruption images.
	windows:        int,
	images:         int,
	corrupt:        int,
	// A creation sweep's power-loss images that open as no database
	// (Corrupted, see crash_sweep_create_power): a meta write torn with
	// nothing whole beside it, or a meta write kept with the sizing lost.
	refused_torn:   int,
	refused_short:  int,
}

/*
Sweeps process kills over the run's journal: for every n from 0 (the
baseline) to len(ops) (the whole journal), the kill image after the first
n operations must open at exactly crash_kill_txn(run, n) and pass
crash_image_check. Stops at the first cut that fails. `path` is the image
file, rewritten for every cut.
*/
crash_sweep_kill :: proc(t: ^testing.T, run: ^Crash_Run, path: string) -> (s: Crash_Sweep, ok: bool) {
	ops := run.journal.ops[:]
	img := image_init(run.base)
	defer delete(img)
	for n in 0 ..= len(ops) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		after := "the baseline"
		if n > 0 {
			r := ops[n - 1]
			image_apply(&img, r)
			after = fmt.tprintf("%v of %d bytes at %d", r.kind, len(r.bytes), r.offset) if r.kind != .Truncate else fmt.tprintf("Truncate to %d", r.size)
		}
		if !testing.expectf(t, image_write(path, img[:]), "%s: writing the image", run.name) {
			return s, false
		}
		want := crash_kill_txn(run, n)
		if !crash_image_check(t, run, path, {want}, fmt.tprintf("kill at cut %d of %d, after %s", n, len(ops), after)) {
			return s, false
		}
		s.cuts += 1
		s.after_truncate += int(n > 0 && ops[n - 1].kind == .Truncate)
		s.committed += int(want != run.base_txn)
	}
	return s, true
}

/*
Power-loss images (KV-I-0005 D2, KV-T-0028).

A power loss keeps everything up to the last sync that returned, and of the
operations after it any subset: each write lost, whole, or torn to some of
its 512-byte sectors, and a truncate taken effect or not. Reordering needs
no model of its own: the writes in a subset land at their own offsets, so
the order they reached the disk in changes nothing unless two overlap, and
of two overlapping writes the later one is the newer bytes, so they are
applied in journal order.

A meta-page write (header and meta, 96 bytes) is shorter than a sector, so
no sector tear splits it. Io_Tear can still keep a prefix of it: a stricter
model than an atomic sector, and the one that shows the meta checksum at
work.
*/
POWER_SECTOR :: 512

// A write a power loss tore: the byte ranges of it, [lo, hi) within its
// bytes, that reached the disk. `op` is its index in the journal.
Io_Tear :: struct {
	op:   int,
	keep: [][2]int,
}

// The operations up to and including the last sync among the first `n` of
// `j`: what a power loss after them keeps whatever happens.
journal_synced :: proc(j: Journal, n: int) -> int {
	#reverse for r, i in j.ops[:n] {
		if r.kind == .Sync {
			return i + 1
		}
	}
	return 0
}

/*
The image a power loss after the first `n` operations of `j` leaves: the
baseline, every operation up to the last sync among them
(journal_synced), then only the operations of `subset` (journal indexes in
[journal_synced(j, n), n), ascending), each whole unless `tears` names it,
in which case only the ranges it keeps. A truncate outside the subset
leaves the size as it was; a write past the end extends the file with
zeros, as ever.
*/
image_power :: proc(b: Baseline, j: Journal, n: int, subset: []int, tears: []Io_Tear, allocator := context.allocator) -> [dynamic]byte {
	synced := journal_synced(j, n)
	img := image_init(b, allocator)
	for r in j.ops[:synced] {
		image_apply(&img, r)
	}
	prev := synced - 1
	for i in subset {
		assert(prev < i && i < n, "a power-loss subset out of order or outside the unsynced operations")
		prev = i
		r := j.ops[i]
		tear, torn := power_tear(tears, i)
		if !torn {
			image_apply(&img, r)
			continue
		}
		assert(r.kind == .Write, "only a write can be torn")
		for k in tear.keep {
			part := r
			part.offset = r.offset + i64(k[0])
			part.bytes = r.bytes[k[0]:k[1]]
			image_apply(&img, part)
		}
	}
	return img
}

/*
Writes to `path` the image a power loss after the first `n` operations of
`j` leaves, keeping only `subset` of the unsynced ones and tearing
`tears` (see image_power). Returns false on an I/O error.
*/
journal_image_power :: proc(b: Baseline, j: Journal, n: int, subset: []int, tears: []Io_Tear, path: string) -> bool {
	img := image_power(b, j, n, subset, tears, context.temp_allocator)
	return image_write(path, img[:])
}

@(private = "file")
power_tear :: proc(tears: []Io_Tear, op: int) -> (tear: Io_Tear, ok: bool) {
	for t in tears {
		if t.op == op {
			return t, true
		}
	}
	return {}, false
}

// Whether the bytes of write `r` are all in the image.
@(private = "file")
image_has :: proc(img: []byte, r: Io_Record) -> bool {
	end := int(r.offset) + len(r.bytes)
	return end <= len(img) && slice.equal(img[r.offset:end], r.bytes)
}

// How many random subsets a power-loss sweep takes of each unsynced
// window, after the fixed images.
CRASH_SUBSETS :: #config(KV_CRASH_SUBSETS, 16)

// The torn meta page of the fixed images: its header and the meta up to
// and including the new txn_id, the rest (the tree, and the checksum) as
// the slot held before. It claims the newer txn_id, and only the checksum
// can tell.
@(private = "file")
POWER_META_TORN :: kv.META_OFFSET + int(offset_of(kv.Meta, txn_id)) + size_of(u64)

/*
Sweeps power losses over the run's journal. A power loss after the first
n operations can leave any image a power loss just before the next sync
can (the same synced prefix, and a subset of fewer unsynced operations is
a subset of more), and must open at the same state, so the sweep cuts
only there: before each sync, and at the end of the journal. Each cut's
window is the operations since the previous sync. Per window, the fixed
images: none of them, all of them, only the meta-page write, and all of
them with the meta-page write torn (the last two when the window has one);
then CRASH_SUBSETS random subsets with random tears, from the test's seed.

An image may open at crash_synced_txn(run, n), or at its successor if and
only if the successor's meta-page write is in the image whole: a meta page
is either all there, or its checksum rejects it and the other slot is used.

Then, beyond the power-loss model, one meta-corruption image per cut (see
crash_image_meta_corrupt). Stops at the first image that fails.
*/
crash_sweep_power :: proc(t: ^testing.T, run: ^Crash_Run, path: string) -> (s: Crash_Sweep, ok: bool) {
	ops := run.journal.ops[:]
	for n in 0 ..= len(ops) {
		if n < len(ops) && ops[n].kind != .Sync {
			continue
		}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		s.cuts += 1
		if !crash_image_meta_corrupt(t, run, path, n, &s) {
			return s, false
		}
		first := journal_synced(run.journal, n)
		if first == n {
			// Nothing unsynced: the kill image at n, which the kill sweep checks.
			continue
		}
		s.windows += 1
		all := make([]int, n - first, context.temp_allocator)
		meta := -1
		for &i, k in all {
			i = first + k
			if _, is_meta := record_meta_txn_id(ops[i]); is_meta {
				meta = i
			}
		}

		// The fixed images.
		if !crash_power_image(t, run, path, n, {}, {}, "none", &s) || !crash_power_image(t, run, path, n, all, {}, "all", &s) {
			return s, false
		}
		if meta >= 0 {
			torn := []Io_Tear{{meta, {{0, POWER_META_TORN}}}}
			if len(all) > 1 && !crash_power_image(t, run, path, n, {meta}, {}, "only the meta page", &s) {
				return s, false
			}
			if !crash_power_image(t, run, path, n, all, torn, "the meta page torn", &s) {
				return s, false
			}
		}

		// Random subsets, each from its own generator so it reproduces
		// from the seed, the cut and its number alone.
		for k in 0 ..< CRASH_SUBSETS {
			state := rand.create(t.seed ~ u64(n) << 20 ~ u64(k))
			gen := rand.default_random_generator(&state)
			subset, tears := power_random(ops, all, gen)
			if !crash_power_image(t, run, path, n, subset, tears, fmt.tprintf("random subset %d", k), &s) {
				return s, false
			}
		}
	}
	return s, true
}

// A random subset of the window `all`: each operation kept with a
// probability drawn per subset (sparse and dense subsets both), and each
// write kept torn with probability 1/4, to a random half of its sectors,
// or to a random prefix if it is shorter than a sector.
@(private = "file")
power_random :: proc(ops: []Io_Record, all: []int, gen: runtime.Random_Generator) -> (subset: []int, tears: []Io_Tear) {
	keep := rand.float64(gen)
	sub := make([dynamic]int, context.temp_allocator)
	torn := make([dynamic]Io_Tear, context.temp_allocator)
	for i in all {
		if rand.float64(gen) >= keep {
			continue
		}
		append(&sub, i)
		r := ops[i]
		if r.kind != .Write || rand.int_max(4, gen) != 0 {
			continue
		}
		ranges := make([dynamic][2]int, context.temp_allocator)
		if len(r.bytes) <= POWER_SECTOR {
			if len(r.bytes) > 1 {
				append(&ranges, [2]int{0, 1 + rand.int_max(len(r.bytes) - 1, gen)})
			}
		} else {
			for lo := 0; lo < len(r.bytes); lo += POWER_SECTOR {
				if rand.int_max(2, gen) == 0 {
					continue
				}
				hi := min(lo + POWER_SECTOR, len(r.bytes))
				if n := len(ranges); n > 0 && ranges[n - 1][1] == lo {
					ranges[n - 1][1] = hi
				} else {
					append(&ranges, [2]int{lo, hi})
				}
			}
		}
		append(&torn, Io_Tear{i, ranges[:]})
	}
	return sub[:], torn[:]
}

// Builds and checks one power-loss image.
@(private = "file")
crash_power_image :: proc(t: ^testing.T, run: ^Crash_Run, path: string, n: int, subset: []int, tears: []Io_Tear, name: string, s: ^Crash_Sweep) -> bool {
	img := image_power(run.base, run.journal, n, subset, tears, context.temp_allocator)
	if !testing.expectf(t, image_write(path, img[:]), "%s: writing the image", run.name) {
		return false
	}
	want := crash_synced_txn(run, n)
	for i in subset {
		if id, is_meta := record_meta_txn_id(run.journal.ops[i]); is_meta && image_has(img[:], run.journal.ops[i]) {
			assert(kv.Txn_Id(id) == want + 1, "a meta page in the unsynced window that isn't the successor's")
			want = kv.Txn_Id(id)
		}
	}
	what := fmt.tprintf("power loss [seed %d] at cut %d of %d, %s: subset %s, tears %s",
		t.seed, n, len(run.journal.ops), name, power_ranges(subset), power_tears(tears))
	s.images += 1
	s.committed += int(want != run.base_txn)
	return crash_image_check(t, run, path, {want}, what)
}

// "3-7 9" for journal indexes 3, 4, 5, 6, 7 and 9.
@(private = "file")
power_ranges :: proc(ids: []int) -> string {
	if len(ids) == 0 {
		return "none"
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(ids); {
		j := i
		for j + 1 < len(ids) && ids[j + 1] == ids[j] + 1 {
			j += 1
		}
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if j > i {
			fmt.sbprintf(&b, "%d-%d", ids[i], ids[j])
		} else {
			fmt.sbprintf(&b, "%d", ids[i])
		}
		i = j + 1
	}
	return strings.to_string(b)
}

// "12 kept [0:512] [1024:4096]" per torn write.
@(private = "file")
power_tears :: proc(tears: []Io_Tear) -> string {
	if len(tears) == 0 {
		return "none"
	}
	b := strings.builder_make(context.temp_allocator)
	for tear, i in tears {
		fmt.sbprintf(&b, "%s%d kept", "; " if i > 0 else "", tear.op)
		for k in tear.keep {
			fmt.sbprintf(&b, " [%d:%d]", k[0], k[1])
		}
	}
	return strings.to_string(b)
}

/*
The meta-corruption image at cut n: the kill image after the first n
operations with the meta page of the newest synced commit S made unreadable
(its checksum flipped), where no later meta page was written. **Beyond the
power-loss model**, which can't damage a synced meta page, and beyond the
initiative's (it doesn't recover from corruption in general): the fallback
to the other slot is the store's own design, and what it falls back to is
S − 1, which the reuse horizon keeps intact however far the transaction
after S got (KV-I-0002 D1). So the image must open at S − 1 and pass
crash_image_check. Taken only where the run knows S − 1's state.
*/
@(private = "file")
crash_image_meta_corrupt :: proc(t: ^testing.T, run: ^Crash_Run, path: string, n: int, s: ^Crash_Sweep) -> bool {
	S := crash_synced_txn(run, n)
	if crash_kill_txn(run, n) != S {
		return true
	}
	if _, known := crash_state(run, S - 1); !known {
		return true
	}
	img := image_init(run.base, context.temp_allocator)
	for r in run.journal.ops[:n] {
		image_apply(&img, r)
	}
	img[int(S & 1) * run.page_size + kv.META_OFFSET + int(offset_of(kv.Meta, checksum))] ~= 0xff
	if !testing.expectf(t, image_write(path, img[:]), "%s: writing the image", run.name) {
		return false
	}
	s.corrupt += 1
	what := fmt.tprintf("meta corruption at cut %d of %d: the meta page of txn %d unreadable", n, len(run.journal.ops), S)
	return crash_image_check(t, run, path, {S - 1}, what)
}

/*
Power losses during creation (KV-I-0005 D6, workload 5, KV-T-0029).

env_open of a new file is one window with no sync before it: truncate to
two pages, the meta page of slot 0, the meta page of slot 1, sync. There
is no committed state before it, so the power-loss sweep of commits
(which expects the synced commit or its successor) doesn't fit; this one
takes every combination of the truncate taken or not and each meta write
lost, whole, or torn to a prefix of 1, POWER_META_TORN or all but one of
its bytes (50 images), then CRASH_SUBSETS random ones. Each image is
classified by what it is, and must open accordingly:

- no file, or two pages all zero (D6): as an empty database, and pass
  crash_image_check at txn 0;
- two pages with a meta write whole in it: the same;
- anything else, which is a meta write torn with no whole one beside it,
  or a meta write kept while the truncate was lost (a file shorter than
  two pages, or one page and a meta prefix): Corrupted. Such a file has
  no valid meta page and isn't all zero, so D6 refuses it by design. This
  pins what the store does today; whether a torn creation should open is
  the owner's question (KV-T-0029's status update). They are counted in
  refused_torn (two pages long) and refused_short.

The run must hold the creation's journal and nothing else, with states[0]
the empty database at txn 0.
*/
crash_sweep_create_power :: proc(t: ^testing.T, run: ^Crash_Run, path: string) -> (s: Crash_Sweep, ok: bool) {
	ops := run.journal.ops[:]
	shape := len(ops) == 4 && ops[0].kind == .Truncate && ops[3].kind == .Sync
	for i in 1 ..= 2 {
		if shape {
			id, is_meta := record_meta_txn_id(ops[i])
			shape = is_meta && id == 0
		}
	}
	if !testing.expectf(t, shape, "%s: creation is not truncate, two meta writes, sync: %v", run.name, ops) {
		return s, false
	}
	n := len(ops) - 1
	s.cuts = 1
	s.windows = 1
	meta_len := len(ops[1].bytes)
	// Per meta write: lost (-1), whole (0), or torn to a prefix of that many bytes.
	fates := []int{-1, 0, 1, POWER_META_TORN, meta_len - 1}
	for truncate in ([]bool{false, true}) {
		for f1 in fates {
			for f2 in fates {
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				subset := make([dynamic]int, context.temp_allocator)
				tears := make([dynamic]Io_Tear, context.temp_allocator)
				if truncate {
					append(&subset, 0)
				}
				for f, k in ([]int{f1, f2}) {
					if f >= 0 {
						append(&subset, 1 + k)
					}
					if f > 0 {
						keep := make([][2]int, 1, context.temp_allocator)
						keep[0] = {0, f}
						append(&tears, Io_Tear{1 + k, keep})
					}
				}
				if !crash_create_image(t, run, path, n, subset[:], tears[:], "fixed", &s) {
					return s, false
				}
			}
		}
	}
	all := []int{0, 1, 2}
	for k in 0 ..< CRASH_SUBSETS {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		state := rand.create(t.seed ~ u64(k) << 32)
		gen := rand.default_random_generator(&state)
		subset, tears := power_random(ops, all, gen)
		if !crash_create_image(t, run, path, n, subset, tears, fmt.tprintf("random subset %d", k), &s) {
			return s, false
		}
	}
	return s, true
}

// Builds, classifies and checks one power-loss image of creation (see
// crash_sweep_create_power).
@(private = "file")
crash_create_image :: proc(t: ^testing.T, run: ^Crash_Run, path: string, n: int, subset: []int, tears: []Io_Tear, name: string, s: ^Crash_Sweep) -> bool {
	img := image_power(run.base, run.journal, n, subset, tears, context.temp_allocator)
	if !testing.expectf(t, image_write(path, img[:]), "%s: writing the image", run.name) {
		return false
	}
	s.images += 1
	what := fmt.tprintf("power loss [seed %d] during creation, %s: subset %s, tears %s: %d bytes",
		t.seed, name, power_ranges(subset), power_tears(tears), len(img))
	two_pages := len(img) == 2 * run.page_size
	opens := len(img) == 0 || (two_pages && mem.check_zero(img[:]))
	opens |= two_pages && (image_has(img[:], run.journal.ops[1]) || image_has(img[:], run.journal.ops[2]))
	if opens {
		return crash_image_check(t, run, path, {0}, what)
	}
	env, err := kv.env_open(path, run.options)
	if err == .None {
		kv.env_close(env)
	}
	if !testing.expectf(t, err == .Corrupted, "%s, %s: env_open: %v, want Corrupted (no valid meta page, not all zero)", run.name, what, err) {
		return false
	}
	if two_pages {
		s.refused_torn += 1
	} else {
		s.refused_short += 1
	}
	return true
}
