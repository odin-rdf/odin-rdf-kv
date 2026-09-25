package killer

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strconv"

import kv "../../kv"
import "workload"

/*
The helper process of the real-kill test (KV-I-0005 D1, KV-T-0032):

	killer <database> <dirty_budget>

Opens the database (creating it if it doesn't exist), reads the number of
the last commit under workload.COUNTER_KEY (0 if absent), then commits the
workload's commits from the next one on, forever, printing each commit's
number on its own line to stdout once txn_commit has returned. It runs until
it is killed; any error ends it with exit status 1 and a message on stderr.

Each line is one write(2) to the pipe, unbuffered, so every number printed
before the kill reaches the test. Built by the test with real syncs:
KV_NO_SYNC must not be set, and main refuses to run if it is.
*/
main :: proc() {
	if kv.NO_SYNC {
		fail("built with KV_NO_SYNC: the kill test needs real syncs")
	}
	if len(os.args) != 3 {
		fail("usage: killer <database> <dirty_budget>")
	}
	dirty_budget, ok := strconv.parse_int(os.args[2])
	if !ok {
		fail("bad dirty_budget %q", os.args[2])
	}

	env, err := kv.env_open(os.args[1], {dirty_budget = dirty_budget})
	if err != .None {
		fail("env_open: %v", err)
	}

	c := counter(env)
	ops := make([dynamic]workload.Op, 0, 80)
	value := make([]byte, 30_000)
	key_buf: [8]byte
	line_buf: [24]byte
	for {
		c += 1
		txn, berr := kv.txn_begin(env, read_only = false)
		if berr != .None {
			fail("commit %d: txn_begin: %v", c, berr)
		}
		clear(&ops)
		workload.commit_ops(c, &ops)
		for op in ops {
			key := workload.slot_key(key_buf[:], op.slot)
			if op.len < 0 {
				if derr := kv.del(&txn, key); derr != .None && derr != .Not_Found {
					fail("commit %d: del %s: %v", c, key, derr)
				}
				continue
			}
			workload.value_fill(value[:op.len], c, op.slot)
			if perr := kv.put(&txn, key, value[:op.len]); perr != .None {
				fail("commit %d: put %s: %v", c, key, perr)
			}
		}
		n: [8]byte
		endian.put_u64(n[:], .Big, c)
		if perr := kv.put(&txn, transmute([]byte)string(workload.COUNTER_KEY), n[:]); perr != .None {
			fail("commit %d: put counter: %v", c, perr)
		}
		if cerr := kv.txn_commit(&txn); cerr != .None {
			fail("commit %d: txn_commit: %v", c, cerr)
		}
		if _, werr := os.write(os.stdout, transmute([]byte)fmt.bprintf(line_buf[:], "%d\n", c)); werr != nil {
			fail("commit %d: write: %v", c, werr)
		}
	}
}

// The last commit's number, from COUNTER_KEY; 0 in a new database.
counter :: proc(env: ^kv.Env) -> u64 {
	txn, err := kv.txn_begin(env)
	if err != .None {
		fail("txn_begin: %v", err)
	}
	defer kv.txn_abort(&txn)
	v, gerr := kv.get(&txn, transmute([]byte)string(workload.COUNTER_KEY))
	switch {
	case gerr == .Not_Found:
		return 0
	case gerr != .None:
		fail("get counter: %v", gerr)
	case len(v) != 8:
		fail("counter is %d bytes", len(v))
	}
	return endian.unchecked_get_u64be(v)
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
