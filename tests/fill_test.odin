package kv_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:testing"

import kv "../kv"

/*
How full pages are after deletes (KV-I-0003 D1). A delete merges an
underfull page only with a sibling it fits with, and never borrows, so the
only guarantee is that no page below the root is empty. This measures what
that means in practice, against a tree built by inserts alone from the same
keys. The figures are reported, not asserted:

	odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_delete_fill

Only the registration is guarded, as for the free-list cost.
*/
when #config(KV_BENCH, false) {
	@(test)
	test_bench_delete_fill :: proc(t: ^testing.T) {
		bench_delete_fill(t)
	}
}

// Page counts and fill (used bytes over usable bytes) of one tree.
Fill_Stats :: struct {
	depth:              int,
	leaves, branches:   int,
	leaf_used:          int,
	branch_used:        int,
	// The emptiest leaf and branch below the root, and how many leaves are
	// under a quarter full.
	min_leaf:           int,
	min_branch:         int,
	underfull_leaves:   int,
	single_child_nodes: int,
}

tree_fill :: proc(txn: ^kv.Txn) -> (s: Fill_Stats) {
	s.depth = int(txn.snapshot.depth)
	s.min_leaf, s.min_branch = max(int), max(int)
	if txn.snapshot.root != 0 {
		fill_walk(txn, txn.snapshot.root, true, &s)
	}
	return s
}

@(private = "file")
fill_walk :: proc(txn: ^kv.Txn, pgno: kv.Pgno, root: bool, s: ^Fill_Stats) {
	page := kv.page_ptr(txn, pgno)
	used := kv.page_used(page)
	if kv.page_is_leaf(page) {
		s.leaves += 1
		s.leaf_used += used
		if !root {
			s.min_leaf = min(s.min_leaf, used)
			s.underfull_leaves += int(kv.page_underfull(page))
		}
		return
	}
	s.branches += 1
	s.branch_used += used
	n := kv.page_num_keys(page)
	if !root {
		s.min_branch = min(s.min_branch, used)
		s.single_child_nodes += int(n == 1)
	}
	for i in 0 ..< n {
		fill_walk(txn, kv.branch_child(page, i), false, s)
	}
}

fill_format :: proc(label: string, s: Fill_Stats, usable: int) -> string {
	// fmt pads a number given a width with zeros, so numbers are formatted
	// first and padded as strings.
	pct :: proc(used, pages, usable: int) -> string {
		return fmt.tprintf("%.1f%%", 100 * f64(used) / f64(max(pages, 1) * usable))
	}
	min_pct :: proc(v, usable: int) -> string {
		return "-" if v == max(int) else fmt.tprintf("%.1f%%", 100 * f64(v) / f64(usable))
	}
	num :: proc(v: int) -> string {
		return fmt.tprintf("%d", v)
	}
	return fmt.tprintf("%-26s depth %d, %5s leaves %6s full (min %6s, %s under 25%%), %3s branches %6s full (min %6s, %s with one child)",
		label, s.depth, num(s.leaves), pct(s.leaf_used, s.leaves, usable), min_pct(s.min_leaf, usable), num(s.underfull_leaves),
		num(s.branches), pct(s.branch_used, s.branches, usable), min_pct(s.min_branch, usable), num(s.single_child_nodes))
}

bench_delete_fill :: proc(t: ^testing.T) {
	N :: 50_000
	// 8-byte keys in scrambled order, values of 0–100 bytes.
	key_of :: proc(id: int, buf: ^[8]byte) -> []byte {
		return u64_key(buf, u64(id) * 0x9E37_79B9_7F4A_7C15)
	}
	value_of :: proc(id: int) -> []byte {
		return patterned(int(u64(id) * 0xBF58_476D_1CE4_E5B9 >> 40 % 101), u32(id))
	}
	usable := kv.DEFAULT_PAGE_SIZE - kv.PAGE_HEADER_SIZE

	// A fresh database holding `ids`, inserted in the given order.
	insert_only :: proc(t: ^testing.T, label: string, ids: []int, usable: int) -> string {
		dir := temp_dir_create(t)
		defer temp_dir_destroy(&dir, DB)
		env, txn, ok := open_write(t, temp_dir_file(dir, DB))
		if !ok {
			return ""
		}
		defer kv.env_close(env)
		defer kv.txn_abort(&txn)
		for id in ids {
			key: [8]byte
			kv.put(&txn, key_of(id, &key), value_of(id))
		}
		return fill_format(label, tree_fill(&txn), usable)
	}

	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	env, txn, ok := open_write(t, temp_dir_file(dir, DB))
	if !ok {
		return
	}
	defer kv.env_close(env)

	ids := make([]int, N, context.temp_allocator)
	for &id, i in ids {
		id = i
	}
	rand.shuffle(ids)
	for id in ids {
		key: [8]byte
		kv.put(&txn, key_of(id, &key), value_of(id))
	}
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fill_format("inserted, random order", tree_fill(&txn), usable))
	kv.txn_commit(&txn)

	// Delete in random order, in commits of 1,000, reporting at 50% and 90%,
	// each beside a tree built by inserting the survivors in random order.
	rand.shuffle(ids)
	deleted := 0
	for target in ([]int{N / 2, N * 9 / 10}) {
		for deleted < target {
			txn, _ = kv.txn_begin(env, read_only = false)
			for id in ids[deleted:min(deleted + 1000, target)] {
				key: [8]byte
				if err := kv.del(&txn, key_of(id, &key)); err != .None {
					testing.expectf(t, false, "del %d: %v", id, err)
					kv.txn_abort(&txn)
					return
				}
			}
			deleted = min(deleted + 1000, target)
			if !commit_ok(t, env, &txn) {
				return
			}
		}
		reader, _ := kv.txn_begin(env)
		append(&lines, fill_format(fmt.tprintf("%d%% deleted", 100 * deleted / N), tree_fill(&reader), usable))
		kv.txn_abort(&reader)
		survivors := ids[deleted:]
		rand.shuffle(survivors)
		append(&lines, insert_only(t, "  the survivors, inserted", survivors, usable))
	}
	for l in lines {
		log.info(l)
	}
}
