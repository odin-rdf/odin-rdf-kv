package kv

/*
Removes `key` and its value. Returns Not_Found, changing nothing, if the key
isn't there: no page is copied and the transaction's cursors stay valid.

`key` is only read while searching for it, before anything changes, so it
may point into this transaction's own pages: a key returned by a cursor, or
a value returned by `get`, in the same write transaction. That makes
deleting the key a cursor is on safe. Like `put`, a delete invalidates the
transaction's cursors and every slice returned in it so far, so a cursor is
repositioned after each one:

	// Every key:
	c := kv.cursor_open(&txn)
	for key, _, err := kv.cursor_first(&c); err == .None; key, _, err = kv.cursor_first(&c) {
		kv.del(&txn, key) or_return
	}

	// Every key in [start, end): copy the key before deleting it.
	buf: [kv.MAX_KEY_SIZE_ANY]byte
	for key, _, err := kv.cursor_seek(&c, start); err == .None && bytes.compare(key, end) < 0; {
		n := copy(buf[:], key)
		kv.del(&txn, key) or_return
		key, _, err = kv.cursor_seek(&c, buf[:n])
	}

A page that drops below a quarter full is merged with a sibling when the two
fit in one page, and an empty page is removed. There is no borrowing from
siblings, so a page can stay underfull (KV-I-0003 D1).

Returns Map_Full without changing anything if the pages the delete copies
might not fit: a delete copies its path before it can free anything, and
the pages it frees only become reusable after later commits. Returns
Out_Of_Memory without changing anything if those copies might not fit in
the dirty-page pool. Any other failure after the tree has started to
change leaves the transaction unusable, as with `put`.
*/
del :: proc(txn: ^Txn, key: []byte) -> Error {
	if txn.read_only {
		return .Txn_Read_Only
	}
	if txn.err != .None {
		return txn.err
	}
	path: Path
	exact := tree_search(txn, key, &path) or_return
	if !exact {
		return .Not_Found
	}
	// Merges move nodes into pages already copied, so the path is all a
	// delete allocates (KV-I-0003 D2).
	if !pages_available(txn, path.depth) {
		return .Map_Full
	}
	if !pool_available(&txn.env.pool, path.depth) {
		return .Out_Of_Memory
	}

	err := del_unchecked(txn, &path)
	if err != .None {
		txn.err = err
	}
	return err
}

@(private = "file")
del_unchecked :: proc(txn: ^Txn, path: ^Path) -> Error {
	txn.mods += 1
	for level in 0 ..< path.depth {
		page_touch(txn, path, level) or_return
	}

	e := path_leaf(path)
	leaf := page_ptr(txn, e.pgno)
	if _, overflow, bigdata := leaf_value(leaf, e.idx); bigdata {
		overflow_free(txn, overflow, leaf_value_size(leaf, e.idx)) or_return
	}
	node_remove(leaf, e.idx)
	txn.snapshot.entries -= 1

	rebalance(txn, path) or_return
	root_collapse(txn)
	return .None
}

/*
Walks up the (touched) path from the leaf, fixing each page whose parent
changed (KV-I-0003 D4, D5). At each level below the root:
- an empty page is freed and its slot removed from the parent;
- an underfull page takes in its right sibling, or else its left one, if
  the two fit in one page: the sibling's nodes move into the page on the
  path, which is already a copy, so the sibling is freed without being
  copied (D2), and the parent loses one slot;
- otherwise the parent didn't change, and nothing above can have either.
*/
@(private = "file")
rebalance :: proc(txn: ^Txn, path: ^Path) -> Error {
	for level := path.depth - 1; level > 0; level -= 1 {
		e := path.entries[level]
		page := page_ptr(txn, e.pgno)
		up := path.entries[level - 1]
		parent := page_ptr(txn, up.pgno)
		i := up.idx

		if page_num_keys(page) == 0 {
			page_free(txn, e.pgno)
			parent_remove(parent, i)
			continue
		}
		if !page_underfull(page) {
			return .None
		}

		// The separator for the right-hand page of the pair is read in
		// place: the parent only changes after the merge.
		leaf := level == path.depth - 1
		if i + 1 < page_num_keys(parent) {
			sib_pgno, sib := sibling(txn, parent, i + 1, leaf) or_return
			if sep := node_key(parent, i + 1); page_merge_fits(page, sib, len(sep)) {
				page_merge(page, sib, false, sep)
				page_free(txn, sib_pgno)
				parent_remove(parent, i + 1)
				continue
			}
		}
		if i > 0 {
			sib_pgno, sib := sibling(txn, parent, i - 1, leaf) or_return
			if sep := node_key(parent, i); page_merge_fits(page, sib, len(sep)) {
				page_merge(page, sib, true, sep)
				page_free(txn, sib_pgno)
				// The left slot keeps its separator and now leads to the
				// merged page.
				branch_set_child(parent, i - 1, e.pgno)
				parent_remove(parent, i)
				continue
			}
		}
		return .None
	}
	return .None
}

// The child in slot `idx` of branch page `parent`, checked like a page
// reached by tree_search.
@(private = "file")
sibling :: proc(txn: ^Txn, parent: []byte, idx: int, leaf: bool) -> (pgno: Pgno, page: []byte, err: Error) {
	pgno = branch_child(parent, idx)
	if pgno < 2 || pgno > txn.snapshot.last_pgno {
		return 0, nil, .Corrupted
	}
	page = page_ptr(txn, pgno)
	page_check_header(page, pgno, leaf) or_return
	return pgno, page, .None
}

// Removes slot `idx` of a branch page. If that was slot 0, the new first
// slot becomes −∞ (KV-I-0003 D6).
@(private = "file")
parent_remove :: proc(parent: []byte, idx: int) {
	node_remove(parent, idx)
	if idx == 0 && page_num_keys(parent) > 0 {
		branch_clear_first_key(parent)
	}
}

// Shrinks the tree from the top: a branch root with one child gives way to
// that child, as often as needed, and an empty root (a leaf, or a branch
// whose last child was removed) leaves the tree empty.
@(private = "file")
root_collapse :: proc(txn: ^Txn) {
	snap := &txn.snapshot
	for snap.root != 0 {
		root := page_ptr(txn, snap.root)
		n := page_num_keys(root)
		if n == 0 {
			page_free(txn, snap.root)
			snap.root, snap.depth = 0, 0
		} else if n == 1 && page_is_branch(root) {
			child := branch_child(root, 0)
			page_free(txn, snap.root)
			snap.root = child
			snap.depth -= 1
		} else {
			return
		}
	}
}
