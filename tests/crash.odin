package kv_tests

import "core:c"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sys/posix"

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
