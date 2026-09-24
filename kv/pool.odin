package kv

import "core:mem"
import "core:slice"
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

Write_State.dirty maps a page number to its slots. A run of pages allocated
together takes consecutive slots, so the pool hands out contiguous ranges,
always the lowest free one: that keeps the committed slots together, and
released in few calls. Overflow values and the free-list run don't go
through the pool as whole runs (KV-I-0004 D5, D6): they are written to the
file a page, or the caller's buffer, at a time.

The pool is a hard limit that callers never hit: when it runs short, put
and del spill the least recently touched dirty pages to their final places
in the file before they change anything (pool_make_room, KV-I-0004 D2–D4).

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
	// Room for every dirty page, for choosing and ordering a spill.
	spill_list:      []Spill_Entry,
	// Slots in use, and bytes committed. Stored atomically by the writer.
	in_use:          int,
	committed_bytes: int,
	// Pages spilled, over the Env's lifetime. Added to atomically by the
	// writer.
	spills:          int,
}

// A dirty page (or run) considered for spilling: its page number, first
// slot, length, and how many changes ago it was last touched.
@(private)
Spill_Entry :: struct {
	pgno:  Pgno,
	slot:  u32,
	pages: u32,
	age:   u32,
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
	spill_list, spill_err := make([]Spill_Entry, slots, allocator)
	if used_err != nil || committed_err != nil || touched_err != nil || spill_err != nil {
		delete(used, allocator)
		delete(committed, allocator)
		delete(touched, allocator)
		delete(spill_list, allocator)
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
		spill_list    = spill_list,
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
	delete(pool.spill_list, allocator)
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

// Returns the first slot of the lowest run of `n` free slots. The scan is
// linear over a bitmap of a few hundred to a few thousand bits, a word at a
// time where the word is full.
@(private = "file")
pool_find :: proc(pool: ^Dirty_Pool, n: int) -> (slot: int, ok: bool) {
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

/*
Makes sure at least `n` slots of the pool are free, spilling dirty pages if
they aren't (KV-I-0004 D2). Called only between operations: at the start of
put and del, before they change anything, and by txn_commit. Never inside
an operation, which holds slices into its dirty pages across page_alloc
(insert_node holds the page it is splitting): spilling there would free
slots still in use. The least recently touched pages are rarely the
operation's own, but nothing guarantees it, so the rule is kept outright,
and asserted (Write_State.in_op).

`n` is at most MIN_DIRTY_PAGES, which every pool has. Returns Io if growing
the file or writing fails; the transaction is consistent then (see spill)
and can go on.
*/
@(private)
pool_make_room :: proc(txn: ^Txn, n: int) -> Error {
	pool := &txn.env.pool
	assert(!txn.write.in_op, "spilling inside an operation (KV-I-0004 D2)")
	assert(n <= pool.slots, "an operation needs more slots than the pool has")
	free := pool.slots - pool.in_use
	if free >= n {
		return .None
	}
	// A quarter of the pool at a time, so that spills are rare and write
	// many pages at once (D3).
	return spill(txn, max(n - free, pool.slots / 4))
}

/*
Writes the least recently touched dirty pages, at least `want` slots' worth,
to their places in the file, and frees their slots (KV-I-0004 D3, D4). Each
slot's `touched` stamp is the transaction's `mods` at its last allocation or
touch, so its age is the number of changes since. Branch pages are touched
by every change below them, so they are the last to go.

The pages are written in page order, adjacent ones in one call, and move
from Write_State.dirty to Write_State.spilled. They stay the transaction's
pages: reads go through the map, which pwrite keeps coherent, page_touch
copies one back into a slot under the same page number, and page_free puts
one on `loose`. Commit syncs the file once, which covers them.

Returns Io if growing the file or a write fails. The pages written before
that are spilled and the rest stay dirty, so the transaction is consistent.
*/
@(private = "file")
spill :: proc(txn: ^Txn, want: int) -> Error {
	env, w, pool := txn.env, txn.write, &txn.env.pool
	ps := i64(env.page_size)

	list := pool.spill_list[:len(w.dirty)]
	i := 0
	for pgno, d in w.dirty {
		list[i] = {pgno = pgno, slot = d.slot, pages = d.pages, age = txn.mods - pool.touched[d.slot]}
		i += 1
	}
	// Oldest first, and in page order among equals, so that a spill is
	// deterministic.
	slice.sort_by(list, proc(a, b: Spill_Entry) -> bool {
		return a.age > b.age || (a.age == b.age && a.pgno < b.pgno)
	})
	count, freed := 0, 0
	for count < len(list) && freed < want {
		freed += int(list[count].pages)
		count += 1
	}
	assert(count > 0, "nothing to spill")
	batch := list[:count]
	slice.sort_by(batch, proc(a, b: Spill_Entry) -> bool {
		return a.pgno < b.pgno
	})

	// Writing these pages before the commit is safe, and needs no format
	// change: every page a write transaction allocates, loose, reused or new
	// at the end of the file, is in no snapshot anyone can read. A reused
	// page was freed by a transaction at or below the reuse horizon, so
	// neither a live reader nor the snapshot before the one this
	// transaction began from (whose meta page the next commit overwrites)
	// uses it (KV-I-0002 D1); a new page is past every snapshot's last
	// page. No meta page points at a spilled page until the commit does,
	// after its sync, so a crash or an abort leaves only unreferenced bytes
	// in free pages. Step 7's crash tests rely on this.
	last := batch[count - 1]
	file_grow(env, (i64(last.pgno) + i64(last.pages)) * ps) or_return
	for start := 0; start < count; {
		// Adjacent pages in adjacent slots are one write.
		end, pages := start + 1, batch[start].pages
		for end < count && batch[end].pgno == batch[start].pgno + Pgno(pages) && batch[end].slot == batch[start].slot + pages {
			pages += batch[end].pages
			end += 1
		}
		os_pwrite(env.fd, pool_pages(pool, batch[start].slot, pages), i64(batch[start].pgno) * ps) or_return
		for e in batch[start:end] {
			pool_free(pool, e.slot, e.pages)
			delete_key(&w.dirty, e.pgno)
			w.spilled[e.pgno] = e.pages
		}
		sync.atomic_add(&pool.spills, int(pages))
		start = end
	}
	return .None
}
