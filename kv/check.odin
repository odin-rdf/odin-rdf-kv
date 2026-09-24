package kv

import "base:runtime"
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
	c := checker_make(txn, allocator)
	defer delete(c.visited, allocator)
	return tree_walk(&c)
}

/*
Checks that every page in [2, last_pgno] visible to `txn` has exactly one
owner: the tree (its pages and overflow runs, walked as by tree_check), the
free-list run, or a free-list record. In a write transaction, the pages it
has freed or dropped (`freed` and `loose`) are owners too; the free list is
the one the transaction began from. Pages 0 and 1 are the meta pages.

This is the check that catches a leaked page or one owned twice. Meant for
tests; it allocates a bit per page with `allocator`.
*/
space_check :: proc(txn: ^Txn, allocator := context.temp_allocator) -> (ok: bool, reason: string) {
	c := checker_make(txn, allocator)
	defer delete(c.visited, allocator)
	if walk_ok, walk_reason := tree_walk(&c); !walk_ok {
		return false, walk_reason
	}

	snap := txn.snapshot
	if snap.freelist_pgno != 0 || snap.freelist_count != 0 {
		records, pages, run_ok := freelist_run(txn.env.map_base, txn.env.page_size, snap)
		if !run_ok {
			return false, "bad free-list run"
		}
		for i in 0 ..< pages {
			if mark_ok, mark_reason := mark_free(&c, snap.freelist_pgno + Pgno(i)); !mark_ok {
				return false, mark_reason
			}
		}
		for r in records {
			if mark_ok, mark_reason := mark_free(&c, Pgno(r.pgno)); !mark_ok {
				return false, mark_reason
			}
		}
	}
	if txn.write != nil {
		for pgno in txn.write.freed {
			if mark_ok, mark_reason := mark_free(&c, pgno); !mark_ok {
				return false, mark_reason
			}
		}
		for pgno in txn.write.loose {
			if mark_ok, mark_reason := mark_free(&c, pgno); !mark_ok {
				return false, mark_reason
			}
		}
	}
	if c.marked != int(snap.last_pgno) - 1 {
		return false, "page owned by nothing"
	}
	return true, ""
}

@(private = "file")
Tree_Checker :: struct {
	txn:     ^Txn,
	depth:   int,
	// One bit per page number up to the snapshot's last_pgno.
	visited: []u64,
	// Number of bits set in `visited`.
	marked:  int,
	entries: u64,
}

@(private = "file")
checker_make :: proc(txn: ^Txn, allocator: runtime.Allocator) -> Tree_Checker {
	return Tree_Checker {
		txn     = txn,
		depth   = int(txn.snapshot.depth),
		visited = make([]u64, int(txn.snapshot.last_pgno) / 64 + 1, allocator),
	}
}

// Marks `pgno`, which must be in range, as visited. Returns false if it
// already was.
@(private = "file")
visit :: proc(c: ^Tree_Checker, pgno: Pgno) -> bool {
	word, bit := &c.visited[pgno / 64], u64(1) << (pgno % 64)
	if word^ & bit != 0 {
		return false
	}
	word^ |= bit
	c.marked += 1
	return true
}

// Marks a page owned by the free list or the write transaction.
@(private = "file")
mark_free :: proc(c: ^Tree_Checker, pgno: Pgno) -> (ok: bool, reason: string) {
	if pgno < 2 || pgno > c.txn.snapshot.last_pgno {
		return false, "free page out of range"
	}
	if !visit(c, pgno) {
		return false, "page owned twice"
	}
	return true, ""
}

// The walk behind tree_check, marking every page it reaches.
@(private = "file")
tree_walk :: proc(c: ^Tree_Checker) -> (ok: bool, reason: string) {
	snap := c.txn.snapshot
	if snap.root == 0 {
		if snap.depth != 0 || snap.entries != 0 {
			return false, "empty tree with non-zero depth or entries"
		}
		return true, ""
	}
	if snap.depth == 0 || int(snap.depth) > MAX_DEPTH {
		return false, "bad depth"
	}
	if sub_ok, sub_reason := check_subtree(c, snap.root, 1, {}); !sub_ok {
		return false, sub_reason
	}
	if c.entries != snap.entries {
		return false, "entry count does not match the snapshot"
	}
	return true, ""
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
		if !visit(c, pgno + Pgno(i)) {
			return false, "overflow page reachable more than once"
		}
	}
	return true, ""
}

@(private = "file")
check_subtree :: proc(c: ^Tree_Checker, pgno: Pgno, level: int, r: Key_Range) -> (ok: bool, reason: string) {
	if pgno < 2 || pgno > c.txn.snapshot.last_pgno {
		return false, "page number out of range"
	}
	if !visit(c, pgno) {
		return false, "page reachable more than once"
	}

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
