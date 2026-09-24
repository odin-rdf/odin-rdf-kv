/*
Package kv is an embedded, memory-mapped key/value store modelled on LMDB.

Data lives in a single file as a copy-on-write B+tree. Reads are zero-copy:
returned slices point straight into a read-only mapping of the file.
*/
package kv

// Page offsets are computed and sliced with `int`, and the whole database is
// mapped into the address space, so only 64-bit targets are supported.
#assert(size_of(int) == 8, "kv requires a 64-bit target")

// Page number: the index of a page within the database file.
Pgno :: distinct u64

// Transaction id. Every commit produces the next id.
Txn_Id :: distinct u64

Error :: enum u8 {
	None,
	Not_Found,
	Map_Full,
	Key_Too_Large,
	Corrupted,
	Io,
	Txn_Read_Only,
	// Another handle (in this or another process) holds the database lock.
	Locked,
	// An option or argument is out of range, such as an invalid page size.
	Invalid_Argument,
	// Memory couldn't be allocated: for a write transaction's dirty pages,
	// or for the environment or its reader table.
	Out_Of_Memory,
}

// "ODKV" when read as bytes from the start of the meta struct.
MAGIC   :: 0x564B_444F
VERSION :: 1

DEFAULT_PAGE_SIZE :: 4096
// Page sizes are powers of two in this range. The upper bound comes from the
// u16 slot offsets and `upper` field in the page header.
MIN_PAGE_SIZE :: 4096
MAX_PAGE_SIZE :: 32768

// Page_Header.flags
PAGE_BRANCH   :: 0x01
PAGE_LEAF     :: 0x02
PAGE_OVERFLOW :: 0x04
PAGE_META     :: 0x08
// The first page of the free-list run (see freelist.odin).
PAGE_FREELIST :: 0x10

// Leaf_Node_Header.flags: the value lives in an overflow run and the node
// stores its first page number instead of the value bytes.
NODE_BIGDATA :: 0x01

page_size_valid :: proc "contextless" (page_size: int) -> bool {
	return page_size >= MIN_PAGE_SIZE && page_size <= MAX_PAGE_SIZE && page_size & (page_size - 1) == 0
}
