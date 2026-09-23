package kv

// Deepest tree the code supports. With at least 4 nodes per page, a tree
// this deep would need far more pages than a map can hold.
MAX_DEPTH :: 24

Path_Entry :: struct {
	pgno: Pgno,
	// Slot index within the page.
	idx:  int,
}

// The pages and slots visited from the root down to a leaf. entries[0] is
// the root and entries[depth - 1] the leaf.
Path :: struct {
	depth:   int,
	entries: [MAX_DEPTH]Path_Entry,
}

// The leaf entry of a non-empty path.
path_leaf :: #force_inline proc(path: ^Path) -> ^Path_Entry {
	return &path.entries[path.depth - 1]
}

/*
Descends from the snapshot's root towards `key`, recording every page and
slot visited in `path`. At the leaf, the slot is the first key ≥ `key`, and
`exact` tells whether it is equal. An empty tree gives a path of depth 0.

Every page is checked for the expected page number and kind on the way down,
so a damaged tree gives `Corrupted` instead of reading out of bounds.
*/
tree_search :: proc(txn: ^Txn, key: []byte, path: ^Path) -> (exact: bool, err: Error) {
	path.depth = 0
	snap := &txn.snapshot
	if snap.root == 0 {
		return false, .None
	}
	depth := int(snap.depth)
	if depth > MAX_DEPTH {
		return false, .Corrupted
	}

	pgno := snap.root
	for level in 0 ..< depth {
		page := page_ptr(txn, pgno)
		leaf := level == depth - 1
		page_check_header(page, pgno, leaf) or_return

		path.depth = level + 1
		if leaf {
			idx: int
			idx, exact = page_search(page, key)
			path.entries[level] = {pgno, idx}
			return exact, .None
		}
		if page_num_keys(page) == 0 {
			return false, .Corrupted
		}
		idx := branch_find_child(page, key)
		path.entries[level] = {pgno, idx}
		pgno = branch_child(page, idx)
		if pgno < 2 || pgno > snap.last_pgno {
			return false, .Corrupted
		}
	}
	unreachable()
}

// Cheap sanity checks on a page reached by following a pointer: the page
// number it records, its kind, and header fields that other accessors
// slice with.
@(private = "file")
page_check_header :: proc(page: []byte, pgno: Pgno, leaf: bool) -> Error {
	h := page_header(page)
	if Pgno(h.pgno) != pgno || u16(h.flags) != (PAGE_LEAF if leaf else PAGE_BRANCH) {
		return .Corrupted
	}
	lower, upper := int(h.lower), int(h.upper)
	if lower < PAGE_HEADER_SIZE || lower > upper || upper > len(page) {
		return .Corrupted
	}
	return .None
}

/*
Looks up `key`. The value is returned without copying: in a read
transaction it points into the map and stays valid until the transaction
ends; in a write transaction it is invalidated by the next change.
*/
get :: proc(txn: ^Txn, key: []byte) -> (value: []byte, err: Error) {
	path: Path
	exact := tree_search(txn, key, &path) or_return
	if !exact {
		return nil, .Not_Found
	}
	leaf := path_leaf(&path)
	page := page_ptr(txn, leaf.pgno)
	data, overflow, bigdata := leaf_value(page, leaf.idx)
	if bigdata {
		return overflow_value(txn, overflow, leaf_value_size(page, leaf.idx))
	}
	return data, .None
}
