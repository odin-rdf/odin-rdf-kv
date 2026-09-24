package kv

import "core:mem"

/*
Values too large to store inline live in an overflow run: `n` contiguous
pages, the first starting with a Page_Header (flags PAGE_OVERFLOW,
overflow_count = n), followed by the value bytes. The leaf node stores the
run's first page number and the value's length.

Because the run is contiguous in the map, a value is returned as a single
zero-copy slice, and it is 16-byte aligned.

A write transaction writes a new run straight to the file rather than
holding it in the dirty-page pool (KV-I-0004 D5), so a value of any size
needs one slot of the pool, briefly. The run is then one of the
transaction's spilled pages, read through the map like any other.
*/

/*
Writes `value` to a new overflow run and returns the run's first page. The
first page (the header and the start of the value) and the last page (the
end of the value, zero-padded) are staged in one pool slot; the whole pages
between them are written from `value` itself. The run is recorded in
Write_State.spilled. See spill in pool.odin for why writing a page this
transaction allocated before the commit is safe.
*/
@(private)
overflow_write :: proc(txn: ^Txn, value: []byte) -> (pgno: Pgno, err: Error) {
	env := txn.env
	ps := env.page_size
	n := overflow_pages(ps, len(value))
	slot := pool_alloc(&env.pool, 1, txn.mods) or_return
	defer pool_free(&env.pool, slot, 1)
	pgno = page_take(txn, n) or_return
	file_grow(env, (i64(pgno) + i64(n)) * i64(ps)) or_return
	at := i64(pgno) * i64(ps)

	buf := pool_pages(&env.pool, slot, 1)
	h := page_header(buf)
	h^ = {}
	h.pgno = u64le(pgno)
	h.flags = PAGE_OVERFLOW
	h.overflow_count = u32le(n)
	head := copy(buf[PAGE_HEADER_SIZE:], value)
	mem.zero_slice(buf[PAGE_HEADER_SIZE + head:])
	os_pwrite(env.fd, buf, at) or_return

	rest := value[head:]
	whole := len(rest) / ps * ps
	if whole > 0 {
		os_pwrite(env.fd, rest[:whole], at + i64(ps)) or_return
	}
	if tail := rest[whole:]; len(tail) > 0 {
		copy(buf, tail)
		mem.zero_slice(buf[len(tail):])
		os_pwrite(env.fd, buf, at + i64(ps) + i64(whole)) or_return
	}
	txn.write.spilled[pgno] = u32(n)
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
	// A run is never in the pool: overflow_write writes it to the file.
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
// (in Write_State.spilled) is discarded and its pages recorded as loose.
@(private)
overflow_free :: proc(txn: ^Txn, pgno: Pgno, val_len: int) -> Error {
	count := overflow_check(txn, pgno, val_len) or_return
	page_free(txn, pgno, count)
	return .None
}
