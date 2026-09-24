package kv

import "core:hash/xxhash"
import "core:mem"

/*
Pages 0 and 1 are meta pages: a Page_Header with PAGE_META followed by a Meta.
Commits alternate between them, and the valid one with the highest `txn_id`
describes the current state of the database.
*/
Meta :: struct {
	magic:     u32le,
	version:   u32le,
	page_size: u32le,
	flags:     u32le,

	txn_id:    u64le,
	// Root page of the tree, or 0 for an empty tree.
	root:      u64le,
	depth:     u32le,
	_reserved: u32le,

	entries:   u64le,
	// Highest page number in use.
	last_pgno: u64le,

	// First page of the free-list run and the number of records in it, or
	// both 0 for an empty free list (see freelist.odin).
	freelist_pgno:  u64le,
	freelist_count: u64le,

	// xxHash64 of every byte before this field.
	checksum:  u64le,
}

META_OFFSET :: PAGE_HEADER_SIZE

#assert(size_of(Meta) == 80)
#assert(offset_of(Meta, txn_id) == 16)
#assert(offset_of(Meta, root) == 24)
#assert(offset_of(Meta, depth) == 32)
#assert(offset_of(Meta, entries) == 40)
#assert(offset_of(Meta, last_pgno) == 48)
#assert(offset_of(Meta, freelist_pgno) == 56)
#assert(offset_of(Meta, freelist_count) == 64)
#assert(offset_of(Meta, checksum) == 72)
#assert(META_OFFSET % align_of(Meta) == 0)

meta_checksum :: proc(m: ^Meta) -> u64 {
	bytes := mem.byte_slice(m, offset_of(Meta, checksum))
	return u64(xxhash.XXH64(bytes))
}

// Returns the meta struct stored in a meta page buffer. The buffer must be
// aligned as for `page_header`.
page_meta :: #force_inline proc(page: []byte) -> ^Meta {
	when ODIN_DEBUG {
		assert(uintptr(raw_data(page)) % align_of(Meta) == 0, "misaligned page buffer")
	}
	return (^Meta)(raw_data(page[META_OFFSET:]))
}
