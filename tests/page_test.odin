package kv_tests

import "core:bytes"
import "core:encoding/endian"
import "core:math/rand"
import "core:slice"
import "core:testing"

import kv "../kv"

// Page buffer for the largest page size, for tests that vary it.
Big_Page_Buf :: struct #align(16) {
	bytes: [kv.MAX_PAGE_SIZE]byte,
}

USABLE :: kv.DEFAULT_PAGE_SIZE - kv.PAGE_HEADER_SIZE

expect_page_ok :: proc(t: ^testing.T, page: []byte, loc := #caller_location) {
	ok, reason := kv.page_check(page)
	testing.expectf(t, ok, "page_check failed: %s", reason, loc = loc)
}

// A 4-byte big-endian key, so keys sort numerically.
be_key :: proc(buf: ^[4]byte, v: u32) -> []byte {
	endian.put_u32(buf[:], .Big, v)
	return buf[:]
}

// Random bytes of the given length, from the test's seeded generator.
random_bytes :: proc(buf: []byte) {
	for &b in buf {
		b = byte(rand.uint32())
	}
}

// Copies of every key on the page, in slot order, allocated with the temp
// allocator. They must be copies: node_key returns slices into the page,
// which a split rewrites.
page_keys :: proc(page: []byte) -> [dynamic][]byte {
	keys := make([dynamic][]byte, context.temp_allocator)
	for i in 0 ..< kv.page_num_keys(page) {
		append(&keys, slice.clone(kv.node_key(page, i), context.temp_allocator))
	}
	return keys
}

@(test)
test_size_limits :: proc(t: ^testing.T) {
	testing.expect_value(t, kv.max_key_size(4096), 1002)

	for page_size in ([]int{4096, 8192, 16384, 32768}) {
		usable := page_size - kv.PAGE_HEADER_SIZE
		max_key := kv.max_key_size(page_size)
		threshold := kv.overflow_threshold(page_size)

		testing.expect(t, max_key % 2 == 0, "max key size must be even")
		// The largest branch node, overflow leaf node and inline leaf node
		// each fit 4 to a page.
		testing.expectf(t, 4 * (kv.branch_node_size(max_key) + kv.SLOT_SIZE) <= usable, "branch, page %d", page_size)
		testing.expectf(t, 4 * (kv.leaf_node_size(max_key, 0, true) + kv.SLOT_SIZE) <= usable, "overflow leaf, page %d", page_size)
		testing.expectf(t, 4 * (threshold + kv.SLOT_SIZE) <= usable, "inline leaf, page %d", page_size)

		// The overflow boundary is exact.
		key_len := 10
		val_len := threshold - kv.leaf_node_size(key_len, 0, false)
		testing.expect(t, !kv.leaf_needs_overflow(page_size, key_len, val_len), "value at the threshold must stay inline")
		testing.expect(t, kv.leaf_needs_overflow(page_size, key_len, val_len + 1), "value past the threshold must overflow")
	}
}

@(test)
test_page_init :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]
	for &b in page {
		b = 0xAA
	}
	kv.page_init(page, 42, kv.PAGE_LEAF)

	testing.expect(t, kv.page_is_leaf(page) && !kv.page_is_branch(page), "wrong page kind")
	testing.expect_value(t, kv.page_num_keys(page), 0)
	testing.expect_value(t, kv.page_free_space(page), USABLE)
	testing.expect_value(t, kv.page_used(page), 0)
	testing.expect_value(t, kv.page_header(page).pgno, 42)
	testing.expect(t, slice.all_of(page[kv.PAGE_HEADER_SIZE:], 0), "page not zeroed")
	expect_page_ok(t, page)
}

@(test)
test_leaf_random_inserts_stay_sorted :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]
	kv.page_init(page, 1, kv.PAGE_LEAF)

	inserted := make(map[string]string)
	defer {
		for k, v in inserted {
			delete(k)
			delete(v)
		}
		delete(inserted)
	}

	for {
		key: [16]byte
		value: [24]byte
		k := key[:1 + rand.int_max(len(key))]
		v := value[:rand.int_max(len(value) + 1)]
		random_bytes(k)
		random_bytes(v)

		idx, exact := kv.page_search(page, k)
		if exact {
			continue
		}
		if !kv.leaf_insert(page, idx, k, v) {
			break
		}
		inserted[string(slice.clone(k))] = string(slice.clone(v))
	}

	expect_page_ok(t, page)
	testing.expect_value(t, kv.page_num_keys(page), len(inserted))
	testing.expect(t, kv.page_free_space(page) < kv.leaf_node_size(16, 24, false) + kv.SLOT_SIZE, "page should be nearly full")

	for k, v in inserted {
		idx, exact := kv.page_search(page, transmute([]byte)k)
		testing.expectf(t, exact, "key %v not found", transmute([]byte)k)
		value, _, bigdata := kv.leaf_value(page, idx)
		testing.expect(t, !bigdata && string(value) == v, "wrong value")
	}
}

@(test)
test_leaf_fill_exactly :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]
	kv.page_init(page, 1, kv.PAGE_LEAF)

	// A 2-byte key with an empty value takes 8 + 2 bytes plus a 2-byte slot.
	per_node := kv.leaf_node_size(2, 0, false) + kv.SLOT_SIZE
	testing.expect_value(t, USABLE % per_node, 0)

	for i in 0 ..< USABLE / per_node {
		key: [2]byte
		endian.put_u16(key[:], .Big, u16(i))
		// Insert at the front every other time, to shuffle slot order
		// against node order.
		idx := 0 if i % 2 == 0 else kv.page_num_keys(page)
		if i % 2 == 0 {
			idx, _ = kv.page_search(page, key[:])
		}
		testing.expect(t, kv.leaf_insert(page, idx, key[:], nil), "insert into non-full page failed")
	}
	testing.expect_value(t, kv.page_free_space(page), 0)
	expect_page_ok(t, page)

	before := buf
	testing.expect(t, !kv.leaf_insert(page, 0, {0xFF, 0xFF}, nil), "insert into a full page succeeded")
	testing.expect(t, !kv.leaf_insert(page, kv.page_num_keys(page), {}, nil), "zero-size insert into a full page succeeded")
	testing.expect(t, before == buf, "failed insert changed the page")
}

@(test)
test_remove_and_reinsert :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]
	kv.page_init(page, 1, kv.PAGE_LEAF)

	value: [100]byte
	for i in 0 ..< 20 {
		key: [4]byte
		// Varying value sizes, inserted in reverse so node order differs
		// from slot order.
		ok := kv.leaf_insert(page, 0, be_key(&key, u32(19 - i)), value[:(19 - i) * 5])
		testing.expect(t, ok, "setup insert failed")
	}
	expect_page_ok(t, page)

	free_before := kv.page_free_space(page)
	removed_size := kv.leaf_node_size(4, 7 * 5, false) + kv.SLOT_SIZE
	kv.node_remove(page, 7)
	expect_page_ok(t, page)
	testing.expect_value(t, kv.page_num_keys(page), 19)
	testing.expect_value(t, kv.page_free_space(page), free_before + removed_size)
	_, exact := kv.page_search(page, be_key(&[4]byte{}, 7))
	testing.expect(t, !exact, "removed key still present")

	// The freed space is reused by a node of the same size.
	key: [4]byte
	idx, _ := kv.page_search(page, be_key(&key, 7))
	testing.expect(t, kv.leaf_insert(page, idx, key[:], value[:35]), "reinsert failed")
	testing.expect_value(t, kv.page_free_space(page), free_before)
	expect_page_ok(t, page)

	// Remove from both ends, then everything.
	kv.node_remove(page, 0)
	kv.node_remove(page, kv.page_num_keys(page) - 1)
	expect_page_ok(t, page)
	for kv.page_num_keys(page) > 0 {
		kv.node_remove(page, kv.page_num_keys(page) / 2)
		expect_page_ok(t, page)
	}
	testing.expect_value(t, kv.page_free_space(page), USABLE)
	testing.expect(t, slice.all_of(page[kv.PAGE_HEADER_SIZE:], 0), "removed nodes left bytes behind")
}

@(test)
test_branch_search_minus_infinity :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]
	kv.page_init(page, 1, kv.PAGE_BRANCH)

	testing.expect(t, kv.branch_insert(page, 0, nil, 10), "insert slot 0")
	testing.expect(t, kv.branch_insert(page, 1, transmute([]byte)string("b"), 11), "insert b")
	testing.expect(t, kv.branch_insert(page, 2, transmute([]byte)string("d"), 12), "insert d")
	expect_page_ok(t, page)

	Case :: struct {
		key:   string,
		child: kv.Pgno,
	}
	cases := []Case{{"", 10}, {"a", 10}, {"b", 11}, {"bb", 11}, {"c", 11}, {"d", 12}, {"zzz", 12}}
	for c in cases {
		idx := kv.branch_find_child(page, transmute([]byte)c.key)
		testing.expectf(t, kv.branch_child(page, idx) == c.child, "key %q: child %v, want %v", c.key, kv.branch_child(page, idx), c.child)
	}

	// Slot 0 is never an exact match, even for the empty key.
	idx, exact := kv.page_search(page, nil)
	testing.expect(t, idx == 1 && !exact, "empty key matched slot 0")

	kv.branch_set_child(page, 1, 99)
	testing.expect_value(t, kv.branch_child(page, 1), 99)
	testing.expect_value(t, string(kv.node_key(page, 1)), "b")

	// A branch with only slot 0 routes everything there.
	kv.page_init(page, 2, kv.PAGE_BRANCH)
	kv.branch_insert(page, 0, nil, 5)
	testing.expect_value(t, kv.branch_find_child(page, transmute([]byte)string("anything")), 0)
}

@(test)
test_leaf_overflow_node :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]
	kv.page_init(page, 1, kv.PAGE_LEAF)

	// Odd key lengths put the page number at an odd offset.
	testing.expect(t, kv.leaf_insert_overflow(page, 0, transmute([]byte)string("big"), 0x0102_0304_0506_0708, 1_000_000), "insert overflow node")
	testing.expect(t, kv.leaf_insert(page, 0, transmute([]byte)string("a"), transmute([]byte)string("inline")), "insert inline node")
	expect_page_ok(t, page)

	value, overflow, bigdata := kv.leaf_value(page, 1)
	testing.expect(t, bigdata && value == nil, "expected an overflow node")
	testing.expect_value(t, overflow, 0x0102_0304_0506_0708)
	testing.expect_value(t, kv.leaf_value_size(page, 1), 1_000_000)
	testing.expect_value(t, len(kv.node_bytes(page, 1)), kv.leaf_node_size(3, 0, true))

	value, overflow, bigdata = kv.leaf_value(page, 0)
	testing.expect(t, !bigdata && overflow == 0 && string(value) == "inline", "wrong inline value")
	testing.expect_value(t, kv.leaf_value_size(page, 0), 6)
}

@(test)
test_max_size_nodes_fit_four_per_page :: proc(t: ^testing.T) {
	big: Big_Page_Buf
	for page_size in ([]int{4096, 8192, 16384, 32768}) {
		page := big.bytes[:page_size]
		max_key := kv.max_key_size(page_size)
		key := make([]byte, max_key)
		defer delete(key)

		// Branch: slot 0 plus 4 maximum-size keys.
		kv.page_init(page, 1, kv.PAGE_BRANCH)
		testing.expect(t, kv.branch_insert(page, 0, nil, 1), "branch slot 0")
		for i in 0 ..< 4 {
			key[max_key - 1] = byte(i)
			testing.expectf(t, kv.branch_insert(page, i + 1, key, kv.Pgno(i + 2)), "branch node %d, page %d", i, page_size)
		}
		expect_page_ok(t, page)

		// Leaf: 4 maximum-size keys whose values are in overflow pages.
		kv.page_init(page, 1, kv.PAGE_LEAF)
		for i in 0 ..< 4 {
			key[max_key - 1] = byte(i)
			testing.expectf(t, kv.leaf_insert_overflow(page, i, key, kv.Pgno(i + 2), 1 << 20), "overflow node %d, page %d", i, page_size)
		}
		expect_page_ok(t, page)

		// Leaf: 4 of the largest inline nodes.
		kv.page_init(page, 1, kv.PAGE_LEAF)
		value := make([]byte, kv.overflow_threshold(page_size) - kv.leaf_node_size(4, 0, false))
		defer delete(value)
		for i in 0 ..< 4 {
			k: [4]byte
			testing.expectf(t, kv.leaf_insert(page, i, be_key(&k, u32(i)), value), "inline node %d, page %d", i, page_size)
		}
		expect_page_ok(t, page)
	}
}

// Inserts a leaf node the way the write path will: inline, or with the
// value in an overflow run when it is too large.
insert_kv :: proc(page: []byte, idx: int, key, value: []byte) -> bool {
	if kv.leaf_needs_overflow(len(page), len(key), len(value)) {
		return kv.leaf_insert_overflow(page, idx, key, 12345, len(value))
	}
	return kv.leaf_insert(page, idx, key, value)
}

insert_kv_size :: proc(page_size: int, key, value: []byte) -> int {
	bigdata := kv.leaf_needs_overflow(page_size, len(key), len(value))
	return kv.leaf_node_size(len(key), len(value), bigdata)
}

// Splits a full leaf page to insert `key`/`value` the way the write path
// will: split_point, then page_move_upper, then insert into the right half.
// Returns false if the new node didn't fit in its half.
split_and_insert :: proc(left, right: []byte, key, value: []byte) -> (split: int, ok: bool) {
	idx, _ := kv.page_search(left, key)
	split = kv.split_point(left, idx, insert_kv_size(len(left), key, value))
	move_from := split - 1 if idx < split else split

	kv.page_init(right, 2, kv.PAGE_LEAF)
	kv.page_move_upper(left, right, move_from)
	if idx < split {
		return split, insert_kv(left, idx, key, value)
	}
	return split, insert_kv(right, idx - split, key, value)
}

// Checks the two halves of a split: both valid, ordered across the boundary,
// holding exactly `expected` keys in order.
expect_split_halves :: proc(t: ^testing.T, left, right: []byte, expected: [][]byte, loc := #caller_location) {
	expect_page_ok(t, left, loc)
	expect_page_ok(t, right, loc)
	testing.expect(t, kv.page_num_keys(left) > 0 && kv.page_num_keys(right) > 0, "empty half", loc = loc)

	keys := page_keys(left)
	append(&keys, ..page_keys(right)[:])
	testing.expect_value(t, len(keys), len(expected), loc = loc)
	for i in 0 ..< min(len(keys), len(expected)) {
		testing.expectf(t, bytes.equal(keys[i], expected[i]), "key %d differs after split", i, loc = loc)
	}
}

@(test)
test_split_point_mixed_sizes :: proc(t: ^testing.T) {
	left_buf, right_buf: Page_Buf
	left, right := left_buf.bytes[:], right_buf.bytes[:]
	big := kv.overflow_threshold(kv.DEFAULT_PAGE_SIZE) - kv.leaf_node_size(4, 0, false)

	// Keys 10, 20, 30, ... with sizes alternating: two big nodes, then small ones.
	build :: proc(page: []byte, big: int) -> int {
		kv.page_init(page, 1, kv.PAGE_LEAF)
		value: [kv.MAX_PAGE_SIZE / 4]byte
		n := 0
		for {
			key: [4]byte
			size := big if n < 2 else 20
			if !kv.leaf_insert(page, n, be_key(&key, u32(10 * (n + 1))), value[:size]) {
				return n
			}
			n += 1
		}
	}

	for new_key in ([]u32{5, 25, 155, 1_000_000}) {
		for new_size in ([]int{0, big}) {
			n := build(left, big)

			// The split balances the halves to within one node.
			key: [4]byte
			k := be_key(&key, new_key)
			value := make([]byte, new_size)
			defer delete(value)
			idx, _ := kv.page_search(left, k)
			total := kv.page_used(left) + kv.leaf_node_size(4, new_size, false) + kv.SLOT_SIZE

			expected := page_keys(left)
			inject_at(&expected, idx, k)

			split, ok := split_and_insert(left, right, k, value)
			testing.expectf(t, ok, "key %d size %d: new node did not fit after split", new_key, new_size)
			testing.expect(t, split >= 1 && split <= n, "split point out of range")
			expect_split_halves(t, left, right, expected[:])

			imbalance := abs(kv.page_used(left) - kv.page_used(right))
			testing.expectf(t, imbalance <= kv.max_node_size(kv.DEFAULT_PAGE_SIZE) + kv.SLOT_SIZE,
				"key %d size %d: halves %d and %d of %d", new_key, new_size, kv.page_used(left), kv.page_used(right), total)
		}
	}
}

// Fill a page with random nodes until one doesn't fit, split, and check.
// Repeated with random sizes, including maximum-size keys and values.
@(test)
test_split_randomized :: proc(t: ^testing.T) {
	left_buf, right_buf: Page_Buf
	left, right := left_buf.bytes[:], right_buf.bytes[:]
	max_key := kv.max_key_size(kv.DEFAULT_PAGE_SIZE)
	threshold := kv.overflow_threshold(kv.DEFAULT_PAGE_SIZE)

	key_buf: [kv.MAX_PAGE_SIZE / 4]byte
	value_buf: [kv.MAX_PAGE_SIZE / 4]byte

	for _ in 0 ..< 300 {
		kv.page_init(left, 1, kv.PAGE_LEAF)
		// Mostly small nodes, sometimes huge ones.
		big_odds := 1 + rand.int_max(8)
		for {
			key_len := 1 + rand.int_max(max_key if rand.int_max(big_odds) == 0 else 24)
			val_len := rand.int_max(threshold - kv.leaf_node_size(key_len, 0, false) + 1) if rand.int_max(big_odds) == 0 else rand.int_max(40)
			k, v := key_buf[:key_len], value_buf[:val_len]
			random_bytes(k)

			idx, exact := kv.page_search(left, k)
			if exact {
				continue
			}
			if insert_kv(left, idx, k, v) {
				continue
			}

			// Full: split to make room.
			expected := page_keys(left)
			inject_at(&expected, idx, k)
			_, ok := split_and_insert(left, right, k, v)
			testing.expect(t, ok, "new node did not fit after split")
			expect_split_halves(t, left, right, expected[:])
			break
		}
		free_all(context.temp_allocator)
		if testing.failed(t) {
			return
		}
	}
}

@(test)
test_page_move_upper_edges :: proc(t: ^testing.T) {
	src_buf, dst_buf: Page_Buf
	src, dst := src_buf.bytes[:], dst_buf.bytes[:]

	fill :: proc(page: []byte) {
		kv.page_init(page, 7, kv.PAGE_LEAF)
		for i in 0 ..< 10 {
			key: [4]byte
			kv.leaf_insert(page, 0, be_key(&key, u32(9 - i)), {byte(i)})
		}
	}

	// Move nothing: src is compacted but otherwise unchanged.
	fill(src)
	kv.page_init(dst, 8, kv.PAGE_LEAF)
	kv.page_move_upper(src, dst, 10)
	testing.expect_value(t, kv.page_num_keys(src), 10)
	testing.expect_value(t, kv.page_num_keys(dst), 0)
	testing.expect_value(t, kv.page_header(src).pgno, 7)
	expect_page_ok(t, src)

	// Move everything.
	fill(src)
	kv.page_init(dst, 8, kv.PAGE_LEAF)
	kv.page_move_upper(src, dst, 0)
	testing.expect_value(t, kv.page_num_keys(src), 0)
	testing.expect_value(t, kv.page_num_keys(dst), 10)
	testing.expect_value(t, kv.page_free_space(src), USABLE)
	expect_page_ok(t, dst)
	for i in 0 ..< 10 {
		value, _, _ := kv.leaf_value(dst, i)
		testing.expect_value(t, value[0], byte(9 - i))
	}
}

@(test)
test_page_check_detects_corruption :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]

	fresh :: proc(page: []byte) {
		kv.page_init(page, 1, kv.PAGE_LEAF)
		for i in 0 ..< 3 {
			key: [4]byte
			kv.leaf_insert(page, i, be_key(&key, u32(i)), {1, 2, 3})
		}
	}
	slot :: proc(page: []byte, i: int) -> ^u16le {
		return &([^]u16le)(raw_data(page[kv.PAGE_HEADER_SIZE:]))[i]
	}
	expect_bad :: proc(t: ^testing.T, page: []byte, what: string, loc := #caller_location) {
		ok, _ := kv.page_check(page)
		testing.expectf(t, !ok, "page_check missed: %s", what, loc = loc)
	}

	fresh(page)
	expect_page_ok(t, page)

	fresh(page)
	slot(page, 0)^, slot(page, 1)^ = slot(page, 1)^, slot(page, 0)^
	expect_bad(t, page, "keys out of order")

	fresh(page)
	slot(page, 1)^ = slot(page, 0)^
	expect_bad(t, page, "two slots pointing at one node")

	fresh(page)
	kv.page_header(page).upper -= 1
	expect_bad(t, page, "gap in the node area")

	fresh(page)
	kv.page_header(page).lower += 1
	expect_bad(t, page, "odd lower")

	fresh(page)
	kv.page_header(page).flags = kv.PAGE_LEAF | kv.PAGE_BRANCH
	expect_bad(t, page, "both branch and leaf")

	fresh(page)
	slot(page, 2)^ = u16le(kv.DEFAULT_PAGE_SIZE - 2)
	expect_bad(t, page, "node past the end of the page")

	fresh(page)
	kv.page_init(page, 1, kv.PAGE_BRANCH)
	kv.branch_insert(page, 0, transmute([]byte)string("x"), 2)
	expect_bad(t, page, "branch slot 0 with a key")
}
