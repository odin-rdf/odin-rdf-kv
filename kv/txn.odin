package kv

import "core:sync"

/*
A transaction sees the snapshot that was committed when it began, however
many commits happen after that.

A Txn is a value: begin it into a variable and end it through a pointer to
that same variable. Don't copy it while it's in use.

	txn := kv.txn_begin(env) or_return
	defer kv.txn_abort(&txn)
*/
Txn :: struct {
	env:       ^Env,
	snapshot:  Snapshot,
	read_only: bool,
	// Set once the transaction has ended; further use is a bug.
	done:      bool,
	// Bumped when the transaction ends. Cursors compare it against the value
	// they saw when opened, to catch use after the end in debug builds.
	gen:       u32,
}

// Begins a transaction. Read-only transactions never block and are never
// blocked by the writer.
txn_begin :: proc(env: ^Env, read_only := true) -> (txn: Txn, err: Error) {
	assert(read_only, "write transactions are not implemented yet")

	// Page reuse (step 5) will also register the snapshot's txn_id in the
	// reader table here, under the same lock, so that a writer computing the
	// oldest reader can't miss this one.
	sync.mutex_lock(&env.snapshot_mutex)
	txn.snapshot = env.snapshot
	sync.mutex_unlock(&env.snapshot_mutex)

	txn.env = env
	txn.read_only = true
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
	sync.atomic_sub(&txn.env.active_txns, 1)
}

// Returns page `pgno` as seen by the transaction. This is the only way the
// rest of the package reaches a page.
page_ptr :: #force_inline proc(txn: ^Txn, pgno: Pgno) -> []byte {
	when ODIN_DEBUG {
		assert(!txn.done, "transaction already ended")
		assert(pgno <= txn.snapshot.last_pgno, "page number past the end of the snapshot")
	}
	// The memory budget (step 6) hooks residency accounting in here.
	ps := txn.env.page_size
	off := int(pgno) * ps
	return txn.env.map_base[off:off + ps]
}
