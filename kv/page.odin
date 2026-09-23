package kv

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
