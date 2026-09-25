package kv

import "core:mem/virtual"
import "core:slice"
import "core:sync"

/*
Makes the transaction's changes durable and visible to new transactions,
then ends it. The steps are ordered so that a crash at any point leaves the
previous commit intact:

1. Build the new free list and allocate a run for it (see freelist.odin),
   in reusable pages if a run of them fits, otherwise at the end of the
   file.
2. Grow the file if needed, write the free-list run a page at a time, and
   write every page still dirty in the pool. Pages spilled earlier in the
   transaction, overflow runs included, are in the file already. No
   committed meta page refers to any of them: they are new pages, or
   reused ones that were freed before the snapshot the transaction began
   from (whose meta page stays intact) and that no live reader can see.
3. Sync, so the pages, spilled ones included, are on disk before anything
   points at them.
4. Write the meta page for txn_id + 1 into the slot the previous commit
   didn't use, then sync it.
5. Publish the new snapshot to transactions that begin from now on, and
   replace the env's free list.

On failure the transaction is aborted and the error returned; the database
and the env's free list stay at the previous commit, including the pages
the transaction took from it. Map_Full here means the free list's run fit
neither in reusable pages nor in the map (KV-I-0002 D6). Pages spilled
before the failure, or before an abort, are left in the file as they are:
they are free pages of the previous commit, or past its last page, so
nothing refers to them.

A failure before the first sync (growing the file, writing the free-list
run or a data page) leaves only such pages written, and the env can take
the next write transaction as if this one had been aborted.

A failure of the first sync, of the meta-page write (a partial write
included) or of the final sync poisons the env (KV-I-0005 D7): every later
txn_begin(rw) returns Poisoned until env_close. After a failed meta-page
write or final sync, the new meta page may or may not be in the file, and
may or may not be durable; if it is, it points at pages this process still
counts as free, and the next write transaction would overwrite them. After
a failed first sync, the OS may have dropped pages it couldn't write, so
the file can no longer be vouched for either. Read transactions carry on
at the previous commit, which this process keeps, and env_stats reports
the flag. Reopening the file recovers: env_open sees the failed commit if
its meta page is durable and whole, otherwise the previous one.

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
	// Changes are counted, not dirty pages: a delete that empties the tree
	// frees every page it copied, and leaves none dirty.
	if txn.mods == 0 && len(txn.write.dirty) == 0 {
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
	run, run_pages := freelist_place(txn, &next) or_return
	snap.freelist_pgno, snap.freelist_count = run, u64(free_state_count(next))

	file_grow(env, (i64(snap.last_pgno) + 1) * ps) or_return
	if run_pages > 0 {
		// The run needs one slot. Spilling for it costs no extra writes:
		// every dirty page is written below anyway.
		pool_make_room(txn, 1) or_return
		freelist_write(txn, run, run_pages, next) or_return
	}

	// Write in page order: cheap to do, and it gives the OS sequential I/O.
	pgnos := make([]Pgno, len(txn.write.dirty), virtual.arena_allocator(&txn.write.arena))
	i := 0
	for pgno in txn.write.dirty {
		pgnos[i] = pgno
		i += 1
	}
	slice.sort(pgnos)
	for pgno in pgnos {
		d := txn.write.dirty[pgno]
		os_pwrite(env.fd, pool_pages(&env.pool, d.slot, d.pages), i64(pgno) * ps) or_return
	}
	// One sync covers every page written in the transaction, spilled ones
	// included: they were written to the same file. From here on a failure
	// poisons the env (D7).
	if err = os_sync(env.fd); err != .None {
		return commit_poison(env, err)
	}

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
	if err = meta_write(env, int(snap.txn_id & 1), meta); err != .None {
		return commit_poison(env, err)
	}
	if err = os_sync(env.fd); err != .None {
		return commit_poison(env, err)
	}

	// Still under writer_mutex, which the transaction holds until it ends.
	free_state_destroy(&env.free)
	env.free = next
	sync.mutex_lock(&env.snapshot_mutex)
	env.snapshot = snap^
	stats_set_free(env)
	sync.mutex_unlock(&env.snapshot_mutex)
	return .None
}

/*
Marks the env poisoned after a failure of the commit's first sync, its
meta-page write or its final sync, and returns `err` (KV-I-0005 D7). The
caller holds writer_mutex.
*/
@(private = "file")
commit_poison :: proc(env: ^Env, err: Error) -> Error {
	sync.atomic_store(&env.poisoned, true)
	return err
}
