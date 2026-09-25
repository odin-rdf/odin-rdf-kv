package kv_tests

import "core:bytes"
import "core:fmt"
import "core:testing"

import kv "../kv"

// README.md's quick start, kept here so the suite compiles and runs it.
// Keep the two identical, except for the import path: the README imports
// the package through a collection (`kv:kv`).

readme_example :: proc(path: string) -> kv.Error {
	env := kv.env_open(path, kv.Options{mapped_budget = 16 << 20}) or_return
	defer kv.env_close(env)

	// One write transaction at a time. Nothing it does is visible to
	// readers, or durable, until txn_commit returns .None.
	{
		txn := kv.txn_begin(env, read_only = false) or_return
		defer kv.txn_abort(&txn) // ends the transaction; harmless after a commit

		kv.put(&txn, transmute([]byte)string("fruit:apple"), transmute([]byte)string("red")) or_return
		kv.put(&txn, transmute([]byte)string("fruit:banana"), transmute([]byte)string("yellow")) or_return
		kv.put(&txn, transmute([]byte)string("veg:leek"), transmute([]byte)string("green")) or_return
		kv.txn_commit(&txn) or_return
	}

	// Readers see the snapshot committed when they began. They never block,
	// and are never blocked by, the writer.
	txn := kv.txn_begin(env) or_return
	defer kv.txn_abort(&txn)

	// Zero-copy: `value` points into the memory-mapped file, and is valid
	// until the transaction ends. Copy it to keep it longer.
	value := kv.get(&txn, transmute([]byte)string("fruit:apple")) or_return
	fmt.println(string(value))

	// A range scan: every key in ["fruit:", "fruit;"), which is every key
	// starting with "fruit:" (';' is the byte after ':').
	start := transmute([]byte)string("fruit:")
	end := transmute([]byte)string("fruit;")
	c := kv.cursor_open(&txn)
	for k, v, err := kv.cursor_seek(&c, start); err == .None; k, v, err = kv.cursor_next(&c) {
		if bytes.compare(k, end) >= 0 {
			break
		}
		fmt.println(string(k), string(v))
	}
	return .None
}

@(test)
test_readme_example :: proc(t: ^testing.T) {
	dir := temp_dir_create(t)
	defer temp_dir_destroy(&dir, DB)
	path := temp_dir_file(dir, DB)
	testing.expect_value(t, readme_example(path), kv.Error.None)
	// Twice: the second run opens the file the first one created.
	testing.expect_value(t, readme_example(path), kv.Error.None)
}
