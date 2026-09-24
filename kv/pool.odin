package kv

import "core:mem"
import "core:sync"

/*
The dirty-page pool (KV-I-0004 D1): the memory a write transaction's dirty
pages live in, fixed when the Env is opened. It is `slots` page-sized slots
of address space, reserved once by env_open and released by env_close.

A slot is committed (made usable, backed by memory) when first used, and
every committed slot is released when the write transaction ends, with a
call that drops its pages from the process at once: an idle store holds no
dirty memory. Commit and release work on granules, the larger of the page
size and the OS page size, since the OS can't protect less; with 4 KiB
pages on macOS (16 KiB OS pages) a granule is four slots.

Write_State.dirty maps a page number to its slots. A run (an overflow value
or the free-list run) takes consecutive slots, so the pool hands out
contiguous ranges, always the lowest free one: that keeps the committed
slots together, and released in few calls.

A transaction needing more slots than are free gets Out_Of_Memory: put and
del check up front, like they do for Map_Full. Spilling (KV-T-0021) makes
the limit invisible instead.

The pool is only used with writer_mutex held. `in_use` and
`committed_bytes` are also read by env_stats, from any thread, so the
writer stores them atomically.
*/
Dirty_Pool :: struct {
	base:            [^]byte,
	// Bytes of address space reserved: `granules` whole granules.
	reserved:        int,
	slots:           int,
	page_size:       int,
	// Slots per granule, a power of two.
	granule_slots:   int,
	granules:        int,
	// One bit per slot: in use by the current write transaction.
	used:            []u64,
	// One bit per granule: committed since the last release.
	committed:       []u64,
	// Per slot: the transaction's `mods` when the slot was last allocated or
	// touched, for choosing what to spill (KV-I-0004 D3).
	touched:         []u32,
	// Slots in use, and bytes committed. Stored atomically by the writer.
	in_use:          int,
	committed_bytes: int,
}

// A dirty page, or a run of them: its first slot and length in pages.
Dirty_Page :: struct {
	slot:  u32,
	pages: u32,
}

// The dirty-page pool's size when `Options.dirty_budget` is 0.
DEFAULT_DIRTY_BUDGET :: 4 << 20

// The smallest pool, in pages: the worst case of one put (copying a path of
// MAX_DEPTH pages, then splitting every level and adding a root), so that
// once spilling exists every operation fits.
MIN_DIRTY_PAGES :: 2 * MAX_DEPTH + 1

/*
Reserves a pool of `budget` bytes, rounded up to whole pages, for a
database with pages of `page_size`. Returns Invalid_Argument if that is
fewer than MIN_DIRTY_PAGES pages, and Out_Of_Memory if the address space or
the pool's bookkeeping can't be allocated.
*/
@(private)
pool_init :: proc(pool: ^Dirty_Pool, budget: int, page_size: int, allocator := context.allocator) -> (err: Error) {
	if budget < 0 {
		return .Invalid_Argument
	}
	slots := (budget + page_size - 1) / page_size
	if slots < MIN_DIRTY_PAGES || slots > int(max(u32)) {
		return .Invalid_Argument
	}
	granule_slots := max(1, os_page_size() / page_size)
	granules := (slots + granule_slots - 1) / granule_slots
	reserved := granules * granule_slots * page_size

	base := os_pool_reserve(reserved) or_return
	defer if err != .None {
		os_unmap(base, reserved)
	}
	used, used_err := make([]u64, (slots + 63) / 64, allocator)
	committed, committed_err := make([]u64, (granules + 63) / 64, allocator)
	touched, touched_err := make([]u32, slots, allocator)
	if used_err != nil || committed_err != nil || touched_err != nil {
		delete(used, allocator)
		delete(committed, allocator)
		delete(touched, allocator)
		return .Out_Of_Memory
	}
	pool^ = Dirty_Pool {
		base          = base,
		reserved      = reserved,
		slots         = slots,
		page_size     = page_size,
		granule_slots = granule_slots,
		granules      = granules,
		used          = used,
		committed     = committed,
		touched       = touched,
	}
	return .None
}

// Unmaps the pool and frees its bookkeeping. No write transaction may be
// open.
@(private)
pool_destroy :: proc(pool: ^Dirty_Pool, allocator := context.allocator) {
	if pool.base != nil {
		os_unmap(pool.base, pool.reserved)
	}
	delete(pool.used, allocator)
	delete(pool.committed, allocator)
	delete(pool.touched, allocator)
	pool^ = {}
}

// The `n` pages of the pool from slot `slot`.
@(private)
pool_pages :: #force_inline proc "contextless" (pool: ^Dirty_Pool, slot: u32, n: u32) -> []byte {
	off := int(slot) * pool.page_size
	return pool.base[off:off + int(n) * pool.page_size]
}

/*
Takes the lowest run of `n` free slots, commits whatever of it isn't
committed yet, and stamps it with `stamp`. Returns Out_Of_Memory if no run
of `n` is free, or if committing fails; nothing changes then.
*/
@(private)
pool_alloc :: proc(pool: ^Dirty_Pool, n: int, stamp: u32) -> (slot: u32, err: Error) {
	first, found := pool_find(pool, n)
	if !found {
		return 0, .Out_Of_Memory
	}
	pool_commit(pool, first, n) or_return
	for i in first ..< first + n {
		pool.used[i / 64] |= 1 << uint(i % 64)
		pool.touched[i] = stamp
	}
	sync.atomic_store(&pool.in_use, pool.in_use + n)
	return u32(first), .None
}

// Returns the `n` slots from `slot` to the pool. They stay committed, for
// the transaction to reuse, until pool_release.
@(private)
pool_free :: proc(pool: ^Dirty_Pool, slot: u32, n: u32) {
	for i in int(slot) ..< int(slot + n) {
		assert(bit_get(pool.used, i), "freeing a pool slot that isn't in use")
		pool.used[i / 64] &~= 1 << uint(i % 64)
	}
	sync.atomic_store(&pool.in_use, pool.in_use - int(n))
}

/*
Ends the write transaction's use of the pool: every slot becomes free, and
every committed granule is released, one call per contiguous range, so
that its memory leaves the process at once. A range whose release fails
stays committed (and keeps its contents), which only costs its memory until
the next transaction's release.
*/
@(private)
pool_release :: proc(pool: ^Dirty_Pool) {
	mem.zero_slice(pool.used)
	sync.atomic_store(&pool.in_use, 0)
	gbytes := pool.granule_slots * pool.page_size
	g := 0
	for g < pool.granules {
		if !bit_get(pool.committed, g) {
			g += 1
			continue
		}
		end := g + 1
		for end < pool.granules && bit_get(pool.committed, end) {
			end += 1
		}
		if os_pool_release(&pool.base[g * gbytes], (end - g) * gbytes) == .None {
			for i in g ..< end {
				pool.committed[i / 64] &~= 1 << uint(i % 64)
			}
			sync.atomic_store(&pool.committed_bytes, pool.committed_bytes - (end - g) * gbytes)
		}
		g = end
	}
}

/*
Whether `singles` single slots and, unless `run` is 0, one run of `run`
slots are sure to be free, whatever order they are allocated in. Single
slots take the lowest free ones, so the run must survive them: it is
searched for past the lowest `singles` free slots. The pool's counterpart
of pages_available.
*/
@(private)
pool_available :: proc(pool: ^Dirty_Pool, singles: int, run := 0) -> bool {
	if singles + run > pool.slots - pool.in_use {
		return false
	}
	if run == 0 {
		return true
	}
	_, found := pool_find(pool, run, skip = singles)
	return found
}

// Returns the first slot of the lowest run of `n` free slots, ignoring the
// lowest `skip` free slots. The scan is linear over a bitmap of a few
// hundred to a few thousand bits, a word at a time where the word is full.
@(private = "file")
pool_find :: proc(pool: ^Dirty_Pool, n: int, skip := 0) -> (slot: int, ok: bool) {
	skip := skip
	start, length := 0, 0
	i := 0
	for i < pool.slots {
		if i % 64 == 0 && pool.used[i / 64] == max(u64) {
			length = 0
			i += 64
			continue
		}
		if bit_get(pool.used, i) {
			length = 0
		} else if skip > 0 {
			skip -= 1
		} else {
			if length == 0 {
				start = i
			}
			length += 1
			if length == n {
				return start, true
			}
		}
		i += 1
	}
	return 0, false
}

// Commits every granule of slots [first, first + n) that isn't committed,
// one call per contiguous uncommitted range.
@(private = "file")
pool_commit :: proc(pool: ^Dirty_Pool, first, n: int) -> Error {
	gbytes := pool.granule_slots * pool.page_size
	g_end := (first + n - 1) / pool.granule_slots + 1
	g := first / pool.granule_slots
	for g < g_end {
		if bit_get(pool.committed, g) {
			g += 1
			continue
		}
		end := g + 1
		for end < g_end && !bit_get(pool.committed, end) {
			end += 1
		}
		os_pool_commit(&pool.base[g * gbytes], (end - g) * gbytes) or_return
		for i in g ..< end {
			pool.committed[i / 64] |= 1 << uint(i % 64)
		}
		sync.atomic_store(&pool.committed_bytes, pool.committed_bytes + (end - g) * gbytes)
		g = end
	}
	return .None
}

@(private = "file")
bit_get :: #force_inline proc "contextless" (bits: []u64, i: int) -> bool {
	return bits[i / 64] & (1 << uint(i % 64)) != 0
}
