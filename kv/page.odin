package kv

import "core:bytes"
import "core:mem"

/*
On-disk page layout (all integers little-endian):

	┌────────────────────────────────────────────┐
	│ Page_Header (16 bytes)                     │
	├────────────────────────────────────────────┤
	│ u16 slot offsets, sorted by key  →  lower  │
	│                                            │
	│               free space                   │
	│                                            │
	│ upper  ←  nodes, growing down from the end │
	└────────────────────────────────────────────┘

Overflow pages have no slots. The value bytes follow the header and continue
across `overflow_count` contiguous pages.
*/
Page_Header :: struct {
	pgno:      u64le,
	flags:     u16le,
	_reserved: u16le,
	using _: struct #raw_union {
		using _: struct {
			// Branch and leaf pages: end of the slot array.
			lower: u16le,
			// Branch and leaf pages: start of the node area.
			upper: u16le,
		},
		// Overflow pages: number of pages in the run, including this one.
		overflow_count: u32le,
	},
}

PAGE_HEADER_SIZE :: size_of(Page_Header)

#assert(size_of(Page_Header) == 16)
#assert(offset_of(Page_Header, pgno) == 0)
#assert(offset_of(Page_Header, flags) == 8)
#assert(offset_of(Page_Header, lower) == 12)
#assert(offset_of(Page_Header, upper) == 14)
#assert(offset_of(Page_Header, overflow_count) == 12)

// Size of one entry in the slot array.
SLOT_SIZE :: size_of(u16le)

// Nodes are packed back to back at arbitrary byte offsets, so their headers
// must not assume any alignment.

// A leaf node is followed by `key_len` key bytes, then either `val_len` value
// bytes or, with NODE_BIGDATA, a u64le page number of the overflow run.
Leaf_Node_Header :: struct #packed {
	key_len: u16le,
	flags:   u16le,
	val_len: u32le,
}

#assert(size_of(Leaf_Node_Header) == 8)
#assert(offset_of(Leaf_Node_Header, key_len) == 0)
#assert(offset_of(Leaf_Node_Header, flags) == 2)
#assert(offset_of(Leaf_Node_Header, val_len) == 4)

// A branch node is followed by `key_len` key bytes. The key in slot 0 is
// treated as −∞ and stored with length 0.
Branch_Node_Header :: struct #packed {
	child:   u64le,
	key_len: u16le,
}

#assert(size_of(Branch_Node_Header) == 10)
#assert(offset_of(Branch_Node_Header, child) == 0)
#assert(offset_of(Branch_Node_Header, key_len) == 8)

// Returns the header at the start of a page buffer. Pages in the map are
// page-aligned; any other page buffer must be allocated with at least
// `align_of(Page_Header)` alignment.
page_header :: #force_inline proc(page: []byte) -> ^Page_Header {
	when ODIN_DEBUG {
		assert(uintptr(raw_data(page)) % align_of(Page_Header) == 0, "misaligned page buffer")
	}
	return (^Page_Header)(raw_data(page))
}

// ---------------------------------------------------------------------------
// Size limits
//
// Every node plus its slot takes at most a quarter of a page's usable space,
// so any page holds at least 4 nodes and a split always leaves both halves
// room for the node being inserted.

// Largest node, excluding its slot, that may be stored on a page.
max_node_size :: proc "contextless" (page_size: int) -> int {
	return (page_size - PAGE_HEADER_SIZE) / 4 - SLOT_SIZE
}

// The largest per-node overhead: a leaf node whose value lives in an
// overflow run (header plus page number), vs. a branch node (header only).
@(private = "file")
MAX_NODE_OVERHEAD :: max(size_of(Branch_Node_Header), size_of(Leaf_Node_Header) + size_of(u64le))

// Longest key allowed for any page size, for sizing key buffers.
MAX_KEY_SIZE_ANY :: ((MAX_PAGE_SIZE - PAGE_HEADER_SIZE) / 4 - SLOT_SIZE - MAX_NODE_OVERHEAD) &~ 1

// Longest key allowed, rounded down to an even number: 1002 bytes for 4 KiB
// pages.
max_key_size :: proc "contextless" (page_size: int) -> int {
	return (max_node_size(page_size) - MAX_NODE_OVERHEAD) &~ 1
}

// A leaf node larger than this keeps its value in an overflow run instead.
overflow_threshold :: proc "contextless" (page_size: int) -> int {
	return max_node_size(page_size)
}

leaf_node_size :: proc "contextless" (key_len, val_len: int, bigdata: bool) -> int {
	return size_of(Leaf_Node_Header) + key_len + (size_of(u64le) if bigdata else val_len)
}

branch_node_size :: proc "contextless" (key_len: int) -> int {
	return size_of(Branch_Node_Header) + key_len
}

// Whether a key/value pair must store its value in overflow pages.
leaf_needs_overflow :: proc "contextless" (page_size, key_len, val_len: int) -> bool {
	return leaf_node_size(key_len, val_len, false) > overflow_threshold(page_size)
}

// ---------------------------------------------------------------------------
// Page access
//
// All procedures below work in place on a page buffer of exactly one page.
// They never allocate.

// Initialises an empty branch or leaf page. The whole buffer is zeroed so no
// stale bytes are ever written to disk.
page_init :: proc(page: []byte, pgno: Pgno, flags: u16) {
	mem.zero_slice(page)
	h := page_header(page)
	h.pgno = u64le(pgno)
	h.flags = u16le(flags)
	h.lower = PAGE_HEADER_SIZE
	h.upper = u16le(len(page))
}

page_is_leaf :: #force_inline proc(page: []byte) -> bool {
	return page_header(page).flags & PAGE_LEAF != 0
}

page_is_branch :: #force_inline proc(page: []byte) -> bool {
	return page_header(page).flags & PAGE_BRANCH != 0
}

page_num_keys :: #force_inline proc(page: []byte) -> int {
	return (int(page_header(page).lower) - PAGE_HEADER_SIZE) / SLOT_SIZE
}

page_free_space :: #force_inline proc(page: []byte) -> int {
	h := page_header(page)
	return int(h.upper) - int(h.lower)
}

// Bytes taken by nodes and slots.
page_used :: proc(page: []byte) -> int {
	h := page_header(page)
	return len(page) - int(h.upper) + int(h.lower) - PAGE_HEADER_SIZE
}

@(private = "file")
page_slots :: #force_inline proc(page: []byte) -> []u16le {
	// The slot array starts at offset 16 of an 8-aligned page, so u16
	// access is aligned.
	return ([^]u16le)(raw_data(page[PAGE_HEADER_SIZE:]))[:page_num_keys(page)]
}

@(private = "file")
Packed_U64le :: struct #packed {
	value: u64le,
}

// Size of the node at byte offset `off`, which depends on the page kind.
@(private = "file")
node_size_at :: proc(page: []byte, off: int, leaf: bool) -> int {
	if leaf {
		h := (^Leaf_Node_Header)(raw_data(page[off:off + size_of(Leaf_Node_Header)]))^
		return leaf_node_size(int(h.key_len), int(h.val_len), h.flags & NODE_BIGDATA != 0)
	}
	h := (^Branch_Node_Header)(raw_data(page[off:off + size_of(Branch_Node_Header)]))^
	return branch_node_size(int(h.key_len))
}

// The raw bytes of node `i`, header included.
node_bytes :: proc(page: []byte, i: int) -> []byte {
	off := int(page_slots(page)[i])
	return page[off:off + node_size_at(page, off, page_is_leaf(page))]
}

// The key of node `i`. On a branch page, slot 0's key is empty and stands
// for −∞.
node_key :: proc(page: []byte, i: int) -> []byte {
	off := int(page_slots(page)[i])
	if page_is_leaf(page) {
		h := (^Leaf_Node_Header)(raw_data(page[off:off + size_of(Leaf_Node_Header)]))^
		start := off + size_of(Leaf_Node_Header)
		return page[start:start + int(h.key_len)]
	}
	h := (^Branch_Node_Header)(raw_data(page[off:off + size_of(Branch_Node_Header)]))^
	start := off + size_of(Branch_Node_Header)
	return page[start:start + int(h.key_len)]
}

// The value of leaf node `i`: the value bytes if stored inline, or the first
// page of its overflow run (see leaf_value_size for its length).
leaf_value :: proc(page: []byte, i: int) -> (value: []byte, overflow: Pgno, bigdata: bool) {
	off := int(page_slots(page)[i])
	h := (^Leaf_Node_Header)(raw_data(page[off:off + size_of(Leaf_Node_Header)]))^
	start := off + size_of(Leaf_Node_Header) + int(h.key_len)
	if h.flags & NODE_BIGDATA != 0 {
		// At an arbitrary offset, so read through a packed struct.
		pgno := (^Packed_U64le)(raw_data(page[start:start + size_of(u64le)])).value
		return nil, Pgno(pgno), true
	}
	return page[start:start + int(h.val_len)], 0, false
}

// Length of leaf node `i`'s value, whether inline or in an overflow run.
leaf_value_size :: proc(page: []byte, i: int) -> int {
	off := int(page_slots(page)[i])
	h := (^Leaf_Node_Header)(raw_data(page[off:off + size_of(Leaf_Node_Header)]))^
	return int(h.val_len)
}

branch_child :: proc(page: []byte, i: int) -> Pgno {
	off := int(page_slots(page)[i])
	return Pgno((^Branch_Node_Header)(raw_data(page[off:off + size_of(Branch_Node_Header)])).child)
}

branch_set_child :: proc(page: []byte, i: int, child: Pgno) {
	off := int(page_slots(page)[i])
	(^Branch_Node_Header)(raw_data(page[off:off + size_of(Branch_Node_Header)])).child = u64le(child)
}

// ---------------------------------------------------------------------------
// Search

// Binary search in memcmp order. Returns the index of the first key ≥ `key`
// (num_keys if there is none), and whether that key is equal. On a branch
// page, slot 0 is −∞ and is never an exact match.
page_search :: proc(page: []byte, key: []byte) -> (idx: int, exact: bool) {
	n := page_num_keys(page)
	lo, hi := 0, n
	if page_is_branch(page) && n > 0 {
		lo = 1
	}
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if bytes.compare(node_key(page, mid), key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < n && bytes.compare(node_key(page, lo), key) == 0
}

// The slot of a branch page whose subtree may contain `key`: the last slot
// with a key ≤ `key`, counting slot 0 as −∞.
branch_find_child :: proc(page: []byte, key: []byte) -> int {
	assert(page_num_keys(page) > 0, "empty branch page")
	idx, exact := page_search(page, key)
	return idx if exact else idx - 1
}

// ---------------------------------------------------------------------------
// Insert and remove

// Makes room for a node of `size` bytes at slot `idx`, shifting later slots
// up. Returns the node's offset, or false (page unchanged) if it doesn't fit.
@(private = "file")
node_reserve :: proc(page: []byte, idx: int, size: int) -> (offset: int, ok: bool) {
	h := page_header(page)
	n := page_num_keys(page)
	assert(idx >= 0 && idx <= n, "slot index out of range")
	if int(h.upper) - int(h.lower) < size + SLOT_SIZE {
		return 0, false
	}
	offset = int(h.upper) - size
	h.upper = u16le(offset)
	h.lower += SLOT_SIZE
	slots := page_slots(page)
	copy(slots[idx + 1:], slots[idx:n])
	slots[idx] = u16le(offset)
	return offset, true
}

// Inserts a leaf node with an inline value at slot `idx`. Returns false,
// leaving the page unchanged, if it doesn't fit.
leaf_insert :: proc(page: []byte, idx: int, key, value: []byte) -> bool {
	assert(page_is_leaf(page))
	off := node_reserve(page, idx, leaf_node_size(len(key), len(value), false)) or_return
	(^Leaf_Node_Header)(raw_data(page[off:]))^ = {key_len = u16le(len(key)), val_len = u32le(len(value))}
	start := off + size_of(Leaf_Node_Header)
	copy(page[start:], key)
	copy(page[start + len(key):], value)
	return true
}

// Inserts a leaf node whose `val_len`-byte value lives in the overflow run
// starting at `overflow`.
leaf_insert_overflow :: proc(page: []byte, idx: int, key: []byte, overflow: Pgno, val_len: int) -> bool {
	assert(page_is_leaf(page))
	off := node_reserve(page, idx, leaf_node_size(len(key), val_len, true)) or_return
	(^Leaf_Node_Header)(raw_data(page[off:]))^ = {key_len = u16le(len(key)), flags = NODE_BIGDATA, val_len = u32le(val_len)}
	start := off + size_of(Leaf_Node_Header)
	copy(page[start:], key)
	(^Packed_U64le)(raw_data(page[start + len(key):])).value = u64le(overflow)
	return true
}

// Inserts a branch node at slot `idx`. The node at slot 0 must have an empty
// key.
branch_insert :: proc(page: []byte, idx: int, key: []byte, child: Pgno) -> bool {
	assert(page_is_branch(page))
	off := node_reserve(page, idx, branch_node_size(len(key))) or_return
	(^Branch_Node_Header)(raw_data(page[off:]))^ = {child = u64le(child), key_len = u16le(len(key))}
	copy(page[off + size_of(Branch_Node_Header):], key)
	return true
}

// Removes node `idx`. The nodes below it move up to close the gap, so the
// free space stays contiguous.
node_remove :: proc(page: []byte, idx: int) {
	h := page_header(page)
	slots := page_slots(page)
	n := len(slots)
	off := int(slots[idx])
	size := node_size_at(page, off, page_is_leaf(page))
	upper := int(h.upper)

	copy(page[upper + size:off + size], page[upper:off])
	mem.zero_slice(page[upper:upper + size])
	for &s in slots {
		if int(s) < off {
			s += u16le(size)
		}
	}
	copy(slots[idx:], slots[idx + 1:])
	slots[n - 1] = 0

	h.upper = u16le(upper + size)
	h.lower -= SLOT_SIZE
}

// Appends a raw node (header included) after the last slot.
@(private = "file")
node_append_raw :: proc(page: []byte, node: []byte) {
	off, ok := node_reserve(page, page_num_keys(page), len(node))
	assert(ok, "node does not fit")
	copy(page[off:], node)
}

// ---------------------------------------------------------------------------
// Split

// Size of virtual node `v`, including its slot, in the sequence formed by
// inserting a node of `insert_size` bytes at `insert_idx`.
@(private = "file")
virtual_node_size :: proc(page: []byte, insert_idx, insert_size, v: int, leaf: bool) -> int {
	if v == insert_idx {
		return insert_size + SLOT_SIZE
	}
	i := v if v < insert_idx else v - 1
	return node_size_at(page, int(page_slots(page)[i]), leaf) + SLOT_SIZE
}

/*
Chooses where to split a full page that must take one more node.

Consider the page's nodes with the new node (`insert_size` bytes, excluding
its slot) inserted at `insert_idx`: n + 1 nodes, indexed 0..=n. The result `s`
is in [1, n]: nodes 0..<s go to the left page and s..=n to the right one,
split so the two halves are as close in bytes as possible.

With the new node in the sequence, real node i is at virtual index i if
i < insert_idx, else i + 1. So the real nodes that move right start at
`s - 1` if insert_idx < s (the new node goes left), otherwise at `s`.
*/
split_point :: proc(page: []byte, insert_idx: int, insert_size: int) -> int {
	n := page_num_keys(page)
	assert(n >= 1, "cannot split an empty page")
	assert(insert_idx >= 0 && insert_idx <= n)
	leaf := page_is_leaf(page)

	total := page_used(page) + insert_size + SLOT_SIZE
	left := 0
	split := n
	for v in 0 ..= n {
		size := virtual_node_size(page, insert_idx, insert_size, v, leaf)
		if 2 * (left + size) > total {
			// Node v crosses the midpoint: keep it on whichever side leaves
			// the halves closer in size.
			split = v + 1 if 2 * (left + size) - total < total - 2 * left else v
			break
		}
		left += size
	}
	return clamp(split, 1, n)
}

// A page-sized buffer for rebuilding a page in place.
@(private = "file")
Page_Scratch :: struct #align(16) {
	bytes: [MAX_PAGE_SIZE]byte,
}

// Moves nodes from_idx..<n of `src` to `dst`, which must be an empty page
// of the same kind. Both pages end up compacted.
page_move_upper :: proc(src, dst: []byte, from_idx: int) {
	n := page_num_keys(src)
	assert(len(dst) == len(src) && page_num_keys(dst) == 0, "destination must be an empty page of the same size")
	assert(page_is_leaf(src) == page_is_leaf(dst), "pages must be of the same kind")
	assert(from_idx >= 0 && from_idx <= n)

	// Rebuilding from a copy is a single pass over the page, however the
	// nodes to keep are scattered. The copy stays on the stack (at most 32 KiB).
	scratch: Page_Scratch = ---
	orig := scratch.bytes[:len(src)]
	copy(orig, src)

	h := page_header(src)
	page_init(src, Pgno(h.pgno), u16(h.flags))
	for i in 0 ..< n {
		node_append_raw(src if i < from_idx else dst, node_bytes(orig, i))
	}
}

// ---------------------------------------------------------------------------
// Invariant checking

/*
Checks the structure of a branch or leaf page: header fields, slot offsets
inside the node area, nodes tiling that area with no gaps or overlaps, node
size limits, node flags, branch slot 0 being −∞, and keys strictly
increasing. Meant for debug builds and tests.
*/
page_check :: proc(page: []byte) -> (ok: bool, reason: string) {
	if !page_size_valid(len(page)) {
		return false, "invalid page size"
	}
	h := page_header(page)
	flags := u16(h.flags)
	if flags != PAGE_LEAF && flags != PAGE_BRANCH {
		return false, "not a branch or leaf page"
	}
	leaf := flags == PAGE_LEAF
	lower, upper := int(h.lower), int(h.upper)
	if lower < PAGE_HEADER_SIZE || (lower - PAGE_HEADER_SIZE) % SLOT_SIZE != 0 || lower > upper || upper > len(page) {
		return false, "bad lower/upper"
	}
	n := page_num_keys(page)
	if !leaf && n == 0 {
		return false, "empty branch page"
	}

	// One bit per byte of the page, to detect overlapping nodes.
	used: [MAX_PAGE_SIZE / 8]u8
	covered := 0
	header_size := size_of(Leaf_Node_Header) if leaf else size_of(Branch_Node_Header)
	for s, i in page_slots(page) {
		off := int(s)
		if off < upper || off + header_size > len(page) {
			return false, "slot offset outside the node area"
		}
		size := node_size_at(page, off, leaf)
		if off + size > len(page) {
			return false, "node extends past the end of the page"
		}
		if size > max_node_size(len(page)) {
			return false, "node larger than max_node_size"
		}
		for b in off ..< off + size {
			if used[b / 8] & (1 << uint(b % 8)) != 0 {
				return false, "overlapping nodes"
			}
			used[b / 8] |= 1 << uint(b % 8)
		}
		covered += size

		if leaf {
			nh := (^Leaf_Node_Header)(raw_data(page[off:]))^
			if nh.flags & ~u16le(NODE_BIGDATA) != 0 {
				return false, "unknown leaf node flags"
			}
		} else if i == 0 && len(node_key(page, 0)) != 0 {
			return false, "branch slot 0 must have an empty key"
		}

		first_ordered := 1 if leaf else 2
		if i >= first_ordered && bytes.compare(node_key(page, i - 1), node_key(page, i)) >= 0 {
			return false, "keys not strictly increasing"
		}
	}
	if covered != len(page) - upper {
		return false, "gap in the node area"
	}
	return true, ""
}
