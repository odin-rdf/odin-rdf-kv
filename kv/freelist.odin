package kv

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

/*
The free list records every page in the file that neither the tree nor the
free list itself uses, together with the transaction that freed it:

- tag 0: reusable. No snapshot a reader could hold still uses the page.
- tag T > 0: freed by the commit of transaction T. Snapshots older than T
  may still use the page.

Each commit writes the whole list to a new contiguous run, laid out like an
overflow run: a Page_Header with PAGE_FREELIST and overflow_count, then the
records from offset 16 across the run's pages, sorted by (txn_id, pgno). The
run may have one page more than its records need (FREELIST_RUN_SLACK), with
everything after the last record zeroed. The
meta page records the run's first page and the number of records, or 0 and
0 for an empty list. The run's own pages are not in the list it holds; the
next commit frees them, and lists them tagged with its own txn_id like any
other page of the previous snapshot.

In memory the committed list is an Env's Free_State: the tag-0 pages as a
sorted array, and the rest as records, the pages of earlier runs apart from
the others. A run is read by nothing but env_open, when it opens the
run's snapshot, and space_check on a transaction of that snapshot; no read
of the tree ever reaches it. So the pages of the run of snapshot T − 1
(tagged T) wait only for KV-I-0002 D1, which keeps the snapshot before the
latest one intact, and for readers of snapshot T − 1 itself, not for every
older reader. Were they held back like the tree's pages, a reader held
across many commits would pin every run written while it was open, each
run would list the pages of the one before it, and the list, with the
file, would grow by a run's worth of pages, a 256th of itself at 4 KiB
pages, with every commit: exponentially, however little the commits
wrote. On disk the run's pages are ordinary records, and env_open, which
has no readers to wait for, loads them with the rest.

A write transaction reuses pages freed by a transaction ≤ its horizon
(Write_State.oldest): at begin, those records move from `pending` to
`ready`, and page_alloc takes from `ready` without changing it. The commit
builds the next list without the pages taken, and places its own run in
reusable pages when it can.
*/

Free_Record :: struct {
	pgno:   u64le,
	txn_id: u64le,
}

#assert(size_of(Free_Record) == 16)
#assert(offset_of(Free_Record, pgno) == 0)
#assert(offset_of(Free_Record, txn_id) == 8)
// Records start right after the page header, so they are aligned in the map.
#assert(PAGE_HEADER_SIZE % align_of(Free_Record) == 0)

// The committed free list. Both arrays are allocated with the Env's
// allocator.
Free_State :: struct {
	// Pages that are reusable now, sorted.
	ready:   [dynamic]Pgno,
	// Pages still waiting for older snapshots to end, ordered by
	// (txn_id, pgno).
	pending: [dynamic]Free_Record,
	// Pages of free-list runs that commits since the Env was opened have
	// freed, waiting for D1 and for readers of the run's own snapshot (see
	// above), ordered by (txn_id, pgno). Not distinct from `pending` on
	// disk.
	runs:    [dynamic]Free_Record,
}

// The most pages a free-list run may have beyond what its records need. See
// freelist_place for why one is enough.
FREELIST_RUN_SLACK :: 1

// Number of pages a free-list run holding `count` records needs. The run
// itself may be up to FREELIST_RUN_SLACK pages longer.
freelist_run_pages :: proc "contextless" (page_size: int, count: int) -> int {
	return overflow_pages(page_size, count * size_of(Free_Record))
}

@(private)
free_state_count :: proc(state: Free_State) -> int {
	return len(state.ready) + len(state.pending) + len(state.runs)
}

@(private)
free_state_destroy :: proc(state: ^Free_State) {
	delete(state.ready)
	delete(state.pending)
	delete(state.runs)
	state^ = {}
}

@(private = "file")
record_less :: proc(a, b: Free_Record) -> bool {
	return a.txn_id < b.txn_id || (a.txn_id == b.txn_id && a.pgno < b.pgno)
}

/*
Returns the records of the free-list run of `snap`, as a slice into the map
at `base`, after checking the run's header: it lies within the snapshot,
records its own page number and PAGE_FREELIST, and has the pages its records
need, or FREELIST_RUN_SLACK more. The run was committed, so it is always read
from the map.

The records themselves are not checked here; see freelist_load.
*/
@(private)
freelist_run :: proc(base: [^]byte, page_size: int, snap: Snapshot) -> (records: []Free_Record, pages: int, ok: bool) {
	pgno, last := snap.freelist_pgno, snap.last_pgno
	// A run always holds at least one record, and every record is a
	// distinct page, which also bounds the run's size.
	if pgno < 2 || pgno > last || snap.freelist_count == 0 || snap.freelist_count > u64(last) {
		return nil, 0, false
	}
	count := int(snap.freelist_count)
	off := int(pgno) * page_size
	pages = run_header_check(base[off:off + page_size], pgno, last, PAGE_FREELIST, count * size_of(Free_Record), FREELIST_RUN_SLACK) or_return
	records = ([^]Free_Record)(&base[off + PAGE_HEADER_SIZE])[:count]
	return records, pages, true
}

/*
Loads and validates the free list of the snapshot being opened. There are
no readers yet, so every page freed before `snap` is reusable, and only
pages that `snap` itself freed stay pending: the snapshot before it is kept
intact (see KV-I-0002 D1).

Returns `Corrupted` if the list breaks any rule: a run header that doesn't
match, records out of order, tagged after `snap`, outside [2, last_pgno] or
inside the run itself, or the same page listed twice.

The run is read from `env`'s map, and its chunks are accounted as read. The
state is allocated with env.allocator.
*/
@(private)
freelist_load :: proc(env: ^Env, snap: Snapshot) -> (state: Free_State, err: Error) {
	allocator := env.allocator
	state.ready = make([dynamic]Pgno, allocator)
	state.pending = make([dynamic]Free_Record, allocator)
	state.runs = make([dynamic]Free_Record, allocator)
	defer if err != .None {
		free_state_destroy(&state)
	}
	if snap.freelist_pgno == 0 {
		return state, .None if snap.freelist_count == 0 else .Corrupted
	}
	records, run_pages, ok := freelist_run(env.map_base, env.page_size, snap)
	if !ok {
		return state, .Corrupted
	}
	chunks_touch_range(env, int(snap.freelist_pgno) * env.page_size, run_pages * env.page_size)

	run_end := snap.freelist_pgno + Pgno(run_pages)
	n_ready := 0
	for r, i in records {
		pgno, tag := Pgno(r.pgno), Txn_Id(r.txn_id)
		if tag > snap.txn_id || pgno < 2 || pgno > snap.last_pgno {
			return state, .Corrupted
		}
		if pgno >= snap.freelist_pgno && pgno < run_end {
			return state, .Corrupted
		}
		if i > 0 && !record_less(records[i - 1], r) {
			return state, .Corrupted
		}
		if tag < snap.txn_id {
			n_ready += 1
		}
	}

	if reserve(&state.ready, n_ready) != nil || reserve(&state.pending, len(records) - n_ready) != nil {
		return state, .Out_Of_Memory
	}
	// Records are sorted by tag, so the pending ones (tagged `snap`) are
	// the last ones.
	for r in records[:n_ready] {
		append(&state.ready, Pgno(r.pgno))
	}
	append(&state.pending, ..records[n_ready:])

	// Pages are unique within a tag, so a page listed twice shows up as
	// neighbours in `ready`, or in both `ready` and `pending`.
	slice.sort(state.ready[:])
	for i in 1 ..< len(state.ready) {
		if state.ready[i - 1] == state.ready[i] {
			return state, .Corrupted
		}
	}
	for r in state.pending {
		if _, found := slice.binary_search(state.ready[:], Pgno(r.pgno)); found {
			return state, .Corrupted
		}
	}
	return state, .None
}

/*
Moves into `ready`, keeping it sorted, the records a write transaction
beginning from snapshot `s` may reuse:

- the pending records freed by a transaction ≤ `oldest`, its reuse
  horizon;
- the records of free-list runs freed by a transaction T ≤ s − 1 (D1),
  unless a reader holds T − 1, the run's own snapshot. `held` is every
  snapshot a live reader held when the horizon was computed, sorted. A
  reader that begins later holds snapshot s, whose run no commit has freed.

The pages are merged from the back, in place. `scratch` holds a sorted copy
of the pages moved. On Out_Of_Memory the state is unchanged.
*/
@(private)
freelist_release :: proc(state: ^Free_State, s: Txn_Id, oldest: Txn_Id, held: []Txn_Id, scratch: runtime.Allocator) -> Error {
	// Pending records are ordered by txn_id, so the eligible ones come first.
	n := 0
	for n < len(state.pending) && Txn_Id(state.pending[n].txn_id) <= oldest {
		n += 1
	}
	// Run records are ordered by txn_id too, so the ones D1 lets go come
	// first; of those, a held snapshot's run stays.
	prev := s - 1 if s > 0 else 0
	runs_end, m := 0, 0
	for runs_end < len(state.runs) && Txn_Id(state.runs[runs_end].txn_id) <= prev {
		if !run_held(state.runs[runs_end], held) {
			m += 1
		}
		runs_end += 1
	}
	if n + m == 0 {
		return .None
	}
	pages, alloc_err := make([]Pgno, n + m, scratch)
	if alloc_err != nil {
		return .Out_Of_Memory
	}
	for r, k in state.pending[:n] {
		pages[k] = Pgno(r.pgno)
	}
	moved := n
	for r in state.runs[:runs_end] {
		if !run_held(r, held) {
			pages[moved] = Pgno(r.pgno)
			moved += 1
		}
	}
	slice.sort(pages)
	old_len := len(state.ready)
	if resize(&state.ready, old_len + len(pages)) != nil {
		return .Out_Of_Memory
	}

	// Fill from the back, so no page is overwritten before it has moved.
	i, j := old_len - 1, len(pages) - 1
	for k := len(state.ready) - 1; j >= 0; k -= 1 {
		if i >= 0 && state.ready[i] > pages[j] {
			state.ready[k] = state.ready[i]
			i -= 1
		} else {
			state.ready[k] = pages[j]
			j -= 1
		}
	}
	remove_range(&state.pending, 0, n)
	// The held runs' records stay, in order, ahead of the ones D1 still
	// holds back.
	kept := 0
	for r in state.runs[:runs_end] {
		if run_held(r, held) {
			state.runs[kept] = r
			kept += 1
		}
	}
	if kept < runs_end {
		copy(state.runs[kept:], state.runs[runs_end:])
		resize(&state.runs, len(state.runs) - (runs_end - kept))
	}
	return .None
}

// Whether a reader in `held` (sorted) holds the snapshot whose free-list run
// the record `r` lists a page of: the one before the commit that freed it.
@(private = "file")
run_held :: proc(r: Free_Record, held: []Txn_Id) -> bool {
	_, found := slice.binary_search(held, Txn_Id(r.txn_id) - 1)
	return found
}

/*
Builds the free list that committing `txn` leaves behind, allocated with the
env allocator. Env.free itself is not changed; the commit swaps the result
in once it is durable. With S the snapshot the transaction began from:

- tag 0: the pages reusable now that the transaction didn't take, plus its
  loose pages, which no reader ever saw;
- the pending records and the earlier runs' records, unchanged;
- tag S + 1: the pages this transaction freed, and apart from them, in
  `runs`, the previous free-list run. Snapshot S still uses them.
*/
@(private)
freelist_build :: proc(txn: ^Txn) -> (next: Free_State, err: Error) {
	env, w, snap := txn.env, txn.write, txn.snapshot
	arena := virtual.arena_allocator(&w.arena)

	// The run's length is in its header, which may count a page of slack.
	run_pages := 0
	if snap.freelist_pgno != 0 {
		run_pages = int(page_header(page_ptr(txn, snap.freelist_pgno)).overflow_count)
	}
	freed, alloc_err := slice.clone(w.freed[:], arena)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	slice.sort(freed)
	slice.sort(w.loose[:])

	next.ready = make([dynamic]Pgno, env.allocator)
	next.pending = make([dynamic]Free_Record, env.allocator)
	next.runs = make([dynamic]Free_Record, env.allocator)
	defer if err != .None {
		free_state_destroy(&next)
	}
	if reserve(&next.ready, len(env.free.ready) + len(w.loose)) != nil || reserve(&next.pending, len(env.free.pending) + len(freed)) != nil || reserve(&next.runs, len(env.free.runs) + run_pages) != nil {
		return next, .Out_Of_Memory
	}

	// Merge the two sorted lists of reusable pages, leaving out the pages
	// taken: those before ready_next, and those in `taken`. A page taken
	// and then dropped again is loose, so it is still listed once.
	a, b, taken := env.free.ready[w.ready_next:], w.loose[:], w.taken[:]
	for len(a) > 0 || len(b) > 0 {
		if len(a) > 0 {
			for len(taken) > 0 && taken[0] < a[0] {
				taken = taken[1:]
			}
			if len(taken) > 0 && taken[0] == a[0] {
				a = a[1:]
				continue
			}
		}
		if len(b) == 0 || (len(a) > 0 && a[0] < b[0]) {
			append(&next.ready, a[0])
			a = a[1:]
		} else {
			append(&next.ready, b[0])
			b = b[1:]
		}
	}
	append(&next.pending, ..env.free.pending[:])
	tag := u64le(snap.txn_id + 1)
	for pgno in freed {
		append(&next.pending, Free_Record{pgno = u64le(pgno), txn_id = tag})
	}
	// Every earlier run was freed by a commit ≤ S, so the order holds.
	append(&next.runs, ..env.free.runs[:])
	for i in 0 ..< run_pages {
		append(&next.runs, Free_Record{pgno = u64le(snap.freelist_pgno + Pgno(i)), txn_id = tag})
	}
	return next, .None
}

/*
Allocates the run for `next`, the free list being committed. Returns its
first page and its length, or 0 and 0 for an empty list. The run takes page
numbers only: freelist_write writes it to the file a page at a time
(KV-I-0004 D6).

The run comes from the list's own reusable pages when it can: the lowest
run of consecutive ones (D5), which then leave the list. Taking j pages
leaves n − j records, and j must be at least the length they need. The
shortest such j is taken, and it is at most the j = 0 length k.

An exact fit doesn't always exist: the needed length falls by one page for
every page's worth of records, so as j grows it can jump from j + 1 to
j − 1, as it does for 257 records at 4 KiB pages. The shortest j then has
one page more than its records need, and never more than that: j − 1 pages
were too few, so the n − j + 1 records they would have left need at least
j, and one record fewer needs at least j − 1. That page is the slack a run
is allowed at open (FREELIST_RUN_SLACK, KV-T-0014).

If no run of the shortest length is free, no longer one is either, and the
run extends the file with the exact length k. If the map has no room for
that, the commit fails with Map_Full (KV-I-0002 D6).
*/
@(private)
freelist_place :: proc(txn: ^Txn, next: ^Free_State) -> (pgno: Pgno, pages: int, err: Error) {
	ps := txn.env.page_size
	n := free_state_count(next^)
	if n == 0 {
		return 0, 0, .None
	}
	k := freelist_run_pages(ps, n)
	for j in 1 ..= min(k, n - 1) {
		if freelist_run_pages(ps, n - j) > j {
			continue
		}
		idx, found := sorted_run_find(next.ready[:], j)
		if !found {
			break
		}
		pgno = next.ready[idx]
		remove_range(&next.ready, idx, idx + j)
		return pgno, j, .None
	}
	pgno = page_take_end(txn, k) or_return
	return pgno, k, .None
}

// Returns the index of the lowest run of `n` consecutive page numbers in
// the sorted `pages`.
@(private = "file")
sorted_run_find :: proc(pages: []Pgno, n: int) -> (idx: int, ok: bool) {
	start := 0
	for i in 0 ..< len(pages) {
		if i > 0 && pages[i] != pages[i - 1] + 1 {
			start = i
		}
		if i - start + 1 == n {
			return start, true
		}
	}
	return 0, false
}

/*
Writes `state` to the run of `pages` pages allocated for it at `pgno`: the
header, the tag-0 records, then the pending ones and the earlier runs' ones
merged in (txn_id, pgno) order. The rest of the run, a
page of slack included, is zeroed. The run is filled and written one page
at a time through one slot of the dirty-page pool, which must have one free
(KV-I-0004 D6), so a free list of any length needs one slot. The file must
already be large enough.
*/
@(private)
freelist_write :: proc(txn: ^Txn, pgno: Pgno, pages: int, state: Free_State) -> Error {
	env := txn.env
	ps := env.page_size
	slot := pool_alloc(&env.pool, 1, txn.mods) or_return
	defer pool_free(&env.pool, slot, 1)
	buf := pool_pages(&env.pool, slot, 1)
	per_page := ps / size_of(Free_Record)
	records := ([^]Free_Record)(raw_data(buf))[:per_page]

	// Records run on from offset PAGE_HEADER_SIZE across the pages, so on
	// every page they start at a record boundary: the first page's header
	// takes the place of its first record.
	#assert(PAGE_HEADER_SIZE == size_of(Free_Record))
	ready, pending, runs := state.ready[:], state.pending[:], state.runs[:]
	for i in 0 ..< pages {
		mem.zero_slice(buf)
		r := 0
		if i == 0 {
			h := page_header(buf)
			h.pgno = u64le(pgno)
			h.flags = PAGE_FREELIST
			h.overflow_count = u32le(pages)
			r = 1
		}
		for ; r < per_page && len(ready) > 0; r += 1 {
			records[r] = {pgno = u64le(ready[0])}
			ready = ready[1:]
		}
		// Every page is listed once, so no two records compare equal.
		for ; r < per_page && (len(pending) > 0 || len(runs) > 0); r += 1 {
			if len(runs) == 0 || (len(pending) > 0 && record_less(pending[0], runs[0])) {
				records[r] = pending[0]
				pending = pending[1:]
			} else {
				records[r] = runs[0]
				runs = runs[1:]
			}
		}
		os_pwrite(env.fd, buf, (i64(pgno) + i64(i)) * i64(ps)) or_return
	}
	assert(len(ready) == 0 && len(pending) == 0 && len(runs) == 0, "free list longer than its run")
	return .None
}
