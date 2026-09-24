package kv

import "base:intrinsics"
import "core:sync"

/*
Chunk accounting (KV-I-0004 D7): the store's own estimate of how much of
the map is resident in the process, kept on every read of a mapped page,
and eviction to keep it within Options.mapped_budget (D8, D9).

The map is divided into aligned chunks of `size` bytes, a power of two of at
least MIN_CHUNK_SIZE, and the map's size is a whole number of chunks. Each
chunk has one byte in `bits`, holding two flags, updated atomically:

- CHUNK_RESIDENT: some page of the chunk was read through the map since the
  chunk was last evicted, so its pages are (estimated to be) mapped into the
  process. `resident` counts the chunks with this flag set.
- CHUNK_REFERENCED: read since the last sweep looked at it; the CLOCK bit
  eviction clears, sparing the chunk once.

page_ptr marks the chunk of every page it returns from the map, and
overflow_value and freelist_load every chunk of the runs they return or
read. A page in the dirty-page pool isn't in the map, so reading it counts
nothing. A chunk becomes resident only through those reads, so a chunk
past the end of the file never does, and eviction never looks past `end`.

The fast path is one atomic load, and no write when both flags are already
set, so reader threads sharing a hot chunk don't take its cache line from
each other. The rest is out of line (chunk_mark): it sets
CHUNK_REFERENCED if it is clear, and sets CHUNK_RESIDENT with a CAS, so
that of several threads reading a chunk at once exactly one counts it.

Eviction (chunks_evict) runs CLOCK under `evict_mutex`, which only
eviction takes: with try_lock at the end of a transaction and in env_sweep,
and waiting for it inline at the hard watermark. A read below the hard
watermark never takes it. Invariant: no code holding evict_mutex reaches
page_ptr (or chunk_touch, chunks_touch_range), since a mark there can wait
for evict_mutex and the thread would wait on itself. Eviction reads no page.
Only eviction clears CHUNK_RESIDENT, and it does so with a CAS before it
evicts the range, so a reader racing it can only leave the estimate too
high: either its read changed the byte and the chunk is spared, or its read
comes after the clear and marks the chunk resident again, whatever the
eviction then drops. Evicting keeps every address valid (os_evict), so
slices held across it stay valid and fault their pages back in.

The estimate is kept whether or not there is a budget; only eviction
depends on it. Pages faulted in through a slice held across an eviction
aren't seen until a later read marks their chunk (KV-I-0004 Q4).

Fields other than the flags, the counters, `end` and `hand` are set by
env_open and never change.
*/
Chunk_Table :: struct {
	// One byte per chunk: CHUNK_RESIDENT | CHUNK_REFERENCED. Atomic.
	bits:              [^]u8,
	count:             int,
	// Chunk size in bytes, and its log2: a byte offset in the map shifted
	// right by `shift` is its chunk.
	size:              int,
	shift:             uint,
	// Options.mapped_budget, in bytes; 0 means no budget.
	budget:            int,
	// The watermarks in chunks (D8), from the budget B = budget / size:
	// `limit` is B, `low` LOW_WATERMARK_EIGHTHS/8 of B and `high` B +
	// HARD_MARGIN_CHUNKS. Without a budget, `limit` and `high` are
	// max(int), so nothing is ever above them.
	limit:             int,
	low:               int,
	high:              int,
	// Chunks with CHUNK_RESIDENT set. Atomic.
	resident:          int,
	// One past the highest chunk ever made resident: eviction looks at no
	// chunk from here on, which covers everything past the end of the
	// file. Only grows. Atomic.
	end:               int,
	// Chunks that became resident, over the Env's lifetime: the estimate's
	// fault count. faults − evictions = resident. Atomic.
	faults:            int,
	// Chunks evicted, over the Env's lifetime; and the calls that evicted
	// any, by path: env_sweep, the end of a transaction, and inline at the
	// hard watermark. Atomic.
	evictions:         int,
	sweeps:            int,
	txn_end_evictions: int,
	inline_evictions:  int,
	// Taken by eviction only: guards `hand`. Nothing holding it may reach
	// page_ptr (see above).
	evict_mutex:       sync.Mutex,
	// The CLOCK hand: the next chunk eviction looks at, below `end`.
	hand:              int,
}

CHUNK_RESIDENT   :: u8(0x01)
CHUNK_REFERENCED :: u8(0x02)

/*
The watermarks (KV-I-0004 D8, amended): above the budget B, the end of a
transaction evicts down to the low watermark, LOW_WATERMARK_EIGHTHS/8 of B,
and so does a read that takes the estimate past the hard watermark, B +
HARD_MARGIN_CHUNKS. Evicting below B leaves room for the next few
transactions to fault chunks in without evicting again. Fixed for now; the
low watermark may become tunable or self-tuning.
*/
LOW_WATERMARK_EIGHTHS :: 7
HARD_MARGIN_CHUNKS :: 2

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
		limit  = max(int),
		high   = max(int),
	}
	if budget > 0 {
		b := budget >> shift
		chunks.limit = b
		chunks.low = b * LOW_WATERMARK_EIGHTHS / 8
		chunks.high = b + HARD_MARGIN_CHUNKS
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
			resident := sync.atomic_add_explicit(&chunks.resident, 1, .Relaxed) + 1
			sync.atomic_add_explicit(&chunks.faults, 1, .Relaxed)
			chunk_resident_added(env, i, resident)
			return
		}
		old = cur
	}
	if old & CHUNK_REFERENCED == 0 {
		sync.atomic_or_explicit(p, CHUNK_REFERENCED, .Relaxed)
	}
}

/*
Called by the thread that made chunk `i` resident, after counting it,
`resident` being the count its increment produced. Raises `end` past the
chunk, and above the hard watermark evicts inline, down to the low
watermark (KV-I-0004 D8): the backstop for one transaction that reads far
past the budget before it ends. Unlike every other eviction, this one waits
for evict_mutex if another thread holds it: a thread over the hard
watermark doesn't go on faulting chunks in while someone else evicts, which
is what keeps the estimate within about B + 2 plus one chunk per thread
under concurrency (with try_lock here it reached 2–4 times the budget;
KV-T-0023). Once it has the lock, it evicts whatever is still above the low
watermark. Since this runs inside page_ptr, no code holding evict_mutex may
reach page_ptr, or it waits on itself (see Chunk_Table).
*/
@(private)
chunk_resident_added :: proc(env: ^Env, i: int, resident: int) {
	chunks := &env.chunks
	end := sync.atomic_load_explicit(&chunks.end, .Relaxed)
	for i >= end {
		cur, won := sync.atomic_compare_exchange_weak_explicit(&chunks.end, end, i + 1, .Relaxed, .Relaxed)
		if won {
			break
		}
		end = cur
	}
	if resident > chunks.high {
		sync.mutex_lock(&chunks.evict_mutex)
		if chunks_evict(env, chunks.low) > 0 {
			sync.atomic_add_explicit(&chunks.inline_evictions, 1, .Relaxed)
		}
		sync.mutex_unlock(&chunks.evict_mutex)
	}
}

/*
Evicts chunks until the resident count is at most `target` (in chunks), and
returns how many it evicted. It can do less when readers keep every chunk
referenced: the hand makes at most two turns, the first of which may only
clear CHUNK_REFERENCED flags. The caller holds evict_mutex.

CLOCK: a chunk the hand passes with CHUNK_REFERENCED set has the flag
cleared and survives; one without it has both flags cleared, by a CAS that
fails (and spares the chunk) if a reader marked it meanwhile, and is
uncounted, and only then evicted. Consecutive chunks are evicted with one
call.
*/
@(private)
chunks_evict :: proc(env: ^Env, target: int) -> (evicted: int) {
	chunks := &env.chunks
	end := sync.atomic_load_explicit(&chunks.end, .Relaxed)
	run_start, run_len := 0, 0
	for _ in 0 ..< 2 * end {
		if sync.atomic_load_explicit(&chunks.resident, .Relaxed) <= target {
			break
		}
		i := chunks.hand if chunks.hand < end else 0
		chunks.hand = i + 1
		p := &chunks.bits[i]
		old := sync.atomic_load_explicit(p, .Relaxed)
		if old & CHUNK_RESIDENT == 0 {
			continue
		}
		if old & CHUNK_REFERENCED != 0 {
			sync.atomic_and_explicit(p, ~CHUNK_REFERENCED, .Relaxed)
			continue
		}
		if _, won := sync.atomic_compare_exchange_strong_explicit(p, old, 0, .Relaxed, .Relaxed); !won {
			continue
		}
		sync.atomic_sub_explicit(&chunks.resident, 1, .Relaxed)
		if run_len > 0 && i != run_start + run_len {
			evicted += chunks_evict_run(env, run_start, run_len)
			run_len = 0
		}
		if run_len == 0 {
			run_start = i
		}
		run_len += 1
	}
	if run_len > 0 {
		evicted += chunks_evict_run(env, run_start, run_len)
	}
	return evicted
}

/*
Evicts `n` consecutive chunks from `start`, already cleared and uncounted,
and returns n. If the OS call fails (never seen: KV-T-0019), it puts them
back (chunks_restore) and returns 0.
*/
@(private = "file")
chunks_evict_run :: proc(env: ^Env, start, n: int) -> int {
	chunks := &env.chunks
	off, size := start << chunks.shift, n << chunks.shift
	if os_evict(env.fd, env.map_base[off:], off, size) != .None {
		chunks_restore(env, start, n)
		return 0
	}
	sync.atomic_add_explicit(&chunks.evictions, n, .Relaxed)
	return n
}

// After a failed eviction: counts the `n` chunks from `start` that no reader
// has marked since resident again, since their pages may still be mapped.
// faults − evictions = resident still holds.
@(private = "file")
chunks_restore :: proc(env: ^Env, start, n: int) {
	chunks := &env.chunks
	for i in start ..< start + n {
		if _, won := sync.atomic_compare_exchange_strong_explicit(&chunks.bits[i], 0, CHUNK_RESIDENT, .Relaxed, .Relaxed); won {
			sync.atomic_add_explicit(&chunks.resident, 1, .Relaxed)
			sync.atomic_sub_explicit(&chunks.faults, 1, .Relaxed)
		}
	}
}

/*
Evicts every chunk below `end`, counted resident or not, with one call, and
returns the number that were counted: env_sweep's target 0. The uncounted
ones matter here: pages read through slices held across an earlier
eviction (Q4) are mapped but not flagged, CLOCK never evicts them, and the
sleep path must drop them too. Every flag is cleared (by the same CAS as in
chunks_evict) before the call. The caller holds evict_mutex.
*/
@(private)
chunks_evict_all :: proc(env: ^Env) -> (evicted: int) {
	chunks := &env.chunks
	end := sync.atomic_load_explicit(&chunks.end, .Relaxed)
	if end == 0 {
		return 0
	}
	for i in 0 ..< end {
		p := &chunks.bits[i]
		old := sync.atomic_load_explicit(p, .Relaxed)
		for old != 0 {
			cur, won := sync.atomic_compare_exchange_weak_explicit(p, old, 0, .Relaxed, .Relaxed)
			if won {
				if old & CHUNK_RESIDENT != 0 {
					sync.atomic_sub_explicit(&chunks.resident, 1, .Relaxed)
					evicted += 1
				}
				break
			}
			old = cur
		}
	}
	chunks.hand = 0
	size := end << chunks.shift
	if os_evict(env.fd, env.map_base, 0, size) != .None {
		chunks_restore(env, 0, end)
		return 0
	}
	sync.atomic_add_explicit(&chunks.evictions, evicted, .Relaxed)
	return evicted
}

/*
Called at the end of every transaction, once it has released the reader
table and the writer mutex: above the budget, evicts down to the low
watermark (KV-I-0004 D8, amended). This is what keeps a store in use within
its budget. Within it, or without a budget, it is one atomic load. If
another thread is evicting already, it doesn't wait. Nothing a transaction
still open holds is invalidated.
*/
@(private)
chunks_txn_end :: #force_inline proc(env: ^Env) {
	chunks := &env.chunks
	if sync.atomic_load_explicit(&chunks.resident, .Relaxed) > chunks.limit {
		chunks_txn_end_evict(env)
	}
}

@(private = "file")
chunks_txn_end_evict :: #force_no_inline proc(env: ^Env) {
	chunks := &env.chunks
	if !sync.mutex_try_lock(&chunks.evict_mutex) {
		return
	}
	if chunks_evict(env, chunks.low) > 0 {
		sync.atomic_add_explicit(&chunks.txn_end_evictions, 1, .Relaxed)
	}
	sync.mutex_unlock(&chunks.evict_mutex)
}

/*
Evicts mapped pages, and returns the number of chunks evicted (KV-I-0004
D9). The store needs no call to stay within its budget: the end of every
transaction evicts down to the low watermark when the estimate is above
Options.mapped_budget, and a read that takes it past the hard watermark
(the budget plus HARD_MARGIN_CHUNKS) evicts inline, for a transaction that
reads far past the budget before it ends (D8). The store starts no thread.

Target 0 is the sleep path: an application calls env_sweep(env, 0) when the
store has been idle for a long time (hours without a request, say), and
every mapped page leaves the process while the Env stays open, including
pages read through slices held across an earlier eviction, which the
estimate never counted. What remains is the Env, its chunk table, the
reader table and the free list. Unlike env_close it needs no reopen: the
next request just reads, faulting in what it needs. Any `target` ≥ 0, in
bytes, evicts until at most that much is resident, budget or not.

The default `target` does what the end of a transaction does, and no
application needs it: nothing (one atomic load) while the estimate is at
or below the budget, or when there is no budget, and above it eviction down
to the low watermark.

Chunks read since the hand last passed them are spared once (CLOCK), so a
partial eviction keeps what is in use. Evicting never invalidates
anything: every slice returned by get, a cursor or overflow_value stays
valid and unchanged, and its pages are read back in from the page cache
when next touched (Q4: those aren't counted until a later read marks their
chunk).

Safe to call from any thread, with or without a transaction open, and while
other threads read and write. If another call, or another eviction, is
under way, it returns 0 at once rather than waiting.
*/
env_sweep :: proc(env: ^Env, target := -1) -> (evicted: int) {
	chunks := &env.chunks
	goal: int
	if target < 0 {
		if sync.atomic_load_explicit(&chunks.resident, .Relaxed) <= chunks.limit {
			return 0
		}
		goal = chunks.low
	} else {
		goal = target >> chunks.shift
	}
	if !sync.mutex_try_lock(&chunks.evict_mutex) {
		return 0
	}
	evicted = chunks_evict_all(env) if goal == 0 else chunks_evict(env, goal)
	sync.mutex_unlock(&chunks.evict_mutex)
	if evicted > 0 {
		sync.atomic_add_explicit(&chunks.sweeps, 1, .Relaxed)
	}
	return evicted
}
