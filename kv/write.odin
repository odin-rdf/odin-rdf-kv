package kv

import "core:mem/virtual"
import "core:slice"

/*
Allocates `n` contiguous pages and registers them as dirty. The returned
buffer is page-aligned, `n` pages long and new: a reused page's old
contents are never read. The caller initialises it.

The pages come from the first of these with room:
- for a single page, the transaction's loose pages;
- the reusable pages on the free list: for a single page the lowest one
  the transaction hasn't taken yet, for a run the lowest run of `n`
  consecutive ones (KV-I-0002 D5). Env.free itself doesn't change; the
  transaction records what it took (see Write_State);
- the end of the database, which grows by `n` pages.

Returns Map_Full if none of them has room.
*/
page_alloc :: proc(txn: ^Txn, n: int) -> (pgno: Pgno, buf: []byte, err: Error) {
	w := txn.write
	if n == 1 && len(w.loose) > 0 {
		buf = dirty_buf_alloc(txn, n) or_return
		pgno = pop(&w.loose)
	} else if idx, found := ready_run_find(txn, n); found {
		buf = dirty_buf_alloc(txn, n) or_return
		pgno = ready_take(txn, idx, n) or_return
	} else {
		return page_alloc_end(txn, n)
	}
	w.dirty[pgno] = buf
	return pgno, buf, .None
}

// Allocates `n` new pages at the end of the database, as page_alloc does.
@(private)
page_alloc_end :: proc(txn: ^Txn, n: int) -> (pgno: Pgno, buf: []byte, err: Error) {
	if end_room(txn) < n {
		return 0, nil, .Map_Full
	}
	buf = dirty_buf_alloc(txn, n) or_return
	pgno = txn.snapshot.last_pgno + 1
	txn.snapshot.last_pgno += Pgno(n)
	txn.write.dirty[pgno] = buf
	return pgno, buf, .None
}

// A page-aligned buffer for `n` dirty pages, from the transaction's arena.
@(private)
dirty_buf_alloc :: proc(txn: ^Txn, n: int) -> (buf: []byte, err: Error) {
	ps := txn.env.page_size
	alloc_err: virtual.Allocator_Error
	buf, alloc_err = virtual.arena_alloc(&txn.write.arena, uint(n * ps), uint(ps))
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	return buf, .None
}

// Number of pages that still fit in the map after the snapshot's last page.
@(private = "file")
end_room :: proc(txn: ^Txn) -> int {
	return txn.env.map_size / txn.env.page_size - int(txn.snapshot.last_pgno) - 1
}

/*
Finds the lowest run of `n` consecutive pages in Env.free.ready that `txn`
hasn't taken, ignoring the lowest `skip` untaken pages. Returns the index of
its first page. For n = 1 that is the lowest untaken page.

The search is linear, so it starts where earlier searches in the
transaction proved no run starts, and a failed one is not repeated: a
search for a run at least as long, skipping at least as many pages, fails
without scanning (see Write_State).
*/
@(private = "file")
ready_run_find :: proc(txn: ^Txn, n: int, skip := 0) -> (idx: int, ok: bool) {
	w := txn.write
	if w.miss != 0 && n >= w.miss {
		return 0, false
	}
	if w.miss_skipped != 0 && n >= w.miss_skipped && skip >= w.miss_skip {
		return 0, false
	}
	// A skip counts untaken pages from ready_next, so a search that skips
	// pages can't start later than that.
	from := w.ready_next
	if skip == 0 {
		for k in 2 ..= min(n, RUN_HINTS) {
			from = max(from, w.run_from[k])
		}
	}
	idx, ok = ready_run_scan(txn, n, skip, from)
	if ok {
		if skip == 0 && n >= 2 && n <= RUN_HINTS {
			w.run_from[n] = idx
		}
		return idx, true
	}
	// Keep the failure that rules out the most searches: the shortest
	// length, then the fewest pages skipped.
	if skip == 0 {
		if w.miss == 0 || n < w.miss {
			w.miss = n
		}
	} else if w.miss_skipped == 0 || n < w.miss_skipped || (n == w.miss_skipped && skip < w.miss_skip) {
		w.miss_skipped, w.miss_skip = n, skip
	}
	return 0, false
}

// The scan behind ready_run_find, from index `from` of Env.free.ready.
@(private = "file")
ready_run_scan :: proc(txn: ^Txn, n: int, skip: int, from: int) -> (idx: int, ok: bool) {
	w := txn.write
	ready, taken := txn.env.free.ready[:], w.taken[:]
	skip := skip
	start, length := 0, 0
	for i in from ..< len(ready) {
		p := ready[i]
		for len(taken) > 0 && taken[0] < p {
			taken = taken[1:]
		}
		if len(taken) > 0 && taken[0] == p {
			length = 0
			continue
		}
		if skip > 0 {
			skip -= 1
			continue
		}
		if length > 0 && p == ready[i - 1] + 1 {
			length += 1
		} else {
			start, length = i, 1
		}
		if length == n {
			return start, true
		}
	}
	return 0, false
}

/*
Takes the `n` pages of Env.free.ready from index `idx`, as found by
ready_run_find, and returns the first. A single page is the lowest untaken
one, so every page before it is taken already and ready_next moves past it.
A run is recorded in `taken` instead.
*/
@(private = "file")
ready_take :: proc(txn: ^Txn, idx: int, n: int) -> (pgno: Pgno, err: Error) {
	w := txn.write
	run := txn.env.free.ready[idx:idx + n]
	if n == 1 {
		w.ready_next = idx + 1
	} else {
		pos, _ := slice.binary_search(w.taken[:], run[0])
		if _, inject_err := inject_at_elems(&w.taken, pos, ..run); inject_err != nil {
			return 0, .Out_Of_Memory
		}
	}
	w.ready_taken += n
	return run[0], .None
}

// Whether `txn` has taken page `pgno` from Env.free.ready.
@(private)
ready_is_taken :: proc(txn: ^Txn, pgno: Pgno) -> bool {
	w := txn.write
	i, found := slice.binary_search(txn.env.free.ready[:], pgno)
	if !found {
		return false
	}
	if i < w.ready_next {
		return true
	}
	_, found = slice.binary_search(w.taken[:], pgno)
	return found
}

/*
Whether `singles` single pages and, unless `run` is 0, one run of `run`
pages are sure to be available, whatever order page_alloc is asked for
them in. Loose pages, untaken reusable pages and the room left in the map
count for single pages. The run needs the room at the end of the map, or a
run of reusable pages that survives the single pages taking the lowest
reusable pages first. Conservative, so that a change that passes it can't
hit Map_Full part-way.
*/
@(private = "file")
pages_available :: proc(txn: ^Txn, singles: int, run := 0) -> bool {
	w := txn.write
	end := end_room(txn)
	untaken := len(txn.env.free.ready) - w.ready_taken
	if singles + run > end + len(w.loose) + untaken {
		return false
	}
	if run == 0 || run <= end {
		return true
	}
	_, found := ready_run_find(txn, run, skip = clamp(singles - len(w.loose), 0, untaken))
	return found
}

/*
Drops the `count` pages starting at `pgno`, a single page or an overflow run,
that the tree no longer uses. Pages of the snapshot are recorded as freed,
for the free list to release once no reader can see them. Pages this
transaction wrote (their buffer is in `dirty` under `pgno`) were never seen
by anyone, so they are discarded and recorded as loose, for page_alloc to
hand out again (KV-I-0003 D8).
*/
@(private)
page_free :: proc(txn: ^Txn, pgno: Pgno, count := 1) {
	w := txn.write
	list := &w.freed
	if pgno in w.dirty {
		delete_key(&w.dirty, pgno)
		list = &w.loose
	}
	for i in 0 ..< count {
		append(list, pgno + Pgno(i))
	}
}

/*
Makes the page at `path` level `level` writable and returns it. A page this
transaction already wrote is returned as is. Otherwise the committed page is
copied to a new page number, the parent (already touched, as touching goes
top-down) is pointed at the copy, and the path is updated.
*/
page_touch :: proc(txn: ^Txn, path: ^Path, level: int) -> (page: []byte, err: Error) {
	e := &path.entries[level]
	if buf, ok := txn.write.dirty[e.pgno]; ok {
		return buf, .None
	}

	pgno, buf := page_alloc(txn, 1) or_return
	copy(buf, page_ptr(txn, e.pgno))
	page_header(buf).pgno = u64le(pgno)
	append(&txn.write.freed, e.pgno)

	if level == 0 {
		txn.snapshot.root = pgno
	} else {
		parent := path.entries[level - 1]
		branch_set_child(page_ptr(txn, parent.pgno), parent.idx, pgno)
	}
	e.pgno = pgno
	return buf, .None
}

/*
Stores `value` under `key`, replacing any existing value.

`key` and `value` must not point into this transaction's own pages, such as
a slice returned by `get` in the same write transaction: the insert moves
bytes around within those pages. Copy such data first.

Returns `Map_Full` without changing anything if the worst case of this put
might not fit in the reusable pages and the room left in the map. Any other failure after the tree has started to
change leaves the transaction unusable: later calls return the same error,
and it can only be aborted.
*/
put :: proc(txn: ^Txn, key, value: []byte) -> Error {
	if txn.read_only {
		return .Txn_Read_Only
	}
	if txn.err != .None {
		return txn.err
	}
	ps := txn.env.page_size
	if len(key) > max_key_size(ps) {
		return .Key_Too_Large
	}
	if len(value) > int(max(u32)) {
		return .Invalid_Argument
	}
	// Worst case: copy every page on the path, an overflow run for the
	// value, then split every level and add a new root. Checking up front
	// means a full map never leaves a half-done change behind.
	singles, run := 2 * int(txn.snapshot.depth) + 1, 0
	if leaf_needs_overflow(ps, len(key), len(value)) {
		run = overflow_pages(ps, len(value))
	}
	if !pages_available(txn, singles, run) {
		return .Map_Full
	}

	err := put_unchecked(txn, key, value)
	if err != .None {
		txn.err = err
	}
	return err
}

@(private = "file")
put_unchecked :: proc(txn: ^Txn, key, value: []byte) -> Error {
	snap := &txn.snapshot
	txn.mods += 1
	bigdata := leaf_needs_overflow(txn.env.page_size, len(key), len(value))

	path: Path
	exact := false
	if snap.root != 0 {
		exact = tree_search(txn, key, &path) or_return
		for level in 0 ..< path.depth {
			page_touch(txn, &path, level) or_return
		}
	}

	if exact {
		e := path_leaf(&path)
		leaf := page_ptr(txn, e.pgno)
		old, old_overflow, old_bigdata := leaf_value(leaf, e.idx)
		if !old_bigdata && !bigdata && len(old) == len(value) {
			copy(old, value)
			return .None
		}
		if old_bigdata {
			overflow_free(txn, old_overflow, leaf_value_size(leaf, e.idx)) or_return
		}
		node_remove(leaf, e.idx)
	} else {
		snap.entries += 1
	}

	node := Pending_Node{key = key, value = value}
	if bigdata {
		node.overflow = overflow_write(txn, value) or_return
	}

	if snap.root == 0 {
		pgno, leaf := page_alloc(txn, 1) or_return
		page_init(leaf, pgno, PAGE_LEAF)
		ok := pending_insert(leaf, 0, node, true)
		assert(ok)
		snap.root, snap.depth = pgno, 1
		return .None
	}
	return insert_node(txn, &path, path.depth - 1, node)
}

// A node waiting to be inserted: a leaf node (key, and the value inline or
// in the overflow run starting at `overflow`) or a branch node (key and
// child).
@(private = "file")
Pending_Node :: struct {
	key:      []byte,
	value:    []byte,
	overflow: Pgno,
	child:    Pgno,
}

@(private = "file")
pending_size :: proc(node: Pending_Node, leaf: bool) -> int {
	if !leaf {
		return branch_node_size(len(node.key))
	}
	return leaf_node_size(len(node.key), len(node.value), node.overflow != 0)
}

@(private = "file")
pending_insert :: proc(page: []byte, idx: int, node: Pending_Node, leaf: bool) -> bool {
	if !leaf {
		return branch_insert(page, idx, node.key, node.child)
	}
	if node.overflow != 0 {
		return leaf_insert_overflow(page, idx, node.key, node.overflow, len(node.value))
	}
	return leaf_insert(page, idx, node.key, node.value)
}

/*
Inserts `node` into the (already touched) page at `path` level `level`, at
the slot recorded in the path. If the page is full it is split, and the new
right page's separator is inserted into the parent the same way, up to a new
root if the root splits.
*/
@(private = "file")
insert_node :: proc(txn: ^Txn, path: ^Path, level: int, node: Pending_Node) -> Error {
	// The separator travelling up. Each level's separator is copied here only
	// after the previous one has been inserted, so one buffer is enough.
	sep_buf: [MAX_KEY_SIZE_ANY]byte
	node, level := node, level

	for {
		e := &path.entries[level]
		page := page_ptr(txn, e.pgno)
		leaf := page_is_leaf(page)
		if pending_insert(page, e.idx, node, leaf) {
			return .None
		}

		// Split: nodes from the split point on move to a new right page, and
		// the new node goes into whichever half it belongs to.
		right_pgno, right := page_alloc(txn, 1) or_return
		page_init(right, right_pgno, u16(page_header(page).flags))
		split := split_point(page, e.idx, pending_size(node, leaf))
		page_move_upper(page, right, split - 1 if e.idx < split else split)
		inserted := pending_insert(page, e.idx, node, leaf) if e.idx < split else pending_insert(right, e.idx - split, node, leaf)
		if !inserted {
			// Node size limits guarantee both halves have room.
			return .Corrupted
		}

		// The right page's first key separates it from the left page. On a
		// branch page that node's key moves up, and its slot becomes −∞.
		first := node_key(right, 0)
		copy(sep_buf[:], first)
		sep := sep_buf[:len(first)]
		if !leaf {
			child := branch_child(right, 0)
			node_remove(right, 0)
			ok := branch_insert(right, 0, nil, child)
			assert(ok)
		}

		if level == 0 {
			root_pgno, root := page_alloc(txn, 1) or_return
			page_init(root, root_pgno, PAGE_BRANCH)
			ok := branch_insert(root, 0, nil, e.pgno) && branch_insert(root, 1, sep, right_pgno)
			assert(ok)
			txn.snapshot.root = root_pgno
			txn.snapshot.depth += 1
			return .None
		}

		// Insert the right page just after the left one in the parent.
		level -= 1
		path.entries[level].idx += 1
		node = Pending_Node{key = sep, child = right_pgno}
	}
}
