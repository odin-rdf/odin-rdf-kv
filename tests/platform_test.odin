#+build darwin, linux
package kv_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

/*
The platform measurement behind the memory budget (KV-I-0004 D12,
KV-T-0019): what evicting part of a read-only shared file mapping does to
the process's resident size on this platform, what each way of asking the
OS about residency reports, whether a MAP_FIXED remap is safe while other
threads read the range, which calls really release anonymous memory (the
dirty pool, D1), and what each of them costs per chunk. It calls the OS
directly and uses nothing in `kv/`. The results are recorded in KV-T-0019.

Resident sizes are process-wide, so nothing else may run at the same time:

	odin test tests -o:speed -define:KV_PLATFORM=true -define:ODIN_TEST_THREADS=1 \
		-define:ODIN_TEST_NAMES=kv_tests.test_platform_residency,kv_tests.test_platform_remap_under_load

The remap test also runs under -sanitize:thread. It runs for
KV_PLATFORM_SECONDS per eviction method (default 10).

Only the registration is guarded: the procedures below are compiled and
type-checked by every run, so the measurement can't rot. The per-platform
parts (constants, `platform_residency`) are in platform_darwin_test.odin and
platform_linux_test.odin.
*/
when #config(KV_PLATFORM, false) {
	@(test)
	test_platform_residency :: proc(t: ^testing.T) {
		platform_file_eviction(t)
		platform_anon_release(t)
		platform_costs(t)
	}

	@(test)
	test_platform_remap_under_load :: proc(t: ^testing.T) {
		platform_remap_under_load(t)
	}
}

@(private = "file")
PLATFORM_SECONDS :: #config(KV_PLATFORM_SECONDS, 10)

// The mapped file: large enough that the figures stand out from the noise of
// the rest of the process.
@(private = "file")
FILE_SIZE :: 64 << 20

// The anonymous region standing in for the dirty pool (D1's default budget).
@(private = "file")
ANON_SIZE :: 4 << 20

when ODIN_OS == .Darwin {
	foreign import platform_libc "system:System"
} else {
	foreign import platform_libc "system:c"
}

// madvise rather than posix_madvise: glibc's posix_madvise ignores
// POSIX_MADV_DONTNEED, and neither binds the platform-specific advice.
foreign platform_libc {
	madvise :: proc(addr: rawptr, len: c.size_t, advice: c.int) -> c.int ---
	mincore :: proc(addr: rawptr, len: c.size_t, vec: [^]u8) -> c.int ---
}

// What the OS says about one range of the address space, and about the
// process. Sizes in bytes; -1 where the platform has no such source.
Platform_Residency :: struct {
	// Pages of the range `mincore` reports resident.
	mincore:   int,
	// Pages of the range present in the process's page tables:
	// /proc/self/pagemap on Linux.
	present:   int,
	// The resident count of the regions in the range: mach_vm_region on
	// macOS, the Rss of the mappings in /proc/self/smaps on Linux.
	region:    int,
	// The process's resident size: task_info's resident_size on macOS,
	// /proc/self/statm on Linux.
	rss:       int,
	// The anonymous memory charged to the process: phys_footprint on macOS,
	// RssAnon on Linux.
	footprint: int,
}

// Ways to evict part of a read-only shared file mapping. Each keeps every
// address valid: the range reads the same bytes afterwards.
Platform_Evict :: enum {
	// madvise(MADV_DONTNEED).
	Dontneed,
	// posix_madvise(POSIX_MADV_DONTNEED), which kv/os_posix.odin's wrapper
	// would call: glibc makes it a no-op.
	Posix_Dontneed,
	// madvise(MADV_PAGEOUT), Linux only: also drops the page cache.
	Pageout,
	// mmap(MAP_FIXED) of the same file range over itself.
	Remap,
	// msync(MS_INVALIDATE).
	Invalidate,
}

// Ways to release a range of private anonymous memory (the dirty pool),
// leaving it usable again.
Platform_Release :: enum {
	// madvise(MADV_FREE).
	Free,
	// madvise(MADV_DONTNEED).
	Dontneed,
	// madvise(MADV_FREE_REUSABLE), macOS only; MADV_FREE_REUSE before reuse.
	Free_Reusable,
	// mmap(MAP_FIXED | MAP_ANONYMOUS) over the range.
	Remap,
	// core:mem/virtual's decommit, then commit before reuse.
	Decommit,
}

@(private = "file")
page_size :: proc() -> int {
	return int(posix.sysconf(._PAGESIZE))
}

@(private = "file")
mib :: proc(bytes: int) -> string {
	if bytes < 0 {
		return "n/a"
	}
	return fmt.tprintf("%.1f", f64(bytes) / f64(1 << 20))
}

@(private = "file")
kib :: proc(bytes: int) -> string {
	if bytes < 0 {
		return "n/a"
	}
	return fmt.tprintf("%d", bytes >> 10)
}

// A width on a number pads it with zeros, so numbers are formatted first
// and the strings padded.
@(private = "file")
f2 :: proc(v: f64) -> string {
	return fmt.tprintf("%.2f", v)
}

@(private = "file")
us :: proc(d: time.Duration) -> f64 {
	return time.duration_microseconds(d)
}

// The 8-byte word the test file holds at `offset`.
@(private = "file")
word_at :: proc(offset: int) -> u64 {
	return u64(offset) ~ 0x9E37_79B9_7F4A_7C15
}

@(private = "file")
Test_File :: struct {
	dir:  Temp_Dir,
	fd:   posix.FD,
}

// Writes the test file, syncs it so its pages are clean, as a committed
// database's are, and reads it once so it is in the page cache.
@(private = "file")
test_file_create :: proc(t: ^testing.T) -> (f: Test_File) {
	f.dir = temp_dir_create(t)
	path := strings.clone_to_cstring(temp_dir_file(f.dir, "platform"), context.temp_allocator)
	f.fd = posix.open(path, {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
	testing.expect(t, f.fd != -1, "open failed")

	buf := make([]u64, (1 << 20) / 8)
	defer delete(buf)
	for off := 0; off < FILE_SIZE; off += 1 << 20 {
		for &w, i in buf {
			w = word_at(off + i * 8)
		}
		n := posix.pwrite(f.fd, ([^]u8)(raw_data(buf)), c.size_t(len(buf) * 8), posix.off_t(off))
		testing.expect_value(t, n, len(buf) * 8)
	}
	posix.fsync(f.fd)
	for off := 0; off < FILE_SIZE; off += 1 << 20 {
		posix.pread(f.fd, ([^]u8)(raw_data(buf)), c.size_t(len(buf) * 8), posix.off_t(off))
	}
	return f
}

@(private = "file")
test_file_destroy :: proc(f: ^Test_File) {
	posix.close(f.fd)
	temp_dir_destroy(&f.dir, "platform")
}

// Maps the whole file read-only and shared with random-access advice, as
// the store does.
@(private = "file")
file_map :: proc(t: ^testing.T, f: Test_File) -> [^]byte {
	p := posix.mmap(nil, FILE_SIZE, {.READ}, {.SHARED}, f.fd, 0)
	testing.expect(t, p != posix.MAP_FAILED, "mmap failed")
	madvise(p, FILE_SIZE, MADV_RANDOM)
	return ([^]byte)(p)
}

// Reads one byte of every page in the range, so every page is faulted in.
@(private = "file")
touch :: proc(base: [^]byte, off, size: int) -> (sum: u64) {
	ps := page_size()
	for o := off; o < off + size; o += ps {
		sum += u64(intrinsics.volatile_load(&base[o]))
	}
	return sum
}

// Writes one byte of every page in the range.
@(private = "file")
dirty :: proc(base: [^]byte, off, size: int) {
	ps := page_size()
	for o := off; o < off + size; o += ps {
		intrinsics.volatile_store(&base[o], 0xA5)
	}
}

// Checks the first word of every page in the range against the file.
@(private = "file")
file_bytes_ok :: proc(base: [^]byte, off, size: int) -> bool {
	ps := page_size()
	for o := off; o < off + size; o += ps {
		if intrinsics.volatile_load((^u64)(&base[o])) != word_at(o) {
			return false
		}
	}
	return true
}

@(private = "file")
file_evict :: proc(m: Platform_Evict, f: Test_File, base: [^]byte, off, size: int) -> bool {
	switch m {
	case .Dontneed:
		return madvise(&base[off], c.size_t(size), MADV_DONTNEED) == 0
	case .Posix_Dontneed:
		return posix.posix_madvise(&base[off], c.size_t(size), .DONTNEED) == .NONE
	case .Pageout:
		return MADV_PAGEOUT >= 0 && madvise(&base[off], c.size_t(size), MADV_PAGEOUT) == 0
	case .Remap:
		p := posix.mmap(&base[off], c.size_t(size), {.READ}, {.SHARED, .FIXED}, f.fd, posix.off_t(off))
		if p == posix.MAP_FAILED {
			return false
		}
		return madvise(p, c.size_t(size), MADV_RANDOM) == 0
	case .Invalidate:
		return posix.msync(&base[off], c.size_t(size), {.INVALIDATE}) == .OK
	}
	return false
}

@(private = "file")
anon_release :: proc(m: Platform_Release, base: [^]byte, off, size: int) -> bool {
	switch m {
	case .Free:
		return madvise(&base[off], c.size_t(size), MADV_FREE) == 0
	case .Dontneed:
		return madvise(&base[off], c.size_t(size), MADV_DONTNEED) == 0
	case .Free_Reusable:
		return MADV_FREE_REUSABLE >= 0 && madvise(&base[off], c.size_t(size), MADV_FREE_REUSABLE) == 0
	case .Remap:
		p := posix.mmap(&base[off], c.size_t(size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .FIXED}, -1, 0)
		return p != posix.MAP_FAILED
	case .Decommit:
		virtual.decommit(&base[off], uint(size))
		return true
	}
	return false
}

// Makes a released range writable again, where the release method needs it.
@(private = "file")
anon_reuse :: proc(m: Platform_Release, base: [^]byte, off, size: int) {
	#partial switch m {
	case .Free_Reusable:
		madvise(&base[off], c.size_t(size), MADV_FREE_REUSE)
	case .Decommit:
		_ = virtual.commit(&base[off], uint(size))
	}
}

// Residency figures relative to a baseline, for the process-wide ones.
@(private = "file")
Residency_Row :: struct {
	label: string,
	r:     Platform_Residency,
}

@(private = "file")
log_residency_rows :: proc(title: string, base: Platform_Residency, rows: []Residency_Row, unit: proc(int) -> string) {
	log.info(title)
	log.info("  step                                   mincore   present    region  ΔRSS  Δfootprint")
	for row in rows {
		r := row.r
		log.info(fmt.tprintf("  %-38s %8s %9s %9s %5s %11s", row.label, unit(r.mincore), unit(r.present), unit(r.region),
			unit(r.rss - base.rss) if r.rss >= 0 else "n/a", unit(r.footprint - base.footprint) if r.footprint >= 0 else "n/a"))
	}
}

/*
For each eviction method: map the file, measure before touching anything
(mincore and the region count may report page-cache pages that aren't
mapped), touch the first 32 MiB, evict the first 16 MiB, measure, and check
the evicted range still reads the file's bytes. Then a sparse touch, one
byte per 256 KiB, to see how much one fault brings in.
*/
@(private = "file")
platform_file_eviction :: proc(t: ^testing.T) {
	f := test_file_create(t)
	defer test_file_destroy(&f)
	log.infof("file eviction: %d MiB file, page size %d", FILE_SIZE >> 20, page_size())

	for m in Platform_Evict {
		base_line := platform_residency(nil, 0)
		base := file_map(t, f)
		rows: [dynamic]Residency_Row
		defer delete(rows)

		append(&rows, Residency_Row{"mapped, untouched", platform_residency(base, FILE_SIZE)})
		touch(base, 0, 32 << 20)
		append(&rows, Residency_Row{"touched 0–32 MiB", platform_residency(base, FILE_SIZE)})
		ok := file_evict(m, f, base, 0, 16 << 20)
		append(&rows, Residency_Row{"evicted 0–16 MiB", platform_residency(base, FILE_SIZE)})
		time.sleep(100 * time.Millisecond)
		append(&rows, Residency_Row{"… 100 ms later", platform_residency(base, FILE_SIZE)})
		bytes_ok := file_bytes_ok(base, 0, 32 << 20)
		append(&rows, Residency_Row{"re-read 0–32 MiB", platform_residency(base, FILE_SIZE)})
		for off := 32 << 20; off < 48 << 20; off += 256 << 10 {
			touch(base, off, 1)
		}
		append(&rows, Residency_Row{"1 byte per 256 KiB of 32–48 MiB (64)", platform_residency(base, FILE_SIZE)})

		log_residency_rows(fmt.tprintf("file eviction by %v (call ok: %v, bytes after: %v), MiB", m, ok, "ok" if bytes_ok else "WRONG"),
			base_line, rows[:], mib)
		if ok {
			testing.expect(t, bytes_ok, "evicted range reads wrong bytes")
		}
		posix.munmap(base, FILE_SIZE)
	}

	// How long each residency source takes over the whole 64 MiB map, with
	// half of it resident: the cost of D10's check.
	base := file_map(t, f)
	defer posix.munmap(base, FILE_SIZE)
	touch(base, 0, 32 << 20)
	start := time.tick_now()
	for _ in 0 ..< 10 {
		platform_residency(base, FILE_SIZE)
	}
	log.infof("all residency sources over 64 MiB: %.0f µs per call", us(time.tick_since(start)) / 10)
	start = time.tick_now()
	vec := make([]u8, FILE_SIZE / page_size())
	defer delete(vec)
	for _ in 0 ..< 10 {
		mincore(base, FILE_SIZE, raw_data(vec))
	}
	log.infof("mincore alone over 64 MiB: %.0f µs per call", us(time.tick_since(start)) / 10)
	platform_source_costs(base, FILE_SIZE)
}

/*
The dirty pool's release (D1): map 4 MiB of private anonymous memory, write
every page, release it with each method, and measure at once and 100 ms
later. Then write it again, to check the range is still usable.
*/
@(private = "file")
platform_anon_release :: proc(t: ^testing.T) {
	for m in Platform_Release {
		base_line := platform_residency(nil, 0)
		p := posix.mmap(nil, ANON_SIZE, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, -1, 0)
		testing.expect(t, p != posix.MAP_FAILED, "mmap failed")
		base := ([^]byte)(p)
		rows: [dynamic]Residency_Row
		defer delete(rows)

		append(&rows, Residency_Row{"mapped, untouched", platform_residency(base, ANON_SIZE)})
		dirty(base, 0, ANON_SIZE)
		append(&rows, Residency_Row{"written", platform_residency(base, ANON_SIZE)})
		ok := anon_release(m, base, 0, ANON_SIZE)
		append(&rows, Residency_Row{"released", platform_residency(base, ANON_SIZE)})
		time.sleep(100 * time.Millisecond)
		append(&rows, Residency_Row{"… 100 ms later", platform_residency(base, ANON_SIZE)})
		zero := true
		if ok {
			anon_reuse(m, base, 0, ANON_SIZE)
			zero = touch(base, 0, ANON_SIZE) == 0
			dirty(base, 0, ANON_SIZE)
			append(&rows, Residency_Row{"written again", platform_residency(base, ANON_SIZE)})
		}
		log_residency_rows(fmt.tprintf("anonymous release by %v (call ok: %v, reads zero after: %v), KiB", m, ok, zero),
			base_line, rows[:], kib)
		posix.munmap(base, ANON_SIZE)
	}
}

@(private = "file")
Cost :: struct {
	median: f64,
	mean:   f64,
}

@(private = "file")
cost_of :: proc(samples: []f64) -> Cost {
	slice.sort(samples)
	return Cost{median = samples[len(samples) / 2], mean = slice.reduce(samples, 0.0, proc(a, b: f64) -> f64 { return a + b }) / f64(len(samples))}
}

/*
What each call costs per chunk of 256 KiB and 64 KiB: evicting a fully
resident chunk of the file mapping, then faulting it back in from the page
cache by touching every page; and releasing a written chunk of anonymous
memory, then writing it again. Medians and means in µs over every chunk of
the file (1,024 or 256 of them) and 8 rounds over the anonymous region.
*/
@(private = "file")
platform_costs :: proc(t: ^testing.T) {
	f := test_file_create(t)
	defer test_file_destroy(&f)

	log.info("cost per chunk, µs (median / mean)")
	log.info("  chunk    call                 evict or release          refault or rewrite")
	for chunk in ([]int{256 << 10, 64 << 10}) {
		n := FILE_SIZE / chunk
		evict := make([]f64, n)
		refault := make([]f64, n)
		defer delete(evict)
		defer delete(refault)
		for m in Platform_Evict {
			base := file_map(t, f)
			touch(base, 0, FILE_SIZE)
			ok := true
			for i in 0 ..< n {
				start := time.tick_now()
				if !file_evict(m, f, base, i * chunk, chunk) {
					ok = false
				}
				evict[i] = us(time.tick_since(start))
			}
			for i in 0 ..< n {
				start := time.tick_now()
				touch(base, i * chunk, chunk)
				refault[i] = us(time.tick_since(start))
			}
			posix.munmap(base, FILE_SIZE)
			if !ok {
				log.info(fmt.tprintf("  %3s KiB  file %-15v  not supported", fmt.tprint(chunk >> 10), m))
				continue
			}
			e, r := cost_of(evict), cost_of(refault)
			log.info(fmt.tprintf("  %3s KiB  file %-15v  %8s / %8s       %8s / %8s", fmt.tprint(chunk >> 10), m, f2(e.median), f2(e.mean), f2(r.median), f2(r.mean)))
		}

		rounds :: 8
		k := ANON_SIZE / chunk
		release := make([]f64, k * rounds)
		rewrite := make([]f64, k * rounds)
		defer delete(release)
		defer delete(rewrite)
		for m in Platform_Release {
			p := posix.mmap(nil, ANON_SIZE, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, -1, 0)
			testing.expect(t, p != posix.MAP_FAILED, "mmap failed")
			base := ([^]byte)(p)
			ok := true
			for round in 0 ..< rounds {
				dirty(base, 0, ANON_SIZE)
				for i in 0 ..< k {
					start := time.tick_now()
					if !anon_release(m, base, i * chunk, chunk) {
						ok = false
					}
					release[round * k + i] = us(time.tick_since(start))
				}
				for i in 0 ..< k {
					start := time.tick_now()
					anon_reuse(m, base, i * chunk, chunk)
					dirty(base, i * chunk, chunk)
					rewrite[round * k + i] = us(time.tick_since(start))
				}
			}
			posix.munmap(base, ANON_SIZE)
			if !ok {
				log.info(fmt.tprintf("  %3s KiB  anon %-15v  not supported", fmt.tprint(chunk >> 10), m))
				continue
			}
			rl, rw := cost_of(release), cost_of(rewrite)
			log.info(fmt.tprintf("  %3s KiB  anon %-15v  %8s / %8s       %8s / %8s", fmt.tprint(chunk >> 10), m, f2(rl.median), f2(rl.mean), f2(rw.median), f2(rw.mean)))
		}
	}
}

@(private = "file")
Load_Reader :: struct {
	base:  [^]byte,
	stop:  ^bool,
	seed:  u64,
	// Results, read after the thread is joined.
	reads: int,
	wrong: int,
}

// Reads random words of the mapping and checks them against the file.
@(private = "file")
load_reader_run :: proc(r: ^Load_Reader) {
	gen := rand.create_u64(r.seed)
	context.random_generator = rand.default_random_generator(&gen)
	for !sync.atomic_load(r.stop) {
		for _ in 0 ..< 1024 {
			off := rand.int_max(FILE_SIZE / 8) * 8
			if intrinsics.volatile_load((^u64)(&r.base[off])) != word_at(off) {
				r.wrong += 1
			}
			r.reads += 1
		}
	}
}

/*
Eviction under load: four reader threads read random words of the mapping
and check them while this thread evicts random 256 KiB chunks as fast as it
can, for KV_PLATFORM_SECONDS per method. A fault would end the process; a
wrong byte or a failed call is counted.
*/
@(private = "file")
platform_remap_under_load :: proc(t: ^testing.T) {
	f := test_file_create(t)
	defer test_file_destroy(&f)
	CHUNK :: 256 << 10
	READERS :: 4

	for m in ([]Platform_Evict{.Remap, .Dontneed}) {
		base := file_map(t, f)
		defer posix.munmap(base, FILE_SIZE)
		stop := false
		readers: [READERS]Load_Reader
		threads: [READERS]^thread.Thread
		for &r, i in readers {
			r = Load_Reader{base = base, stop = &stop, seed = u64(i) + 1}
			threads[i] = thread.create_and_start_with_poly_data(&r, load_reader_run)
		}

		evictions, failures := 0, 0
		deadline := time.tick_now()
		for time.tick_diff(deadline, time.tick_now()) < PLATFORM_SECONDS * time.Second {
			off := rand.int_max(FILE_SIZE / CHUNK) * CHUNK
			if file_evict(m, f, base, off, CHUNK) {
				evictions += 1
			} else {
				failures += 1
			}
		}
		sync.atomic_store(&stop, true)
		reads, wrong := 0, 0
		for th, i in threads {
			thread.join(th)
			thread.destroy(th)
			reads += readers[i].reads
			wrong += readers[i].wrong
		}
		log.infof("%v under load, %d s, %d readers: %d evictions, %d failed calls, %d reads, %d wrong",
			m, PLATFORM_SECONDS, READERS, evictions, failures, reads, wrong)
		testing.expect_value(t, failures, 0)
		testing.expect_value(t, wrong, 0)
	}
}
