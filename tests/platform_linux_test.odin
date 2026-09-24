#+build linux
package kv_tests

import "core:c"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// The Linux side of platform_test.odin (KV-T-0019). See madvise(2); -1 for
// advice Linux doesn't have.
MADV_RANDOM :: 1
MADV_DONTNEED :: 4
MADV_FREE :: 8
MADV_PAGEOUT :: 21
MADV_FREE_REUSABLE :: -1
MADV_FREE_REUSE :: -1

// Reads a /proc file, whose size stat doesn't report, into temporary memory.
@(private = "file")
read_proc :: proc(path: cstring) -> string {
	fd := posix.open(path, {.CLOEXEC})
	if fd == -1 {
		return ""
	}
	defer posix.close(fd)
	buf := make([dynamic]byte, 0, 64 << 10, context.temp_allocator)
	chunk: [16 << 10]byte
	for {
		n := posix.read(fd, &chunk[0], len(chunk))
		if n <= 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}
	return string(buf[:])
}

// The value of a "Name:   123 kB" line, in bytes.
@(private = "file")
kb_field :: proc(line: string) -> int {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	v, _ := strconv.parse_int(fields[1])
	return v << 10
}

// The Rss of the mappings in /proc/self/smaps that start in the range.
@(private = "file")
smaps_rss :: proc(base: [^]byte, size: int) -> int {
	lo, hi := uintptr(base), uintptr(base) + uintptr(size)
	text := read_proc("/proc/self/smaps")
	inside := false
	total := 0
	for line in strings.split_lines_iterator(&text) {
		dash := strings.index_byte(line, '-')
		space := strings.index_byte(line, ' ')
		if dash > 0 && space > dash {
			if start, ok := strconv.parse_uint(line[:dash], 16); ok {
				inside = uintptr(start) >= lo && uintptr(start) < hi
				continue
			}
		}
		if inside && strings.has_prefix(line, "Rss:") {
			total += kb_field(line)
		}
	}
	return total
}

// Pages of the range whose /proc/self/pagemap entry has the present bit
// (bit 63). Unprivileged processes see the bit, with the frame number zeroed.
@(private = "file")
pagemap_present :: proc(base: [^]byte, size: int) -> int {
	ps := int(posix.sysconf(._PAGESIZE))
	fd := posix.open("/proc/self/pagemap", {.CLOEXEC})
	if fd == -1 {
		return -1
	}
	defer posix.close(fd)
	entries := make([]u64, size / ps, context.temp_allocator)
	want := len(entries) * 8
	n := posix.pread(fd, ([^]u8)(raw_data(entries)), c.size_t(want), posix.off_t(int(uintptr(base)) / ps * 8))
	if n != want {
		return -1
	}
	present := 0
	for e in entries {
		if e >> 63 != 0 {
			present += ps
		}
	}
	return present
}

// The figures for the range, and the process-wide ones. With a nil `base`,
// only the process-wide ones.
platform_residency :: proc(base: [^]byte, size: int) -> (r: Platform_Residency) {
	r = Platform_Residency{mincore = -1, present = -1, region = -1}
	ps := int(posix.sysconf(._PAGESIZE))
	if base != nil {
		vec := make([]u8, size / ps, context.temp_allocator)
		if mincore(base, c.size_t(size), raw_data(vec)) == 0 {
			r.mincore = 0
			for v in vec {
				if v & 1 != 0 {
					r.mincore += ps
				}
			}
		}
		r.present = pagemap_present(base, size)
		r.region = smaps_rss(base, size)
	}
	statm := read_proc("/proc/self/statm")
	fields := strings.fields(statm, context.temp_allocator)
	if len(fields) >= 2 {
		pages, _ := strconv.parse_int(fields[1])
		r.rss = pages * ps
	}
	status := read_proc("/proc/self/status")
	for line in strings.split_lines_iterator(&status) {
		if strings.has_prefix(line, "RssAnon:") {
			r.footprint = kb_field(line)
		}
	}
	return r
}

// How long the platform's own sources take over the range.
platform_source_costs :: proc(base: [^]byte, size: int) {
	start := time.tick_now()
	for _ in 0 ..< 10 {
		pagemap_present(base, size)
	}
	log.infof("pagemap over the range: %.1f µs per call", time.duration_microseconds(time.tick_since(start)) / 10)
	start = time.tick_now()
	for _ in 0 ..< 10 {
		smaps_rss(base, size)
	}
	log.infof("smaps over the process: %.1f µs per call", time.duration_microseconds(time.tick_since(start)) / 10)
	start = time.tick_now()
	for _ in 0 ..< 10 {
		read_proc("/proc/self/statm")
	}
	log.infof("statm: %.1f µs per call", time.duration_microseconds(time.tick_since(start)) / 10)
}
