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
	// Owns every dirty page buffer, the dirty map and the freed list.
	arena: virtual.Arena,
	// Pages written by this transaction, by page number. An overflow run is
	// stored as one buffer under its first page number.
	dirty: map[Pgno][]byte,
	// Pages of the snapshot that this transaction replaced. Page reuse
	// (step 5) will put them on the free list at commit.
	freed: [dynamic]Pgno,
	// Pages this transaction allocated and then dropped again (a replaced
	// overflow run). No reader ever saw them, so step 5 can reuse them
	// immediately.
	loose: [dynamic]Pgno,
}

// Begins a transaction. Read-only transactions never block and are never
// blocked by the writer.
txn_begin :: proc(env: ^Env, read_only := true) -> (txn: Txn, err: Error) {
	if !read_only {
		sync.mutex_lock(&env.writer_mutex)
		w, alloc_err := new(Write_State, env.allocator)
		if alloc_err != nil {
			sync.mutex_unlock(&env.writer_mutex)
			return {}, .Out_Of_Memory
		}
		arena := virtual.arena_allocator(&w.arena)
		w.dirty = make(map[Pgno][]byte, arena)
		w.freed = make([dynamic]Pgno, arena)
		w.loose = make([dynamic]Pgno, arena)
		txn.write = w
	}

	// Page reuse (step 5) will also register the snapshot's txn_id in the
	// reader table here, under the same lock, so that a writer computing the
	// oldest reader can't miss this one.
	sync.mutex_lock(&env.snapshot_mutex)
	txn.snapshot = env.snapshot
	sync.mutex_unlock(&env.snapshot_mutex)

	txn.env = env
	txn.read_only = read_only
	sync.atomic_add(&env.active_txns, 1)
	return txn, .None
}

// Ends the transaction, discarding any changes. Safe to call more than once,
// and after txn_commit.
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
	sync.atomic_sub(&txn.env.active_txns, 1)
}

@(private)
write_state_free :: proc(txn: ^Txn) {
	virtual.arena_destroy(&txn.write.arena)
	free(txn.write, txn.env.allocator)
	txn.write = nil
}

// Returns page `pgno` as seen by the transaction: this transaction's copy if
// it has written the page, otherwise the committed page in the map. This is
// the only way the rest of the package reaches a page.
page_ptr :: #force_inline proc(txn: ^Txn, pgno: Pgno) -> []byte {
	when ODIN_DEBUG {
		assert(!txn.done, "transaction already ended")
		assert(pgno <= txn.snapshot.last_pgno, "page number past the end of the snapshot")
	}
	ps := txn.env.page_size
	if txn.write != nil {
		if buf, ok := txn.write.dirty[pgno]; ok {
			return buf[:ps]
		}
	}
	// The memory budget (step 6) hooks residency accounting in here.
	off := int(pgno) * ps
	return txn.env.map_base[off:off + ps]
}
