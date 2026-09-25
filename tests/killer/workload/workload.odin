package killer_workload

import "core:encoding/endian"
import "core:fmt"

/*
The real-kill test's workload (KV-I-0005 D1, KV-T-0032), shared by the
helper that runs it (tests/killer) and the test that checks what a kill
left (tests/kill_test.odin).

Commit `c` (from 1) writes `c` under COUNTER_KEY and changes a few of SLOTS
slot keys, chosen by a hash of `c` alone: puts of 16 to 300 bytes, one in
ten an overflow value of 5,000 to 30,000 bytes, and one change in six a
delete. One commit in twelve changes 80 slots, which spills with the
smallest dirty-page pool. So the state after commit N is a function of N:
`replay` rebuilds it, and `value_fill` gives every value's exact bytes.
*/

COUNTER_KEY :: "n"

// The slot keys, "s0000" to "s1999"; each sorts after COUNTER_KEY.
SLOTS :: 2000

// A change to one slot: a put of `len` bytes, or a delete (`len` < 0).
Op :: struct {
	slot: int,
	len:  int,
}

@(private = "file")
splitmix :: proc(x: u64) -> u64 {
	z := x + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// Appends commit `c`'s changes to `ops`, in the order they are made. A slot
// may appear twice; the later change wins.
commit_ops :: proc(c: u64, ops: ^[dynamic]Op) {
	h := splitmix(c)
	n := 1 + int(h % 8)
	if (h >> 8) % 12 == 0 {
		n = 80
	}
	for i in 0 ..< n {
		r := splitmix(c * 1_000 + u64(i) + 1)
		op := Op {
			slot = int(r % SLOTS),
		}
		switch {
		case (r >> 16) % 6 == 0:
			op.len = -1
		case (r >> 24) % 10 == 0:
			op.len = 5_000 + int((r >> 32) % 25_001)
		case:
			op.len = 16 + int((r >> 32) % 285)
		}
		append(ops, op)
	}
}

// Slot `slot`'s key, in `buf` (at least 5 bytes).
slot_key :: proc(buf: []byte, slot: int) -> []byte {
	return transmute([]byte)fmt.bprintf(buf, "s%04d", slot)
}

// Fills `value` with the bytes commit `c` puts under slot `slot`: `c` and
// `slot` big-endian in the first 12 bytes (every value is at least 16),
// then a pattern of both.
value_fill :: proc(value: []byte, c: u64, slot: int) {
	endian.put_u64(value[0:8], .Big, c)
	endian.put_u32(value[8:12], .Big, u32(slot))
	x := splitmix(c ~ (u64(slot) << 40))
	for i in 12 ..< len(value) {
		value[i] = byte(x >> (u64(i) % 8 * 8)) ~ byte(i)
	}
}

// The state after commit `n`: for each slot, the commit that last put it
// and the value's length, or {0, -1} if it is absent.
Slot_State :: struct {
	commit: u64,
	len:    int,
}

replay :: proc(n: u64, state: []Slot_State, allocator := context.temp_allocator) {
	assert(len(state) == SLOTS)
	for &s in state {
		s = {0, -1}
	}
	ops := make([dynamic]Op, 0, 80, allocator)
	defer delete(ops)
	for c in 1 ..= n {
		clear(&ops)
		commit_ops(c, &ops)
		for op in ops {
			state[op.slot] = {c, op.len} if op.len >= 0 else {0, -1}
		}
	}
}
