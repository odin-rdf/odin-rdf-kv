package kv_tests

import "core:bytes"
import "core:encoding/endian"
import "core:slice"
import "core:testing"

import kv "../kv"

/*
An in-memory model of the database for randomized tests.

The key space is fixed: ids 0..<n, each with key bytes derived from the id
(short, medium or maximum-length, in scrambled order). The model stores no
bytes: a value is identified by (version, size) and regenerated on demand,
so copying the whole model at a transaction boundary is cheap.
*/
Key_Space :: struct {
	keys:       [][]byte,
	// Ids in key order.
	sorted_ids: []int,
}

Val_Spec :: struct {
	present: bool,
	version: u32,
	size:    int,
}

// One entry per id.
Model :: []Val_Spec

// Builds the key space with the temp allocator.
key_space_make :: proc(n: int, page_size := kv.DEFAULT_PAGE_SIZE) -> Key_Space {
	ks := Key_Space {
		keys       = make([][]byte, n, context.temp_allocator),
		sorted_ids = make([]int, n, context.temp_allocator),
	}
	max_key := kv.max_key_size(page_size)
	for id in 0 ..< n {
		h := u64(id) * 0x9E37_79B9_7F4A_7C15
		key: []byte
		switch h % 20 {
		case 0:
			// Maximum length: a long shared prefix, the id at the end.
			key = make([]byte, max_key, context.temp_allocator)
			for &b in key {
				b = 'P'
			}
			endian.put_u64(key[max_key - 8:], .Big, u64(id))
		case 1, 2, 3:
			// Medium: filler derived from the id, then the id.
			size := 100 + int(h >> 32 % 200)
			key = make([]byte, size, context.temp_allocator)
			for &b, i in key {
				b = byte(h >> uint(i % 56))
			}
			endian.put_u64(key[size - 8:], .Big, u64(id))
		case:
			// Short: 8 bytes, a bijection of the id, so order is scrambled.
			key = make([]byte, 8, context.temp_allocator)
			endian.put_u64(key, .Big, h)
		}
		ks.keys[id] = key
		ks.sorted_ids[id] = id
	}
	sort_ids_by_key(&ks)
	return ks
}

// Sorts ids by their key bytes. The comparator reaches the keys through
// context.user_ptr, as Odin procedures can't capture variables.
@(private = "file")
sort_ids_by_key :: proc(ks: ^Key_Space) {
	keys := ks.keys
	context.user_ptr = &keys
	slice.sort_by(ks.sorted_ids, proc(a, b: int) -> bool {
		keys := (^[][]byte)(context.user_ptr)^
		return bytes.compare(keys[a], keys[b]) < 0
	})
}

// The value bytes for `spec` of key `id`, written into `buf`.
model_value :: proc(id: int, spec: Val_Spec, buf: []byte) -> []byte {
	v := buf[:spec.size]
	seed := u32(id) * 2654435761 + spec.version * 40503
	for &b, i in v {
		b = byte(u32(i) * 2246822519 + seed)
	}
	return v
}

model_count :: proc(m: Model) -> u64 {
	n: u64
	for spec in m {
		if spec.present {
			n += 1
		}
	}
	return n
}

// Largest value any model test uses, for sizing value buffers.
MODEL_MAX_VALUE :: 4 * kv.DEFAULT_PAGE_SIZE

/*
Compares everything `txn` sees with the model: the entry count, `get` for
every id (present or not), a full forward and backward cursor scan, and the
tree structure. Returns the first difference, or "" if there is none.

Safe to call from any thread: it reports instead of failing a test.
*/
model_diff :: proc(txn: ^kv.Txn, ks: Key_Space, m: Model, value_buf: []byte) -> string {
	if txn.snapshot.entries != model_count(m) {
		return "entry count differs"
	}
	for spec, id in m {
		got, err := kv.get(txn, ks.keys[id])
		if spec.present {
			if err != .None || !bytes.equal(got, model_value(id, spec, value_buf)) {
				return "get returned a wrong value"
			}
		} else if err != .Not_Found {
			return "get found an absent key"
		}
	}

	c := kv.cursor_open(txn)
	i := 0
	for key, value, err := kv.cursor_first(&c); err == .None; key, value, err = kv.cursor_next(&c) {
		i = next_present(ks, m, i, 1)
		if i == len(ks.sorted_ids) {
			return "forward scan found an extra key"
		}
		id := ks.sorted_ids[i]
		if !bytes.equal(key, ks.keys[id]) || !bytes.equal(value, model_value(id, m[id], value_buf)) {
			return "forward scan differs"
		}
		i += 1
	}
	if next_present(ks, m, i, 1) != len(ks.sorted_ids) {
		return "forward scan ended early"
	}

	i = len(ks.sorted_ids) - 1
	for key, _, err := kv.cursor_last(&c); err == .None; key, _, err = kv.cursor_prev(&c) {
		i = next_present(ks, m, i, -1)
		if i < 0 || !bytes.equal(key, ks.keys[ks.sorted_ids[i]]) {
			return "backward scan differs"
		}
		i -= 1
	}
	if next_present(ks, m, i, -1) >= 0 {
		return "backward scan ended early"
	}

	if ok, reason := kv.tree_check(txn, context.allocator); !ok {
		return reason
	}
	return ""
}

// From sorted position `i`, the first position (moving by `dir`) whose id
// is present in the model; len(sorted_ids) or -1 if there is none.
next_present :: proc(ks: Key_Space, m: Model, i: int, dir: int) -> int {
	i := i
	for i >= 0 && i < len(ks.sorted_ids) && !m[ks.sorted_ids[i]].present {
		i += dir
	}
	return i
}

// The first sorted position whose key is ≥ `target`.
lower_bound :: proc(ks: Key_Space, target: []byte) -> int {
	lo, hi := 0, len(ks.sorted_ids)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if bytes.compare(ks.keys[ks.sorted_ids[mid]], target) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// model_diff for the test thread: records a failure with the seed, the
// operation (if `op` is given) and the phase if the transaction differs
// from the model.
model_compare :: proc(t: ^testing.T, txn: ^kv.Txn, ks: Key_Space, m: Model, value_buf: []byte, phase: string, seed: u64, op := -1, loc := #caller_location) -> bool {
	if diff := model_diff(txn, ks, m, value_buf); diff != "" {
		if op >= 0 {
			testing.expectf(t, false, "[seed %d] op %d: %s: %s", seed, op, phase, diff, loc = loc)
		} else {
			testing.expectf(t, false, "[seed %d] %s: %s", seed, phase, diff, loc = loc)
		}
		return false
	}
	return true
}
