package kv

import "core:mem/virtual"

/*
Allocates `n` contiguous new pages at the end of the database and registers
them as dirty. The returned buffer is page-aligned and `n` pages long; the
caller initialises it.
*/
page_alloc :: proc(txn: ^Txn, n: int) -> (pgno: Pgno, buf: []byte, err: Error) {
	ps := txn.env.page_size
	if !pages_available(txn, n) {
		return 0, nil, .Map_Full
	}
	alloc_err: virtual.Allocator_Error
	buf, alloc_err = virtual.arena_alloc(&txn.write.arena, uint(n * ps), uint(ps))
	if alloc_err != nil {
		return 0, nil, .Out_Of_Memory
	}
	pgno = txn.snapshot.last_pgno + 1
	txn.snapshot.last_pgno += Pgno(n)
	txn.write.dirty[pgno] = buf
	return pgno, buf, .None
}

// Whether `n` more pages fit in the map.
@(private = "file")
pages_available :: proc(txn: ^Txn, n: int) -> bool {
	return (int(txn.snapshot.last_pgno) + 1 + n) * txn.env.page_size <= txn.env.map_size
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
might not fit in the map. Any other failure after the tree has started to
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
	if len(value) > int(max(u32)) || leaf_needs_overflow(ps, len(key), len(value)) {
		// Overflow values arrive with KV-T-0006.
		return .Invalid_Argument
	}
	// Worst case: copy every page on the path, split every level, and add a
	// new root. Checking up front means a full map never leaves a half-done
	// change behind.
	if !pages_available(txn, 2 * int(txn.snapshot.depth) + 1) {
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

	if snap.root == 0 {
		pgno, leaf := page_alloc(txn, 1) or_return
		page_init(leaf, pgno, PAGE_LEAF)
		ok := leaf_insert(leaf, 0, key, value)
		assert(ok)
		snap.root, snap.depth, snap.entries = pgno, 1, 1
		return .None
	}

	path: Path
	exact := tree_search(txn, key, &path) or_return
	for level in 0 ..< path.depth {
		page_touch(txn, &path, level) or_return
	}
	e := path_leaf(&path)
	leaf := page_ptr(txn, e.pgno)

	if exact {
		old, _, bigdata := leaf_value(leaf, e.idx)
		if !bigdata && len(old) == len(value) {
			copy(old, value)
			return .None
		}
		node_remove(leaf, e.idx)
	} else {
		snap.entries += 1
	}
	return insert_node(txn, &path, path.depth - 1, Pending_Node{key = key, value = value})
}

// A node waiting to be inserted: a leaf node (key and value) or a branch
// node (key and child).
@(private = "file")
Pending_Node :: struct {
	key:   []byte,
	value: []byte,
	child: Pgno,
}

@(private = "file")
pending_size :: proc(node: Pending_Node, leaf: bool) -> int {
	return leaf_node_size(len(node.key), len(node.value), false) if leaf else branch_node_size(len(node.key))
}

@(private = "file")
pending_insert :: proc(page: []byte, idx: int, node: Pending_Node, leaf: bool) -> bool {
	if leaf {
		return leaf_insert(page, idx, node.key, node.value)
	}
	return branch_insert(page, idx, node.key, node.child)
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
