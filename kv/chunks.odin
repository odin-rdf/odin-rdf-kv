package kv

import "base:intrinsics"
import "core:sync"

/*
Chunk accounting (KV-I-0004 D7): the store's own estimate of how much of
the map is resident in the process, kept on every read of a mapped page.

The map is divided into aligned chunks of `size` bytes, a power of two of at
least MIN_CHUNK_SIZE, and the map's size is a whole number of chunks. Each
chunk has one byte in `bits`, holding two flags, updated atomically:

- CHUNK_RESIDENT: some page of the chunk was read through the map since the
  chunk was last evicted, so its pages are (estimated to be) mapped into the
  process. `resident` counts the chunks with this flag set.
- CHUNK_REFERENCED: read since the last sweep looked at it; the CLOCK bit
  eviction (KV-T-0023) clears, sparing the chunk once.

page_ptr marks the chunk of every page it returns from the map, and
overflow_value and freelist_load every chunk of the runs they return or
read. A page in the dirty-page pool isn't in the map, so reading it counts
nothing. A chunk becomes resident only through those reads, so a chunk
past the end of the file never does.

The fast path is one atomic load, and no write when both flags are already
set, so reader threads sharing a hot chunk don't take its cache line from
each other. The rest is out of line (chunk_mark): it sets
CHUNK_REFERENCED if it is clear, and sets CHUNK_RESIDENT with a CAS, so
that of several threads reading a chunk at once exactly one counts it.

The estimate is kept whether or not there is a budget; only eviction
(KV-T-0023) depends on `budget`. Pages faulted in through a slice held
across an eviction aren't seen until a later read marks their chunk
(KV-I-0004 Q4).

Fields other than the flags and the counters are set by env_open and never
change.
*/
Chunk_Table :: struct {
	// One byte per chunk: CHUNK_RESIDENT | CHUNK_REFERENCED. Atomic.
	bits:     [^]u8,
	count:    int,
	// Chunk size in bytes, and its log2: a byte offset in the map shifted
	// right by `shift` is its chunk.
	size:     int,
	shift:    uint,
	// Options.mapped_budget, in bytes; 0 means no budget. Used by eviction
	// (KV-T-0023).
	budget:   int,
	// Chunks with CHUNK_RESIDENT set. Atomic.
	resident: int,
	// Chunks that became resident, over the Env's lifetime: the estimate's
	// fault count. Equal to `resident` until something is evicted. Atomic.
	faults:   int,
}

CHUNK_RESIDENT   :: u8(0x01)
CHUNK_REFERENCED :: u8(0x02)

// The chunk size when `Options.chunk_size` is 0.
DEFAULT_CHUNK_SIZE :: 256 * 1024

/*
The smallest chunk size. Linux maps 64 KiB, aligned, per fault of a file
mapping (fault-around, measured in KV-T-0019), so a smaller chunk would see
pages become resident that no read of it caused. It is also at least every
valid page size, so a page never spans two chunks, and at least the OS page
size on every supported platform.
*/
MIN_CHUNK_SIZE :: 64 * 1024

#assert(MIN_CHUNK_SIZE >= MAX_PAGE_SIZE)

/*
Compiled out only to measure what accounting costs (KV-I-0004 NFR-002):
`-define:KV_NO_CHUNK_ACCOUNTING=true`. Nothing else is meant to build
without it; the estimate then stays at 0.
*/
CHUNK_ACCOUNTING :: !#config(KV_NO_CHUNK_ACCOUNTING, false)

chunk_size_valid :: proc "contextless" (chunk_size: int) -> bool {
	return chunk_size >= MIN_CHUNK_SIZE && chunk_size & (chunk_size - 1) == 0
}

/*
Allocates the table for a map of `map_size` bytes, a multiple of
`chunk_size`, which is valid (chunk_size_valid). Returns Out_Of_Memory if
the table can't be allocated. One byte per chunk: 4 KiB for a 1 GiB map of
256 KiB chunks.
*/
@(private)
chunks_init :: proc(chunks: ^Chunk_Table, map_size, chunk_size, budget: int, allocator := context.allocator) -> Error {
	assert(chunk_size_valid(chunk_size) && map_size % chunk_size == 0)
	count := map_size / chunk_size
	bits, alloc_err := make([]u8, count, allocator)
	if alloc_err != nil {
		return .Out_Of_Memory
	}
	shift: uint
	for 1 << shift < chunk_size {
		shift += 1
	}
	chunks^ = Chunk_Table {
		bits   = raw_data(bits),
		count  = count,
		size   = chunk_size,
		shift  = shift,
		budget = budget,
	}
	return .None
}

@(private)
chunks_destroy :: proc(chunks: ^Chunk_Table, allocator := context.allocator) {
	delete(chunks.bits[:chunks.count], allocator)
	chunks^ = {}
}

/*
Marks the chunk holding byte `off` of the map as read. The fast path of
page_ptr: a shift and an atomic load, and nothing else when the chunk is
already resident and referenced.
*/
@(private)
chunk_touch :: #force_inline proc(env: ^Env, off: int) {
	when CHUNK_ACCOUNTING {
		// Masked so that the compiler can drop Odin's check for a shift of
		// 64 or more.
		i := off >> (env.chunks.shift & 63)
		if intrinsics.expect(sync.atomic_load_explicit(&env.chunks.bits[i], .Relaxed) != CHUNK_RESIDENT | CHUNK_REFERENCED, false) {
			chunk_mark(env, i)
		}
	}
}

// Marks every chunk of the `n` bytes of the map from `off` (n > 0) as read:
// an overflow value, or the free-list run.
@(private)
chunks_touch_range :: proc(env: ^Env, off, n: int) {
	when CHUNK_ACCOUNTING {
		for i in off >> env.chunks.shift ..= (off + n - 1) >> env.chunks.shift {
			if sync.atomic_load_explicit(&env.chunks.bits[i], .Relaxed) != CHUNK_RESIDENT | CHUNK_REFERENCED {
				chunk_mark(env, i)
			}
		}
	}
}

/*
The slow path of chunk_touch: sets whichever of chunk `i`'s flags is clear.
CHUNK_RESIDENT is set with a CAS (together with CHUNK_REFERENCED), so of
several threads finding it clear, exactly one counts the chunk and calls
chunk_resident_added.
*/
@(private)
chunk_mark :: #force_no_inline proc(env: ^Env, i: int) {
	chunks := &env.chunks
	p := &chunks.bits[i]
	old := sync.atomic_load_explicit(p, .Relaxed)
	for old & CHUNK_RESIDENT == 0 {
		cur, won := sync.atomic_compare_exchange_weak_explicit(p, old, old | CHUNK_RESIDENT | CHUNK_REFERENCED, .Relaxed, .Relaxed)
		if won {
			sync.atomic_add_explicit(&chunks.resident, 1, .Relaxed)
			sync.atomic_add_explicit(&chunks.faults, 1, .Relaxed)
			chunk_resident_added(env)
			return
		}
		old = cur
	}
	if old & CHUNK_REFERENCED == 0 {
		sync.atomic_or_explicit(p, CHUNK_REFERENCED, .Relaxed)
	}
}

/*
Called by the thread that made a chunk resident, after counting it: where
the resident count is checked against the hard watermark, and evicted
inline above it (KV-I-0004 D8, KV-T-0023). Nothing yet.
*/
@(private)
chunk_resident_added :: #force_no_inline proc(env: ^Env) {
}
