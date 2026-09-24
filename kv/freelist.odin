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
meta page records the run's first page and the number of records, or 0 and
0 for an empty list. The run's own pages are not in the list it holds; the
next commit frees them like any other page of the previous snapshot.

In memory the committed list is an Env's Free_State: the tag-0 pages as a
sorted array, and the rest as records.

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
}

// Number of pages in a free-list run holding `count` records.
freelist_run_pages :: proc "contextless" (page_size: int, count: int) -> int {
	return overflow_pages(page_size, count * size_of(Free_Record))
}

@(private)
free_state_count :: proc(state: Free_State) -> int {
	return len(state.ready) + len(state.pending)
}

@(private)
free_state_destroy :: proc(state: ^Free_State) {
	delete(state.ready)
	delete(state.pending)
	state^ = {}
}

@(private = "file")
record_less :: proc(a, b: Free_Record) -> bool {
	return a.txn_id < b.txn_id || (a.txn_id == b.txn_id && a.pgno < b.pgno)
}

/*
Returns the records of the free-list run of `snap`, as a slice into the map
at `base`, after checking the run's header: it lies within the snapshot,
records its own page number and PAGE_FREELIST, and has exactly the pages its
records need. The run was committed, so it is always read from the map.

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
	pages = run_header_check(base[off:off + page_size], pgno, last, PAGE_FREELIST, count * size_of(Free_Record)) or_return
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
*/
@(private)
freelist_load :: proc(base: [^]byte, page_size: int, snap: Snapshot, allocator := context.allocator) -> (state: Free_State, err: Error) {
	state.ready = make([dynamic]Pgno, allocator)
	state.pending = make([dynamic]Free_Record, allocator)
	defer if err != .None {
		free_state_destroy(&state)
	}
	if snap.freelist_pgno == 0 {
		return state, .None if snap.freelist_count == 0 else .Corrupted
	}
	records, run_pages, ok := freelist_run(base, page_size, snap)
	if !ok {
		return state, .Corrupted
	}

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
Moves the pending records freed by a transaction ≤ `oldest` into `ready`,
keeping it sorted: a merge from the back, in place. `scratch` holds a sorted
copy of the pages moved. On Out_Of_Memory the state is unchanged.
*/
@(private)
freelist_release :: proc(state: ^Free_State, oldest: Txn_Id, scratch: runtime.Allocator) -> Error {
	// Pending records are ordered by txn_id, so the eligible ones come first.
	n := 0
	for n < len(state.pending) && Txn_Id(state.pending[n].txn_id) <= oldest {
		n += 1
	}
	if n == 0 {
		return .None
	}
	pages, alloc_err := make([]Pgno, n, scratch)
	if alloc_err != nil {
		return .Out_Of_Memory
	}
	for r, i in state.pending[:n] {
		pages[i] = Pgno(r.pgno)
	}
	slice.sort(pages)
	old_len := len(state.ready)
	if resize(&state.ready, old_len + n) != nil {
		return .Out_Of_Memory
	}

	// Fill from the back, so no page is overwritten before it has moved.
	i, j := old_len - 1, n - 1
	for k := old_len + n - 1; j >= 0; k -= 1 {
		if i >= 0 && state.ready[i] > pages[j] {
			state.ready[k] = state.ready[i]
			i -= 1
		} else {
			state.ready[k] = pages[j]
			j -= 1
		}
	}
	remove_range(&state.pending, 0, n)
	return .None
}

/*
Builds the free list that committing `txn` leaves behind, allocated with the
env allocator. Env.free itself is not changed; the commit swaps the result
in once it is durable. With S the snapshot the transaction began from:

- tag 0: the pages reusable now that the transaction didn't take, plus its
  loose pages, which no reader ever saw;
- the pending records, unchanged;
- tag S + 1: the pages this transaction freed and the previous free-list
  run. Snapshot S still uses them.
*/
@(private)
freelist_build :: proc(txn: ^Txn) -> (next: Free_State, err: Error) {
	env, w, snap := txn.env, txn.write, txn.snapshot
	arena := virtual.arena_allocator(&w.arena)

	run_pages := 0
	if snap.freelist_pgno != 0 {
		run_pages = freelist_run_pages(env.page_size, int(snap.freelist_count))
	}
	freed, alloc_err := make([]Pgno, len(w.freed) + run_pages, arena)
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	copy(freed, w.freed[:])
	for i in 0 ..< run_pages {
		freed[len(w.freed) + i] = snap.freelist_pgno + Pgno(i)
	}
	slice.sort(freed)
	slice.sort(w.loose[:])

	next.ready = make([dynamic]Pgno, env.allocator)
	next.pending = make([dynamic]Free_Record, env.allocator)
	defer if err != .None {
		free_state_destroy(&next)
	}
	if reserve(&next.ready, len(env.free.ready) + len(w.loose)) != nil || reserve(&next.pending, len(env.free.pending) + len(freed)) != nil {
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
	return next, .None
}

/*
Allocates the run for `next`, the free list being committed, registered as
a dirty page of `txn`. Returns its first page, its length and its buffer,
or 0, 0 and nil for an empty list.

The run comes from the list's own reusable pages when it can: the lowest
run of consecutive ones (D5), which then leave the list. Taking j pages
leaves n − j records, and the run must be exactly the length they need,
because that is how a run is validated at open. The needed length only
falls as j grows, so at most one j fits, and it is at most the j = 0 length;
if no j fits, or no run of that length is free, the run extends the file.
If the map has no room for that either, the commit fails with Map_Full
(KV-I-0002 D6).
*/
@(private)
freelist_place :: proc(txn: ^Txn, next: ^Free_State) -> (pgno: Pgno, pages: int, buf: []byte, err: Error) {
	ps := txn.env.page_size
	n := free_state_count(next^)
	if n == 0 {
		return 0, 0, nil, .None
	}
	k := freelist_run_pages(ps, n)
	for j in 1 ..= min(k, n - 1) {
		if freelist_run_pages(ps, n - j) != j {
			continue
		}
		idx, found := sorted_run_find(next.ready[:], j)
		if !found {
			break
		}
		pgno = next.ready[idx]
		buf = dirty_buf_alloc(txn, j) or_return
		txn.write.dirty[pgno] = buf
		remove_range(&next.ready, idx, idx + j)
		return pgno, j, buf, .None
	}
	pgno, buf = page_alloc_end(txn, k) or_return
	return pgno, k, buf, .None
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

// Writes `state` into `buf`, the run of `pages` pages allocated for it at
// `pgno`: the header, the tag-0 records, then the pending ones.
@(private)
freelist_write :: proc(buf: []byte, pgno: Pgno, pages: int, state: Free_State) {
	h := page_header(buf)
	h^ = {}
	h.pgno = u64le(pgno)
	h.flags = PAGE_FREELIST
	h.overflow_count = u32le(pages)

	count := free_state_count(state)
	records := ([^]Free_Record)(&buf[PAGE_HEADER_SIZE])[:count]
	for p, i in state.ready {
		records[i] = {pgno = u64le(p)}
	}
	copy(records[len(state.ready):], state.pending[:])
	mem.zero_slice(buf[PAGE_HEADER_SIZE + count * size_of(Free_Record):])
}
