package kv

import "core:mem/virtual"
import "core:slice"
import "core:sync"

// The file grows by at least this much at a time, or by an eighth of its
// size if that is more, so that commits rarely need to resize it.
FILE_GROWTH_MIN :: 1 << 20

/*
Makes the transaction's changes durable and visible to new transactions,
then ends it. The steps are ordered so that a crash at any point leaves the
previous commit intact:

1. Build the new free list and allocate a run for it (see freelist.odin),
   in reusable pages if a run of them fits, otherwise at the end of the
   file.
2. Grow the file if needed and write every dirty page, the run included.
   No committed meta page refers to any of them: they are new pages, or
   reused ones that were freed before the snapshot the transaction began
   from (whose meta page stays intact) and that no live reader can see.
3. Sync, so the pages are on disk before anything points at them.
4. Write the meta page for txn_id + 1 into the slot the previous commit
   didn't use, then sync it.
5. Publish the new snapshot to transactions that begin from now on, and
   replace the env's free list.

On failure the transaction is aborted and the error returned; the database
and the env's free list stay at the previous commit, including the pages
the transaction took from it. Map_Full here means the free list's run fit
neither in reusable pages nor in the map (KV-I-0002 D6). If only the final
sync fails, the new meta page may or may not have reached the disk: the
next open sees whichever state is durable, and this process keeps the
previous one.

Committing a read-only transaction, or a write transaction that changed
nothing, just ends it. Committing a transaction that failed part-way returns
that failure.
*/
txn_commit :: proc(txn: ^Txn) -> (err: Error) {
	if txn.done || txn.env == nil {
		return .None
	}
	defer txn_abort(txn)

	if txn.write == nil {
		return .None
	}
	if txn.err != .None {
		return txn.err
	}
	if len(txn.write.dirty) == 0 {
		return .None
	}

	env := txn.env
	snap := &txn.snapshot
	ps := i64(env.page_size)

	// The free list is built outside Env.free, which only changes once the
	// commit is durable. Its run is allocated last, so nothing it lists can
	// change after it is written.
	next := freelist_build(txn) or_return
	defer if err != .None {
		free_state_destroy(&next)
	}
	run, run_pages, run_buf := freelist_place(txn, &next) or_return
	if run_pages > 0 {
		freelist_write(run_buf, run, run_pages, next)
	}
	snap.freelist_pgno, snap.freelist_count = run, u64(free_state_count(next))

	file_grow(env, (i64(snap.last_pgno) + 1) * ps) or_return

	// Write in page order: cheap to do, and it gives the OS sequential I/O.
	pgnos := make([]Pgno, len(txn.write.dirty), virtual.arena_allocator(&txn.write.arena))
	i := 0
	for pgno in txn.write.dirty {
		pgnos[i] = pgno
		i += 1
	}
	slice.sort(pgnos)
	for pgno in pgnos {
		os_pwrite(env.fd, txn.write.dirty[pgno], i64(pgno) * ps) or_return
	}
	os_sync(env.fd) or_return

	snap.txn_id += 1
	meta := Meta {
		magic          = MAGIC,
		version        = VERSION,
		page_size      = u32le(env.page_size),
		txn_id         = u64le(snap.txn_id),
		root           = u64le(snap.root),
		depth          = u32le(snap.depth),
		entries        = u64le(snap.entries),
		last_pgno      = u64le(snap.last_pgno),
		freelist_pgno  = u64le(snap.freelist_pgno),
		freelist_count = u64le(snap.freelist_count),
	}
	meta_write(env, int(snap.txn_id & 1), meta) or_return
	os_sync(env.fd) or_return

	// Still under writer_mutex, which the transaction holds until it ends.
	free_state_destroy(&env.free)
	env.free = next
	sync.mutex_lock(&env.snapshot_mutex)
	env.snapshot = snap^
	env.stats.free_ready = len(next.ready)
	env.stats.free_pending = len(next.pending)
	sync.mutex_unlock(&env.snapshot_mutex)
	return .None
}

// Grows the file to at least `needed` bytes, in steps of at least
// FILE_GROWTH_MIN or an eighth of its size, without exceeding the map.
@(private = "file")
file_grow :: proc(env: ^Env, needed: i64) -> Error {
	if needed <= env.file_size {
		return .None
	}
	step := max(FILE_GROWTH_MIN, env.file_size / 8)
	size := max(needed, env.file_size + step)
	size = min(size, i64(env.map_size))
	size = (size + i64(env.page_size) - 1) / i64(env.page_size) * i64(env.page_size)
	assert(size >= needed, "commit past the end of the map")

	os_truncate(env.fd, size) or_return
	env.file_size = size
	sync.mutex_lock(&env.snapshot_mutex)
	env.stats.file_pages = int(size) / env.page_size
	sync.mutex_unlock(&env.snapshot_mutex)
	return .None
}
