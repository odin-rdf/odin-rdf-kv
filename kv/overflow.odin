package kv

import "core:mem"

/*
Values too large to store inline live in an overflow run: `n` contiguous
pages, the first starting with a Page_Header (flags PAGE_OVERFLOW,
overflow_count = n), followed by the value bytes. The leaf node stores the
run's first page number and the value's length.

Because the run is contiguous in the map, a value is returned as a single
zero-copy slice, and it is 16-byte aligned.
*/

// Writes `value` to a new overflow run and returns the run's first page.
@(private)
overflow_write :: proc(txn: ^Txn, value: []byte) -> (pgno: Pgno, err: Error) {
	n := overflow_pages(txn.env.page_size, len(value))
	buf: []byte
	pgno, buf = page_alloc(txn, n) or_return

	h := page_header(buf)
	h^ = {}
	h.pgno = u64le(pgno)
	h.flags = PAGE_OVERFLOW
	h.overflow_count = u32le(n)
	copy(buf[PAGE_HEADER_SIZE:], value)
	mem.zero_slice(buf[PAGE_HEADER_SIZE + len(value):])
	return pgno, .None
}

/*
Returns the value of `val_len` bytes stored in the overflow run starting at
`pgno`, after checking that the run is where the leaf says, is entirely
inside the snapshot, and has exactly the pages the value needs.
*/
@(private)
overflow_value :: proc(txn: ^Txn, pgno: Pgno, val_len: int) -> (value: []byte, err: Error) {
	count := overflow_check(txn, pgno, val_len) or_return
	start := PAGE_HEADER_SIZE
	if txn.write != nil {
		if buf, ok := txn.write.dirty[pgno]; ok {
			return buf[start:start + val_len], .None
		}
	}
	ps := txn.env.page_size
	off := int(pgno) * ps
	run := txn.env.map_base[off:off + count * ps]
	return run[start:start + val_len], .None
}

// Checks the header of the overflow run at `pgno` and returns its length in
// pages.
@(private)
overflow_check :: proc(txn: ^Txn, pgno: Pgno, val_len: int) -> (count: int, err: Error) {
	last := txn.snapshot.last_pgno
	if pgno < 2 || pgno > last {
		return 0, .Corrupted
	}
	ok: bool
	count, ok = run_header_check(page_ptr(txn, pgno), pgno, last, PAGE_OVERFLOW, val_len)
	return count, .None if ok else .Corrupted
}

// Checks the header on `first`, the first page of a run at `pgno` holding
// `size` bytes after its header: it records its own page number and exactly
// `flags`, and has the pages `size` needs plus at most `slack` more, all
// within `last`. Returns the run's length in pages. Shared by overflow runs
// (no slack) and the free-list run (see freelist_place).
@(private)
run_header_check :: proc(first: []byte, pgno, last: Pgno, flags: u16, size: int, slack := 0) -> (count: int, ok: bool) {
	h := page_header(first)
	if Pgno(h.pgno) != pgno || u16(h.flags) != flags {
		return 0, false
	}
	count = int(h.overflow_count)
	needed := overflow_pages(len(first), size)
	if count < needed || count > needed + slack || int(pgno) + count - 1 > int(last) {
		return 0, false
	}
	return count, true
}

// Drops the overflow run at `pgno` whose value is being replaced or removed.
// A run from the snapshot is recorded as freed; a run this transaction wrote
// is discarded and its pages recorded as loose.
@(private)
overflow_free :: proc(txn: ^Txn, pgno: Pgno, val_len: int) -> Error {
	count := overflow_check(txn, pgno, val_len) or_return
	list := &txn.write.freed
	if pgno in txn.write.dirty {
		delete_key(&txn.write.dirty, pgno)
		list = &txn.write.loose
	}
	for i in 0 ..< count {
		append(list, pgno + Pgno(i))
	}
	return .None
}
