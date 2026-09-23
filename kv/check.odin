package kv

import "core:bytes"

/*
Walks the whole tree visible to `txn` and checks its structure: every page
passes page_check and records its own page number, pages are reached only
once, branch pages sit above the leaves and all leaves are at the same
depth, every key lies between the separators that lead to it, only the root
may be an empty leaf, and the number of entries matches the snapshot.

Meant for tests and debug builds; it allocates a set of visited pages with
`allocator`.
*/
tree_check :: proc(txn: ^Txn, allocator := context.temp_allocator) -> (ok: bool, reason: string) {
	snap := txn.snapshot
	if snap.root == 0 {
		if snap.depth != 0 || snap.entries != 0 {
			return false, "empty tree with non-zero depth or entries"
		}
		return true, ""
	}
	if snap.depth == 0 || int(snap.depth) > MAX_DEPTH {
		return false, "bad depth"
	}

	c := Tree_Checker {
		txn     = txn,
		depth   = int(snap.depth),
		visited = make(map[Pgno]struct{}, allocator),
	}
	defer delete(c.visited)

	if sub_ok, sub_reason := check_subtree(&c, snap.root, 1, {}); !sub_ok {
		return false, sub_reason
	}
	if c.entries != snap.entries {
		return false, "entry count does not match the snapshot"
	}
	return true, ""
}

@(private = "file")
Tree_Checker :: struct {
	txn:     ^Txn,
	depth:   int,
	visited: map[Pgno]struct{},
	entries: u64,
}

// Bounds on the keys of a subtree: lo ≤ key < hi, each only if present.
@(private = "file")
Key_Range :: struct {
	lo, hi:         []byte,
	has_lo, has_hi: bool,
}

@(private = "file")
key_in_range :: proc(key: []byte, r: Key_Range) -> bool {
	if r.has_lo && bytes.compare(key, r.lo) < 0 {
		return false
	}
	if r.has_hi && bytes.compare(key, r.hi) >= 0 {
		return false
	}
	return true
}

// Checks an overflow run and marks all its pages as visited.
@(private = "file")
check_overflow :: proc(c: ^Tree_Checker, pgno: Pgno, key_len, val_len: int) -> (ok: bool, reason: string) {
	count, err := overflow_check(c.txn, pgno, val_len)
	if err != .None {
		return false, "bad overflow run"
	}
	if !leaf_needs_overflow(c.txn.env.page_size, key_len, val_len) {
		return false, "overflow run for a value that fits inline"
	}
	for i in 0 ..< count {
		p := pgno + Pgno(i)
		if p in c.visited {
			return false, "overflow page reachable more than once"
		}
		c.visited[p] = {}
	}
	return true, ""
}

@(private = "file")
check_subtree :: proc(c: ^Tree_Checker, pgno: Pgno, level: int, r: Key_Range) -> (ok: bool, reason: string) {
	if pgno < 2 || pgno > c.txn.snapshot.last_pgno {
		return false, "page number out of range"
	}
	if pgno in c.visited {
		return false, "page reachable more than once"
	}
	c.visited[pgno] = {}

	page := page_ptr(c.txn, pgno)
	if page_ok, page_reason := page_check(page); !page_ok {
		return false, page_reason
	}
	if Pgno(page_header(page).pgno) != pgno {
		return false, "page header records a different page number"
	}
	leaf := level == c.depth
	if leaf != page_is_leaf(page) {
		return false, "branch and leaf pages at the wrong levels"
	}

	n := page_num_keys(page)
	if leaf {
		if n == 0 && level > 1 {
			return false, "empty leaf below the root"
		}
		for i in 0 ..< n {
			if !key_in_range(node_key(page, i), r) {
				return false, "leaf key outside its parent's separators"
			}
			if _, overflow, bigdata := leaf_value(page, i); bigdata {
				if run_ok, run_reason := check_overflow(c, overflow, len(node_key(page, i)), leaf_value_size(page, i)); !run_ok {
					return false, run_reason
				}
			}
		}
		c.entries += u64(n)
		return true, ""
	}

	for i in 0 ..< n {
		child_range := r
		if i > 0 {
			sep := node_key(page, i)
			if !key_in_range(sep, r) {
				return false, "separator outside its parent's separators"
			}
			child_range.lo, child_range.has_lo = sep, true
		}
		if i + 1 < n {
			child_range.hi, child_range.has_hi = node_key(page, i + 1), true
		}
		if sub_ok, sub_reason := check_subtree(c, branch_child(page, i), level + 1, child_range); !sub_ok {
			return false, sub_reason
		}
	}
	return true, ""
}
