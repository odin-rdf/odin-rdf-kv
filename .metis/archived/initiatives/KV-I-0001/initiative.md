---
id: core-copy-on-write-b-tree-file
level: initiative
title: "Core copy-on-write B+tree: file format, write path and cursors"
short_code: "KV-I-0001"
created_at: 2026-09-23T22:03:32.986460+00:00
updated_at: 2026-09-24T09:23:22.444046+00:00
parent: KV-V-0001
blocked_by: []
archived: true

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: false
estimated_complexity: L
initiative_id: core-copy-on-write-b-tree-file
---

# Core copy-on-write B+tree: file format, write path and cursors Initiative

## Context

This initiative covers build steps 1–3 of the vision (KV-V-0001). It delivers the smallest useful, crash-safe store: a single-file copy-on-write B+tree with dual meta pages, zero-copy reads from a read-only mmap, `put`, `get`, and cursors for range scans.

Later initiatives build on it:
- delete with merge (step 4);
- freeing and reusing pages, with the reader table (step 5);
- the store-scoped memory budget (step 6);
- crash testing and fuzzing (step 7).

Until step 5 lands, the file only grows. That's acceptable at this stage and keeps the scope small.

## Goals & Non-Goals

**Goals:**
- Define and implement the on-disk format: meta pages, slotted branch and leaf pages, and overflow pages. It must be stable enough that later initiatives only add to it.
- **Open:** create or open the file, reserve the read-only mmap, and choose the valid meta page with the highest `txn_id`.
- **Transactions:**
  - read transactions that take a snapshot, with zero-copy `get`;
  - write transactions with copy-on-write touch, insert, overwrite, splits (including root splits) and overflow values;
  - commit using the ordered two-sync protocol, and abort.
- **Cursors:** `first`, `last`, `seek`, `next` and `prev`, returning zero-copy slices.
- Run on macOS (primary) and Linux.

**Non-Goals:**
- Delete and merge: KV-I for step 4.
- Free list, page reuse and reader table: step 5. Pages replaced by copy-on-write, and overflow runs made obsolete by an overwrite, are simply leaked until then.
- Memory budget, spilling, eviction and the sweeper: step 6. This initiative must still route every page access through a single `page_ptr` so that step 6 can hook in.
- Kill-during-commit crash harness and long fuzzing runs: step 7. Basic meta-page fallback tests *are* in scope.
- Multi-process access, sub-databases and duplicate keys (excluded by the vision).

## Requirements

### Functional requirements
- **REQ-001:** `env_open(path, options)` creates a new database (writing two initial meta pages) or opens an existing one. It validates magic, version, page size and checksum.
- **REQ-002:** at open, the valid meta page with the highest `txn_id` is used. A meta page with a bad checksum is ignored. If both are invalid, return `Corrupted`.
- **REQ-003:** `get(txn, key)` returns a `[]byte` pointing into the mmap (or into a dirty page inside a write transaction), or `Not_Found`.
- **REQ-004:** `put(txn, key, val)` inserts or overwrites. Keys longer than the maximum return `Key_Too_Large`. A `put` on a read-only transaction returns `Txn_Read_Only`.
- **REQ-005:** values larger than the overflow threshold are stored in contiguous overflow pages, and `get` returns one slice covering the whole value.
- **REQ-006:** `txn_commit` makes all changes durable and visible atomically. `txn_abort` discards them, and is a no-op after commit.
- **REQ-007:** a read transaction sees a consistent snapshot, unaffected by commits that happen after it began.
- **REQ-008:** cursors support `first`, `last`, `seek` (first key ≥ k), `next` and `prev` in both read and write transactions, and return `Not_Found` at either end.
- **REQ-009:** the file grows by `ftruncate` as needed. Growing beyond `map_size` returns `Map_Full`, and the transaction remains abortable.

### Non-functional requirements
- **NFR-001:** read paths (`get` and cursor operations in a read transaction) allocate nothing.
- **NFR-002:** a cursor is a value type with a fixed-size stack, and needs no allocation.
- **NFR-003:** all page access goes through one `page_ptr(txn, pgno)` function.
- **NFR-004:** durability uses `F_FULLFSYNC` on Darwin and `fsync` (or `fdatasync`) on Linux.
- **NFR-005:** on-disk integers are little-endian (`u16le`, `u32le`, `u64le`).

## Architecture

### Overview
The code is one Odin package, `kv`, split by concern:

| File | Responsibility |
|---|---|
| `types.odin` | `Pgno`, `Txn_Id` (`distinct u64`), the `Error` enum, constants (magic, version, flags) |
| `page.odin` | Page header and node layout; slot binary search; node read, insert and replace; free-space accounting; split helpers |
| `meta.odin` | Meta layout, checksum, choosing a meta page, writing a meta page |
| `os_darwin.odin` / `os_linux.odin` | Platform layer: `mmap` reservation, `pwrite`, `ftruncate`, `sync_file` (`F_FULLFSYNC` vs `fsync`), `MADV_RANDOM` |
| `env.odin` | `Env`: fd, map base, `map_size`, page size, the current snapshot and the mutexes guarding it; `env_open` and `env_close` |
| `txn.odin` | `Txn`: snapshot, read-only flag, dirty map, next page number, generation counter; `txn_begin`, `txn_commit`, `txn_abort`; `page_ptr`, `page_touch`, `page_alloc` |
| `tree.odin` | Search, `get`, `put`, splits, overflow write and read |
| `cursor.odin` | The `Cursor` value type and its navigation operations |
| `tests/` | `odin test` suites |

### Sequence: `put` then commit
1. `txn_begin(rw)` takes the writer mutex and copies the snapshot: root, depth, `last_pgno`, `txn_id`.
2. `put`:
   1. Build a cursor stack with `seek(key)`.
   2. Touch the stack from the root down. For each page not yet dirty: allocate a new page number (`last_pgno + 1`), copy the page into a dirty buffer, and repoint the parent slot at the copy.
   3. Insert into the leaf, or split. A split cascades upwards; a root split creates a new root and increments the depth.
3. `txn_commit`:
   1. Grow the file if needed.
   2. `pwrite` every dirty page, then sync.
   3. Build the meta page (`txn_id + 1`, root, depth, `last_pgno`, count, checksum), `pwrite` it to slot `(txn_id + 1) & 1`, then sync.
   4. Take the snapshot mutex, publish the new snapshot, and release it.
   5. Free the dirty buffers and release the writer mutex.

## Detailed Design

### On-disk format (version 1)
- **Meta page (pages 0 and 1):**
  - `magic: u32le`, `version: u32le`, `page_size: u32le`, `flags: u32le`;
  - `txn_id: u64le`, `root: u64le` (0 means an empty tree), `depth: u32le`;
  - `entries: u64le`, `last_pgno: u64le`;
  - `freelist_pgno: u64le` and `freelist_count: u64le`, reserved for step 5 and written as 0;
  - `checksum: u64le` over the preceding bytes.
  - Checksum algorithm: xxHash64 via `xxhash.XXH64` from `core:hash/xxhash`, with the default seed.
- **Page header (16 bytes):** `pgno: u64le`, `flags: u16le` (`BRANCH`, `LEAF`, `OVERFLOW`, `META`), 2 reserved bytes, then `lower: u16le` and `upper: u16le`. For overflow pages, `lower` and `upper` are replaced by `overflow_count: u32le`; placing them at offset 12 keeps that union 4-byte-aligned.
- **Leaf node:** `key_len: u16le`, `flags: u16le` (`BIGDATA`), `val_len: u32le`, the key bytes, then the value bytes, or a `u64le` overflow page number when `BIGDATA` is set.
- **Branch node:** `child: u64le`, `key_len: u16le`, the key bytes. The key in slot 0 is ignored and treated as −∞, so it is stored with length 0.
- **Limits:**
  - `max_node_size = (page_size − header) / 4 − slot_size`: the largest node, excluding its slot. Every node plus its slot takes at most a quarter of the usable space, so every page holds at least 4 nodes.
  - `max_key = max_node_size − 16`, rounded down to an even number: 1002 bytes at 4 KiB pages. The 16 bytes are the largest node overhead: a leaf node whose value is in overflow pages (8-byte header plus 8-byte page number). A branch node's overhead is only 10.
  - **Overflow threshold:** a value goes to overflow pages when the inline leaf node would exceed `max_node_size` (`leaf_needs_overflow`).

### Byte order and alignment
- **Byte order:** every target the Odin compiler supports is little-endian, so the `le` field types cost nothing. They document the format and keep files portable between machines.
- **Integer keys must be stored big-endian.** Keys sort by `memcmp`, so only big-endian encoding sorts numerically. This matters for RDF index keys built from `u64` term IDs. Read them back with unaligned big-endian loads (`core:encoding/endian`, or a `#packed` struct of `u64be` fields).
- **64-bit targets only,** enforced by `#assert(size_of(int) == 8)` in `types.odin`.
- **Alignment guarantees:**

  | Data | Alignment |
  |---|---|
  | Page header | Page-aligned in the map |
  | `Meta` | 8 bytes (offset 16) |
  | Slots | 2 bytes |
  | Overflow values | 16 bytes (offset 16 of a page-aligned run) |
  | Node headers, the `BIGDATA` page number, inline keys and values | None: any byte offset |

- **Inline values are deliberately not padded** (decided 2026-09-24). Callers must not cast a value slice to a pointer to a multi-byte type; they read fields with unaligned loads or copy them out. This matches LMDB, and avoids up to 7 bytes of padding per entry.
- **Rules for the code:**
  - Node headers are `#packed` structs, and their fields are only read and written by value. Never take the address of a packed field.
  - The `BIGDATA` page number is read through a `#packed` struct or `intrinsics.unaligned_load`, never by casting to `^u64le`.
  - Page buffers outside the map (dirty pages, test buffers) must be allocated with at least `align_of(Page_Header)` alignment; dirty pages use page-size alignment. In debug builds, `page_header` and `page_meta` assert this.

### Page handling
- **`page_ptr(txn, pgno)`:** in a write transaction, check the dirty map first; otherwise return `map_base + pgno * page_size`. This is the only access path (NFR-003).
- **Dirty storage:**
  - A hash map from `Pgno` to a buffer pointer, with buffers allocated from a per-transaction arena (`core:mem/virtual`).
  - Step 6 will replace this with a bounded pool, so keep it behind `dirty_get`, `dirty_put` and `dirty_reset`.
- **Page allocation:** always `last_pgno + 1` (or `+ n` for overflow runs). A page allocated by this transaction is already dirty, so touching it again copies nothing.

### Split
- **Leaf split:**
  - Choose the split point by bytes, not by count, so both halves have room for the node being inserted.
  - The separator is the first key of the right page. The right page is a new page.
- **Branch split:**
  - Move the node at the split point up to the parent.
  - Its child becomes slot 0 of the right page, with its key treated as −∞.
- **Root split:** allocate a new branch root with two slots, `[−∞ → left, sep → right]`, and increment the depth.
- **Cursor depth:** `MAX_DEPTH = 24`. Exceeding it is treated as `Corrupted`; with the minimum fan-out of 4 it can't happen before the map is full.

### Cursor
- **Layout:** `Cursor { txn: ^Txn, gen: u32, depth: u8, stack: [MAX_DEPTH]struct{ pgno: Pgno, idx: u16 } }`.
- **Page numbers, not pointers:** the stack stores page numbers, so in a write transaction the cursor stays valid across page touches. Each access resolves the page through `page_ptr`.
- **Navigation:**
  - `next` / `prev` move along the leaf. At either end, pop to the nearest ancestor that has a slot in that direction, step to it, then descend to the leftmost or rightmost leaf.
  - `seek` performs the search. If the insertion point is past the end of the leaf, it advances with `next`.
- **Generation check (debug builds):** `txn.gen` must equal `cursor.gen`, which catches use after the transaction has ended.

### Concurrency (scope of this initiative)
- **Writer mutex:** one writer at a time.
- **Snapshot mutex:** protects the published snapshot. Readers copy it in `txn_begin(ro)`.
- **No reader table yet:** pages are never reused, so an old snapshot's pages are never overwritten. The reader table arrives in step 5, and until then `txn_begin(ro)` must keep the same shape so it can slot in.

## Testing Strategy

### Unit testing
- **Page layer:** insert nodes in random order and check the slots come out sorted; free-space accounting; split point choice; boundary sizes (maximum key; a value exactly at the overflow threshold, and one byte over).
- **Meta layer:** checksum round-trip; with one meta page corrupted, open falls back to the other; with both corrupted, open returns `Corrupted`; after a reopen, the highest `txn_id` wins.
- **Tools:** `odin test tests/`, run under both `-debug` and `-o:speed`, and with `-sanitize:address` in CI.

### Integration testing
- **Model check:** random `put` sequences (small keys, large keys, overflow values, overwrites) compared against a `map[string][]byte` oracle, followed by a full forward and backward cursor scan compared with the sorted oracle. This covers 10⁵ or more operations across several commits, with reopens in between.
- **Snapshot isolation:** open a read transaction, commit more writes, and verify that the reader still sees the old state, including through a cursor scan, and that a new reader sees the new state.
- **Zero-copy:** check that returned slices fall inside the `[map_base, map_base + map_size)` range, and use a tracking allocator to show that read paths allocate nothing (NFR-001).
- **Map full:** a small `map_size` produces `Map_Full`, the transaction can be aborted, and the database reopens intact.

### Deferred
Killing the process during commit, and long fuzzing runs, belong to step 7.

## Alternatives Considered

- **Sibling pointers in leaves for scans:** rejected. Under copy-on-write, changing one leaf would force copies of its neighbours; the cursor's parent stack gives the same traversal.
- **Writable shared mmap (like LMDB's `WRITEMAP`):** rejected. With a read-only map, stray writes can't corrupt the file, and it keeps the platform layer simple.
- **Writing dirty pages straight into the file during `put`:** rejected for now. It complicates abort, and step 6's spilling covers the memory concern properly.
- **Remapping as the file grows:** rejected, because it would invalidate zero-copy slices. We reserve `map_size` once instead.
- **Storing cursor pointers instead of page numbers:** rejected, because pointers go stale when a page is touched in a write transaction.

## Implementation Plan

Planned tasks, created at decompose time:

1. **Types, platform layer and on-disk structs:** `types.odin`, `os_darwin.odin` and `os_linux.odin`, the page and meta layouts, and the meta checksum (`xxhash.XXH64`).
2. **Open and close:** create or open, validate and choose a meta page, reserve the mmap, `MADV_RANDOM`; meta-page fallback tests.
3. **Page layer:** slotted-page operations and binary search, with unit tests.
4. **Read path:** `txn_begin` and `txn_abort` for read transactions, `page_ptr`, search, `get` (tested against a hand-built file).
5. **Write path:** write transaction, dirty map, touch, allocation, insert and overwrite, leaf, branch and root splits.
6. **Overflow values:** allocation, write and zero-copy read.
7. **Commit protocol:** growing the file, ordered `pwrite` and sync, writing the meta page, publishing the snapshot; `Map_Full` handling.
8. **Cursors:** `first`, `last`, `seek`, `next` and `prev` in read and write transactions.
9. **Model-check and snapshot-isolation tests,** and zero-allocation verification.

**Exit criteria:** all requirements REQ-001 to REQ-009 and NFR-001 to NFR-005 are met, and every test above passes on macOS and Linux.

## Results (2026-09-24)

All nine tasks (KV-T-0001 to KV-T-0009) are complete. The suite of 79 tests passes on macOS arm64 (debug, speed, ASan; TSan for the threaded test) and on Linux arm64 and amd64 (debug, speed). Each task's status section records its detailed decisions and deviations.

### Exit criteria

| Requirement | Status | Evidence |
|---|---|---|
| REQ-001 open or create, validation | ✓ | `env_test.odin` (create/reopen, bad magic, not a database, truncated) |
| REQ-002 newest valid meta page wins | ✓ | `env_test.odin` (highest txn, fallback both ways, page-size probing), `commit_test.odin` (fallback after commits) |
| REQ-003 zero-copy `get` | ✓ | `read_test.odin`, `alloc_test.odin` (slices in the map), `write_test.odin` (dirty pages) |
| REQ-004 `put`, `Key_Too_Large`, `Txn_Read_Only` | ✓ | `write_test.odin` |
| REQ-005 overflow values, one slice | ✓ | `overflow_test.odin`, `commit_test.odin` (after reopen) |
| REQ-006 atomic durable commit; abort | ✓ | `commit_test.odin`, `model_test.odin` (346 commits, 63 aborts) |
| REQ-007 snapshot isolation | ✓ | `commit_test.odin`, `isolation_test.odin` (4 threads, 100 commits) |
| REQ-008 cursors in both transaction types | ✓ | `cursor_test.odin`, `model_test.odin` |
| REQ-009 file growth, `Map_Full`, abortable | ✓ | `commit_test.odin`, `write_test.odin`, `model_test.odin` (until the map is full) |
| NFR-001 reads allocate nothing | ✓ | `alloc_test.odin`, `read_test.odin`, `cursor_test.odin` |
| NFR-002 value-type cursor, fixed stack | ✓ | `Cursor` holds a `Path` with `[MAX_DEPTH]Path_Entry`; covered by the zero-allocation tests |
| NFR-003 single page access path | ✓ | `page_ptr` (overflow runs use the validated `overflow_value`) |
| NFR-004 `F_FULLFSYNC` / `fdatasync` | ✓ | `os_darwin.odin`, `os_linux.odin` |
| NFR-005 little-endian format | ✓ | `u16le`, `u32le`, `u64le` structs with `#assert`ed layout |

### Deviations from this design, for review
- **Page header:** the 2 reserved bytes come before `lower`/`upper`, so `overflow_count` is 4-byte aligned (KV-T-0001).
- **`max_key`:** 1002 bytes at 4 KiB. The overhead is 16 bytes (an overflow leaf node), not the branch node's 10 (KV-T-0003).
- **New errors:** `Locked`, `Invalid_Argument`, `Out_Of_Memory` (KV-T-0001, KV-T-0002, KV-T-0005).
- **Map size:** `map_size` defaults to 1 GiB, and is enlarged at open to cover an existing file (KV-T-0002).
- **Split protocol:** `split_point` works on the virtual sequence with the new node included. Rebuilding a page uses a 32 KiB stack scratch buffer (KV-T-0003).
- **Write state:** stored on the heap (`Txn.write`), because `Txn` is returned by value. `put` checks `Map_Full` up front, and failures part-way through poison the transaction (KV-T-0005).
- **Loose pages:** replaced overflow runs that this transaction wrote are dropped from the dirty map and recorded as `loose` (KV-T-0006).
- **Cursor:** it has an explicit `Cursor_State` (LMDB-style edge behaviour) and a public `cursor_stale`. `Path_Entry.idx` is an `int` (KV-T-0004, KV-T-0008).
- **Commit** always ends the transaction. A failed final sync leaves the on-disk outcome undetermined, as in LMDB (KV-T-0007).
- **Caller restrictions:** `put` must not be given slices into the same transaction's dirty pages. `get` and cursor slices from a write transaction are invalidated by the next `put`.

### Known limitations, planned for later steps
- **No page reuse** (step 5): the file grows with every commit, and `freed`/`loose` are recorded but not yet used.
- **No delete** (step 4).
- **No memory budget, spilling or eviction** (step 6). Dirty pages and large values are held in the arena until commit.
- **No crash testing** (kill during commit) or long fuzzing runs (step 7).
- **Initialising a new file isn't crash-safe:** a crash during initialisation leaves a file that opens as `Corrupted`, and the parent directory isn't synced after creation.