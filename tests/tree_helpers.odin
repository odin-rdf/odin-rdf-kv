package kv_tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:testing"

import kv "../kv"

Entry :: struct {
	key, value: []byte,
}

Built_Tree :: struct {
	root:      kv.Pgno,
	depth:     int,
	last_pgno: kv.Pgno,
}

// `n` entries with 8-byte big-endian keys 0, 2, 4, ... (so odd numbers are
// absent) and values "v<i>". Allocated with the temp allocator.
even_entries :: proc(n: int) -> []Entry {
	entries := make([]Entry, n, context.temp_allocator)
	for &e, i in entries {
		key := make([]byte, 8, context.temp_allocator)
		endian.put_u64(key, .Big, u64(2 * i))
		e = {key, transmute([]byte)fmt.tprintf("v%d", i)}
	}
	return entries
}

u64_key :: proc(buf: ^[8]byte, v: u64) -> []byte {
	endian.put_u64(buf[:], .Big, v)
	return buf[:]
}

/*
Writes a B+tree holding `entries` (sorted, unique, inline values only) into
the database at `path`, built bottom-up with the page layer, and commits it
with a meta page for `txn_id`. The database must not be open elsewhere.

This stands in for the write path until it exists, and lets tests build
trees of any shape directly.
*/
build_tree_file :: proc(t: ^testing.T, path: string, entries: []Entry, options := kv.Options{}, txn_id: u64 = 1) -> (tree: Built_Tree) {
	env, err := kv.env_open(path, options)
	testing.expect_value(t, err, kv.Error.None)
	if err != .None {
		return
	}
	defer kv.env_close(env)
	ps := env.page_size

	for i in 1 ..< len(entries) {
		assert(bytes.compare(entries[i - 1].key, entries[i].key) < 0, "entries must be sorted and unique")
	}
	if len(entries) == 0 {
		return {}
	}

	pages := make([dynamic][]byte, context.temp_allocator)
	next := kv.Pgno(2)
	new_page :: proc(pages: ^[dynamic][]byte, next: ^kv.Pgno, ps: int, flags: u16) -> []byte {
		page := make([]byte, ps, context.temp_allocator)
		kv.page_init(page, next^, flags)
		append(pages, page)
		next^ += 1
		return page
	}

	// The first key and page number of each page on the level being built.
	Level_Node :: struct {
		key:  []byte,
		pgno: kv.Pgno,
	}
	level := make([dynamic]Level_Node, context.temp_allocator)

	cur: []byte
	for e in entries {
		assert(!kv.leaf_needs_overflow(ps, len(e.key), len(e.value)), "build_tree_file only supports inline values")
		if cur == nil || !kv.leaf_insert(cur, kv.page_num_keys(cur), e.key, e.value) {
			cur = new_page(&pages, &next, ps, kv.PAGE_LEAF)
			append(&level, Level_Node{e.key, next - 1})
			ok := kv.leaf_insert(cur, 0, e.key, e.value)
			assert(ok)
		}
	}

	depth := 1
	for len(level) > 1 {
		upper := make([dynamic]Level_Node, context.temp_allocator)
		cur = nil
		for node in level {
			if cur == nil || !kv.branch_insert(cur, kv.page_num_keys(cur), node.key, node.pgno) {
				// A new branch page: this node becomes its −∞ slot, and its
				// key moves up a level.
				cur = new_page(&pages, &next, ps, kv.PAGE_BRANCH)
				append(&upper, Level_Node{node.key, next - 1})
				ok := kv.branch_insert(cur, 0, nil, node.pgno)
				assert(ok)
			}
		}
		level = upper
		depth += 1
	}

	tree = {root = level[0].pgno, depth = depth, last_pgno = next - 1}
	testing.expect_value(t, kv.os_truncate(env.fd, i64(next) * i64(ps)), kv.Error.None)
	for page in pages {
		ok, reason := kv.page_check(page)
		assert(ok, reason)
		pgno := i64(kv.page_header(page).pgno)
		testing.expect_value(t, kv.os_pwrite(env.fd, page, pgno * i64(ps)), kv.Error.None)
	}
	meta := kv.Meta {
		magic     = kv.MAGIC,
		version   = kv.VERSION,
		page_size = u32le(ps),
		txn_id    = u64le(txn_id),
		root      = u64le(tree.root),
		depth     = u32le(tree.depth),
		entries   = u64le(len(entries)),
		last_pgno = u64le(tree.last_pgno),
	}
	testing.expect_value(t, kv.meta_write(env, int(txn_id & 1), meta), kv.Error.None)
	return tree
}

// Reads page `pgno` of an open database into `buf`, lets the caller change
// it, and writes it back.
read_page :: proc(t: ^testing.T, env: ^kv.Env, pgno: kv.Pgno, buf: ^Page_Buf) -> []byte {
	page := buf.bytes[:env.page_size]
	testing.expect_value(t, kv.os_pread(env.fd, page, i64(pgno) * i64(env.page_size)), kv.Error.None)
	return page
}

// The length in pages of the free-list run of `snap`, from its header on
// disk: the pages its records need, or one more (kv.FREELIST_RUN_SLACK).
// 0 if the snapshot has no run.
freelist_run_len :: proc(t: ^testing.T, env: ^kv.Env, snap: kv.Snapshot) -> int {
	if snap.freelist_pgno == 0 {
		return 0
	}
	buf: Page_Buf
	return int(kv.page_header(read_page(t, env, snap.freelist_pgno, &buf)).overflow_count)
}

// Writes `page` at page number `pgno`, whatever its header says.
write_page :: proc(t: ^testing.T, env: ^kv.Env, pgno: kv.Pgno, page: []byte) {
	testing.expect_value(t, kv.os_pwrite(env.fd, page, i64(pgno) * i64(env.page_size)), kv.Error.None)
}
