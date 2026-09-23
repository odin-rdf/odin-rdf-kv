package kv

/*
A cursor walks the keys of a transaction in order. It is a value with no
heap allocation, and needs no closing.

	// Every key in [start, end):
	c := kv.cursor_open(&txn)
	for key, value, err := kv.cursor_seek(&c, start); err == .None; key, value, err = kv.cursor_next(&c) {
		if bytes.compare(key, end) >= 0 {
			break
		}
		...
	}

Keys and values are returned without copying, with the same lifetime as
`get` results. In a write transaction, a `put` invalidates the transaction's
cursors: `cursor_first`, `cursor_last` or `cursor_seek` reposition a cursor
and make it usable again, while `cursor_next`/`cursor_prev` on a stale
cursor are a bug (asserted in debug builds; see `cursor_stale`).
*/
Cursor :: struct {
	txn:   ^Txn,
	// The transaction's gen and mods when the cursor was last positioned.
	gen:   u32,
	mods:  u32,
	path:  Path,
	state: Cursor_State,
}

Cursor_State :: enum u8 {
	// Not positioned yet: next acts as first, prev as last.
	Unpositioned,
	On_Item,
	// Moved before the first key; the path is at the first key.
	Before_First,
	// Moved past the last key; the path is at the last key.
	After_Last,
}

cursor_open :: proc(txn: ^Txn) -> Cursor {
	return Cursor{txn = txn, gen = txn.gen, mods = txn.mods}
}

// Whether the transaction has ended or changed since the cursor was last
// positioned.
cursor_stale :: proc(c: ^Cursor) -> bool {
	return c.txn.done || c.gen != c.txn.gen || c.mods != c.txn.mods
}

// Positions at the first key.
cursor_first :: proc(c: ^Cursor) -> (key, value: []byte, err: Error) {
	return cursor_edge(c, true)
}

// Positions at the last key.
cursor_last :: proc(c: ^Cursor) -> (key, value: []byte, err: Error) {
	return cursor_edge(c, false)
}

// Positions at the first key ≥ `key`. If there is none, returns Not_Found
// and leaves the cursor past the last key.
cursor_seek :: proc(c: ^Cursor, key: []byte) -> (k, v: []byte, err: Error) {
	cursor_reset(c)
	tree_search(c.txn, key, &c.path) or_return
	if c.path.depth == 0 {
		return nil, nil, .Not_Found
	}
	leaf := path_leaf(&c.path)
	n := page_num_keys(page_ptr(c.txn, leaf.pgno))
	if leaf.idx < n {
		c.state = .On_Item
		return cursor_current(c)
	}
	// Past the end of this leaf: the answer is the first key of the next one.
	if n > 0 {
		leaf.idx = n - 1
	}
	moved := cursor_step(c, true) or_return
	if !moved {
		if n == 0 {
			c.state = .Unpositioned
		} else {
			c.state = .After_Last
		}
		return nil, nil, .Not_Found
	}
	c.state = .On_Item
	return cursor_current(c)
}

// Moves to the next key. Returns Not_Found, leaving the cursor past the
// last key, when there is none.
cursor_next :: proc(c: ^Cursor) -> (key, value: []byte, err: Error) {
	return cursor_move(c, true)
}

// Moves to the previous key. Returns Not_Found, leaving the cursor before
// the first key, when there is none.
cursor_prev :: proc(c: ^Cursor) -> (key, value: []byte, err: Error) {
	return cursor_move(c, false)
}

@(private = "file")
cursor_reset :: proc(c: ^Cursor) {
	when ODIN_DEBUG {
		assert(!c.txn.done, "cursor used after its transaction ended")
	}
	c.gen, c.mods = c.txn.gen, c.txn.mods
	c.path.depth = 0
	c.state = .Unpositioned
}

@(private = "file")
cursor_edge :: proc(c: ^Cursor, first: bool) -> (key, value: []byte, err: Error) {
	cursor_reset(c)
	root := c.txn.snapshot.root
	if root == 0 {
		return nil, nil, .Not_Found
	}
	descend_edge(c, 0, root, first) or_return
	if page_num_keys(page_ptr(c.txn, path_leaf(&c.path).pgno)) == 0 {
		c.path.depth = 0
		return nil, nil, .Not_Found
	}
	c.state = .On_Item
	return cursor_current(c)
}

@(private = "file")
cursor_move :: proc(c: ^Cursor, forward: bool) -> (key, value: []byte, err: Error) {
	if c.state == .Unpositioned {
		return cursor_edge(c, forward)
	}
	when ODIN_DEBUG {
		assert(!cursor_stale(c), "cursor used after its transaction ended or changed; reposition it first")
	}
	switch c.state {
	case .Unpositioned:
	case .Before_First:
		if !forward {
			return nil, nil, .Not_Found
		}
		c.state = .On_Item
		return cursor_current(c)
	case .After_Last:
		if forward {
			return nil, nil, .Not_Found
		}
		c.state = .On_Item
		return cursor_current(c)
	case .On_Item:
	}

	moved := cursor_step(c, forward) or_return
	if !moved {
		c.state = .After_Last if forward else .Before_First
		return nil, nil, .Not_Found
	}
	return cursor_current(c)
}

/*
Moves the path one key forward or back. Within a leaf that's just the slot
index; at a leaf's edge, climb to the nearest ancestor with a slot in that
direction, step to it, and descend to the leftmost (or rightmost) leaf
below. Returns false, leaving the path unchanged, at the edge of the tree.
*/
@(private = "file")
cursor_step :: proc(c: ^Cursor, forward: bool) -> (moved: bool, err: Error) {
	leaf := path_leaf(&c.path)
	n := page_num_keys(page_ptr(c.txn, leaf.pgno))
	if forward && leaf.idx + 1 < n {
		leaf.idx += 1
		return true, .None
	}
	if !forward && leaf.idx > 0 {
		leaf.idx -= 1
		return true, .None
	}

	for level := c.path.depth - 2; level >= 0; level -= 1 {
		e := &c.path.entries[level]
		branch := page_ptr(c.txn, e.pgno)
		if forward && e.idx + 1 < page_num_keys(branch) {
			e.idx += 1
		} else if !forward && e.idx > 0 {
			e.idx -= 1
		} else {
			continue
		}
		child := branch_child(branch, e.idx)
		descend_edge(c, level + 1, child, forward) or_return
		return true, .None
	}
	return false, .None
}

// Fills the path from `level` (page `pgno`) down to a leaf, taking the first
// slot of every page (or the last one), checking each page on the way.
@(private = "file")
descend_edge :: proc(c: ^Cursor, level: int, pgno: Pgno, first: bool) -> Error {
	snap := &c.txn.snapshot
	depth := int(snap.depth)
	if depth > MAX_DEPTH {
		return .Corrupted
	}
	pgno := pgno
	for l in level ..< depth {
		if pgno < 2 || pgno > snap.last_pgno {
			return .Corrupted
		}
		page := page_ptr(c.txn, pgno)
		leaf := l == depth - 1
		page_check_header(page, pgno, leaf) or_return
		n := page_num_keys(page)
		if !leaf && n == 0 {
			return .Corrupted
		}
		idx := 0 if first else max(n - 1, 0)
		c.path.entries[l] = {pgno, idx}
		if !leaf {
			pgno = branch_child(page, idx)
		}
	}
	c.path.depth = depth
	return .None
}

@(private = "file")
cursor_current :: proc(c: ^Cursor) -> (key, value: []byte, err: Error) {
	e := path_leaf(&c.path)
	page := page_ptr(c.txn, e.pgno)
	key = node_key(page, e.idx)
	data, overflow, bigdata := leaf_value(page, e.idx)
	if bigdata {
		value = overflow_value(c.txn, overflow, leaf_value_size(page, e.idx)) or_return
		return key, value, .None
	}
	return key, data, .None
}
