package kv

import "core:mem/virtual"
import "core:sync"

/*
A transaction sees the snapshot that was committed when it began, however
many commits happen after that. A write transaction also sees its own
changes.

A Txn is a value: begin it into a variable and end it through a pointer to
that same variable.

	txn := kv.txn_begin(env) or_return
	defer kv.txn_abort(&txn)

Only one write transaction exists at a time; beginning a second one blocks
until the first ends, so a thread must not begin two.
*/
Txn :: struct {
	env:       ^Env,
	// Read transactions: the snapshot they began from. Write transactions:
	// the working state, which becomes the new snapshot on commit.
	snapshot:  Snapshot,
	read_only: bool,
	// Set once the transaction has ended; further use is a bug.
	done:      bool,
	// Bumped when the transaction ends. Cursors compare it against the value
	// they saw when opened, to catch use after the end in debug builds.
	gen:       u32,
	// Bumped by every change in a write transaction, invalidating cursors.
	mods:      u32,
	// Set when a change failed part-way; every later call returns it, and
	// the transaction can only be aborted.
	err:       Error,
	// Write transactions only. Kept on the heap so that the arena, and the
	// allocator pointing at it, don't move when the Txn value does.
	write:     ^Write_State,
}

Write_State :: struct {
	// Owns the dirty map and the page lists. The dirty pages themselves are
	// in Env.pool.
	arena: virtual.Arena,
	// Pages written by this transaction and held in the pool, by page
	// number: the slot holding each. A run allocated in one piece is stored
	// under its first page number, in consecutive slots.
	dirty: map[Pgno]Dirty_Page,
	// Pages written by this transaction that are already in the file, not
	// in the pool: dirty pages that were spilled, and overflow runs, which
	// are written directly (KV-I-0004 D4, D5). By first page number, with
	// the length in pages. A page is in `dirty` or `spilled`, never both.
	// They are the transaction's own pages like dirty ones: touching one
	// copies it back into the pool under the same number, and freeing one
	// makes it loose.
	spilled: map[Pgno]u32,
	// Set while put or del changes the tree. Spilling then would free slots
	// the operation still holds slices into, so pool_make_room refuses to
	// (KV-I-0004 D2).
	in_op:   bool,
	// Pages of the snapshot that this transaction replaced. The commit puts
	// them on the free list, tagged with its own txn_id.
	freed: [dynamic]Pgno,
	// Pages this transaction allocated and then dropped again (a replaced
	// overflow run). No reader ever saw them, so page_alloc hands them out
	// again first, and the commit puts the rest on the free list as
	// reusable.
	loose: [dynamic]Pgno,
	// The reuse horizon, computed once when the transaction began: pages
	// freed by a transaction ≤ oldest are reusable. It is the oldest
	// snapshot a live reader holds, or the snapshot before the one this
	// transaction began from if that is older (KV-I-0002 D1, D4).
	oldest: Txn_Id,
	// The pages this transaction took from Env.free.ready, which isn't
	// changed until the commit is durable: every page before index
	// `ready_next` (single pages, taken in order), and the pages in
	// `taken`, sorted (runs, taken from anywhere after it). `ready_taken`
	// counts them both.
	ready_next:  int,
	taken:       [dynamic]Pgno,
	ready_taken: int,
	// What earlier run searches of Env.free.ready proved, so that later
	// ones don't scan it again (KV-T-0015). The list doesn't change during
	// the transaction and pages are only taken from it, so a proof stays
	// true:
	// - `run_from[n]`: a search skipping nothing found its run of n at this
	//   index, so no run of n or more starts before it. The run search's
	//   counterpart of ready_next, for n in 2 ..= RUN_HINTS.
	// - `miss`: the shortest length a search skipping nothing found no run
	//   of, so none is left of that length or more. 0: none yet.
	// - `miss_skipped`: the same for a search skipping `miss_skip` pages,
	//   which rules out every search skipping at least as many.
	run_from:     [RUN_HINTS + 1]int,
	miss:         int,
	miss_skipped: int,
	miss_skip:    int,
}

// Run lengths for which Write_State remembers where to start searching.
// Longer runs start from the entry for the longest length below them.
RUN_HINTS :: 8

// Begins a transaction. Read-only transactions never block and are never
// blocked by the writer. A read transaction holds its snapshot in the
// reader table until it ends; one that is never ended pins it forever.
txn_begin :: proc(env: ^Env, read_only := true) -> (txn: Txn, err: Error) {
	if !read_only {
		sync.mutex_lock(&env.writer_mutex)
		w, alloc_err := new(Write_State, env.allocator)
		if alloc_err != nil {
			sync.mutex_unlock(&env.writer_mutex)
			return {}, .Out_Of_Memory
		}
		arena := virtual.arena_allocator(&w.arena)
		w.dirty = make(map[Pgno]Dirty_Page, arena)
		w.spilled = make(map[Pgno]u32, arena)
		w.freed = make([dynamic]Pgno, arena)
		w.loose = make([dynamic]Pgno, arena)
		w.taken = make([dynamic]Pgno, arena)
		txn.write = w
	}

	// A reader registers its snapshot under the same lock that copies it, so
	// a writer computing the oldest reader can't miss it: the snapshot is
	// either still the latest one or already in the table.
	sync.mutex_lock(&env.snapshot_mutex)
	txn.snapshot = env.snapshot
	if read_only {
		if reg_err := reader_register(env, txn.snapshot.txn_id); reg_err != .None {
			sync.mutex_unlock(&env.snapshot_mutex)
			return {}, reg_err
		}
	} else {
		txn.write.oldest = reuse_horizon(env, txn.snapshot.txn_id)
	}
	sync.mutex_unlock(&env.snapshot_mutex)

	if !read_only {
		// Pages that became reusable since the last commit move to `ready`.
		// Whatever the transaction does later, that stays true, so it is
		// done in place rather than at commit.
		w := txn.write
		n_ready := len(env.free.ready)
		if rel_err := freelist_release(&env.free, w.oldest, virtual.arena_allocator(&w.arena)); rel_err != .None {
			virtual.arena_destroy(&w.arena)
			free(w, env.allocator)
			sync.mutex_unlock(&env.writer_mutex)
			return {}, rel_err
		}
		if len(env.free.ready) != n_ready {
			stats_update_free(env)
		}
	}

	txn.env = env
	txn.read_only = read_only
	sync.atomic_add(&env.active_txns, 1)
	return txn, .None
}

/*
Returns the reuse horizon for a write transaction beginning from snapshot
`s`: the oldest snapshot a live reader holds, or s − 1 if that is older.
Pages freed by a transaction ≤ the horizon are in no snapshot anyone can
still read. Keeping s − 1 intact is KV-I-0002 D1: the meta page the next
commit overwrites still holds it, and env_open falls back to it if meta
page s is ever unreadable. The caller holds snapshot_mutex.
*/
@(private = "file")
reuse_horizon :: proc(env: ^Env, s: Txn_Id) -> Txn_Id {
	// Nothing is tagged 0, so an empty database's horizon can be 0.
	oldest := s - 1 if s > 0 else 0
	if reader, ok := oldest_reader(env); ok {
		oldest = min(oldest, reader)
	}
	return oldest
}

// Ends the transaction, discarding any changes. Safe to call more than once,
// and after txn_commit. Every transaction ends here (txn_commit too), so this
// is also where the store evicts mapped pages when it is over its budget
// (see chunks_txn_end).
txn_abort :: proc(txn: ^Txn) {
	if txn.done || txn.env == nil {
		return
	}
	txn.done = true
	txn.gen += 1
	if txn.write != nil {
		write_state_free(txn)
		sync.mutex_unlock(&txn.env.writer_mutex)
	}
	if txn.read_only {
		sync.mutex_lock(&txn.env.snapshot_mutex)
		reader_deregister(txn.env, txn.snapshot.txn_id)
		sync.mutex_unlock(&txn.env.snapshot_mutex)
	}
	// With nothing held any more, so that eviction holds up neither the
	// writer nor the reader table (KV-I-0004 D8).
	chunks_txn_end(txn.env)
	sync.atomic_sub(&txn.env.active_txns, 1)
}

// Frees the write transaction's state and releases the pool's memory.
@(private)
write_state_free :: proc(txn: ^Txn) {
	pool_release(&txn.env.pool)
	virtual.arena_destroy(&txn.write.arena)
	free(txn.write, txn.env.allocator)
	txn.write = nil
}

// Returns page `pgno` as seen by the transaction: this transaction's copy in
// the pool if it holds the page dirty, otherwise the page in the map (a
// committed page, or one this transaction spilled). This is the only way the
// rest of the package reaches a page. A page returned from the map has its
// chunk accounted as read (see chunks.odin); a dirty page counts nothing.
page_ptr :: #force_inline proc(txn: ^Txn, pgno: Pgno) -> []byte {
	when ODIN_DEBUG {
		assert(!txn.done, "transaction already ended")
		assert(pgno <= txn.snapshot.last_pgno, "page number past the end of the snapshot")
	}
	ps := txn.env.page_size
	if txn.write != nil {
		if d, ok := txn.write.dirty[pgno]; ok {
			return pool_pages(&txn.env.pool, d.slot, 1)
		}
	}
	// The map's base is read before the accounting, whose slow path is a
	// call, so that the fast path doesn't read it again after.
	env := txn.env
	base := env.map_base
	off := int(pgno) * ps
	chunk_touch(env, off)
	return base[off:off + ps]
}
