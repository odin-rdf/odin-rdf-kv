---
id: odin-rdf-kv
level: vision
title: "odin-rdf-kv"
short_code: "KV-V-0001"
created_at: 2026-09-23T22:01:04.716865+00:00
updated_at: 2026-09-23T22:03:30.654937+00:00
archived: false

tags:
  - "#vision"
  - "#phase/published"


exit_criteria_met: false
initiative_id: NULL
---

# odin-rdf-kv Vision

## Purpose

Build a simple, memory-efficient, embeddable key/value store in Odin, modelled on LMDB's core ideas: a copy-on-write B+tree in a single memory-mapped file, zero-copy reads, and crash safety without a write-ahead log.

It runs **inside a host process that also holds other data sources in memory**. The store must therefore limit its own memory use, because no process-wide limit (cgroup, rlimit) can be applied. The goal is a database much larger than its memory budget (for example 100 MB on disk, about 20 MB resident), with the OS paging data in on demand.

## Product/Solution Overview

An Odin library (no server) that gives the host application:

- `put`, `get` and `del` on byte-string keys and values, sorted by `memcmp` order.
- Cursors with `first`, `last`, `seek` (first key ≥ k), `next` and `prev`. A range scan is `seek(start)` followed by `next` until the key reaches `end`.
- **Zero-copy reads:** `get` and cursors return `[]byte` slices that point straight into the memory-mapped file.
- Snapshot isolation: many concurrent readers and one writer, with neither blocking the other.
- A configurable, store-scoped memory budget, with statistics the host can inspect.

The upstream C sources in `liblmdb/` are a reference for comparison. This design keeps LMDB's core and intentionally drops much of its complexity.

## Current State

- The design was discussed and agreed in conversation (2026-09-23). It is recorded here.
- KV-I-0001 (build steps 1–3) is implemented in the `kv` package (2026-09-24): the file format, open with meta-page selection, read and write transactions with copy-on-write, overflow values, commit, and cursors. It has 79 tests on macOS and Linux.
- KV-I-0002 (build step 5, page reuse) is implemented (2026-09-24) and completed after review: a reader table, a persistent free list rewritten at every commit, reuse of freed pages under the horizon `min(oldest reader, S − 1)`, `space_check`, and `env_stats`. The suite has 107 tests on macOS and Linux. Its Results section has the evidence and the measurements:
  - **Page reuse criterion:** with no readers the file stays bounded instead of growing with every commit. Under a random workload it follows the high-water mark of the data plus the pages in flight, which still rises now and then, ever more rarely: from 352 pages of data, about 490 after 10⁴ commits and 500 after 10⁵.
  - **The flat free list's rewrite cost** is about 4.5 ns per record, under 1% of a synced commit up to 10⁴ records, so the extent fallback isn't needed for cost. Placing the list's own run in a fragmented pool, and linear run searches, are the known weak points (backlog: KV-T-0014, KV-T-0015). *(KV-T-0014, 2026-09-24: the run may now have one page of slack, which ends the growth after a long reader. A pool with no two consecutive free pages still extends the file by the whole run. KV-T-0015, 2026-09-24: a write transaction remembers what its run searches proved, so only its first search scans a fragmented pool: a repeated search at 10⁵ scattered records takes 121 → 0.58 µs.)*
- KV-I-0003 (build step 4, delete with merge) is implemented (2026-09-24): `del` removes a key and its overflow run, merges an underfull page with a sibling when they fit (the sibling merges into the already-copied page, so a delete needs at most `depth` new pages), drops empty pages and collapses the root. There is no borrowing. The suite has 132 tests on macOS and Linux. Its Results section has the evidence:
  - **Page reuse under churn:** inserting and deleting over a moving key set keeps the file bounded (352 pages loaded, 368–373 after 10⁴ commits, none added in the second half).
  - **Fill after deletes:** about 40% after random deletes against 70% for an insert-only tree of the same keys, so 1.6–1.8× the leaves, but no leaf below 25% in the measurement.
- The memory budget (step 6) and crash testing (step 7) remain.
- Toolchain: Odin `dev-2026-09`. The development platform is macOS (Darwin). Linux is also a target.

## Future State

A tested, crash-safe Odin library that:

1. Stores data in one file: a copy-on-write B+tree with dual meta pages.
2. Serves all reads zero-copy from a read-only mmap, with no allocation.
3. Keeps its resident mapped pages within a configurable soft budget and its write-side memory within a hard budget, whatever else the host process is doing.
4. Reclaims freed pages safely while readers hold older snapshots.
5. Always reopens at the last committed state after a crash, with no recovery step.

## Key Design Decisions

### Storage format
- **Page size:** fixed; the OS page size, 4 KiB by default.
- **Meta pages:** pages 0 and 1 are meta pages, written alternately. A meta page holds: magic, version, page size, `txn_id`, root page number, depth, entry count, `last_pgno`, the free-list location and its count, and a checksum. At open, the valid meta page with the highest `txn_id` wins.
- **Slotted pages:** a header (`pgno`, flags, `lower`, `upper`), then sorted `u16` slot offsets growing up, with nodes growing down from the end of the page.
- **Leaf nodes:** `key_len: u16`, `flags: u16`, `val_len: u32`, the key, then the value inline or an overflow page number (`BIGDATA` flag).
- **Branch nodes:** `child_pgno: u64`, `key_len: u16`, the key. The key in slot 0 is treated as −∞.
- **Overflow pages:** values larger than about `page_size / 4` are stored in a *contiguous* run of overflow pages, so a zero-copy slice covers the whole value.
- **Maximum key size:** capped so that every page (branch or leaf) always holds at least 4 nodes: 1002 bytes at 4 KiB pages.
- **Odin conventions:** on-disk fields use `u16le`, `u32le` and `u64le`. `Pgno` and `Txn_Id` are `distinct u64`.

### Memory map and I/O
- **One reservation:** a single read-only `MAP_SHARED` mmap reserves `map_size` of address space at open and is never remapped, so slices stay valid while the file grows. Exceeding it returns `Map_Full`.
- **Writes:** the writer uses `pwrite` on the file descriptor. macOS and Linux keep the mmap coherent with it.
- **Durability:** `fcntl(F_FULLFSYNC)` on Darwin; `fsync` on Linux.
- **Readahead:** `MADV_RANDOM` is applied to the whole map to disable it.

### Transactions and concurrency
- **Scope:** one process, many threads. Multi-process access (a lock file with a shared reader table) is out of scope.
- **Read transaction:** under a brief mutex, copy the in-memory snapshot and register its `txn_id` in the reader table. The transaction holds no locks after that.
- **Write transaction:** a writer mutex allows one writer at a time. A dirty-page map is checked before the mmap on every lookup. Pages are touched (copied on write) top-down along the cursor path.
- **Commit:**
  1. Write the free list.
  2. `pwrite` the dirty pages, then sync.
  3. Write the other meta page (`txn_id + 1`), then sync.
  4. Publish the new snapshot.
- **Abort:** discard the dirty pages; nothing on disk has changed.
- **Crash recovery:** at open, discard any meta page with a bad checksum and use the one with the higher `txn_id`. No WAL is needed.

### B+tree operations
- **Cursor:** a value type holding a fixed-depth stack of `(page, idx)` pairs, with no heap allocation. There are no sibling pointers; copy-on-write makes them impractical.
- **Put:** seek, touch the path, then insert. Split when a page is full; splits can cascade up to a new root.
- **Delete:** remove the node, merge with a sibling when a page drops below 25% full, and collapse empty pages and single-child roots. There is no borrowing from siblings.

### Page reclamation
- **Rule:** pages freed by transaction `T` can be reused once every active reader has a snapshot ≥ `T`.
- **Storage:** the free list is a flat, sorted array of `(txn_id, pgno)` records in a contiguous page run, rewritten on every commit.
  - Its pages come from the reusable pool first. Allocating them only shrinks the list, so there is no recursion as in LMDB's free-list tree.
- **Caveat:** long-lived readers pin old pages, and the file grows until they finish.

### Store-scoped memory budget
- **Mapped pages (soft limit):**
  - **Self-accounting, not OS measurement:** divide the map into aligned chunks of at least 64 KiB (for example 256 KiB), each with two bits, `resident` and `referenced`. `page_ptr` sets `referenced` and switches `resident` on with a compare-and-swap, which increments `resident_chunks`.
  - **Eviction order:** clear the `resident` bit first, then evict the range. A racing reader can then only cause an overestimate, never an underestimate.
  - **Sweeper:** a background thread runs CLOCK at the soft watermark. At the hard watermark, the reader thread that crossed it evicts a few chunks itself.
  - **Eviction:** Linux uses `MADV_DONTNEED`, or `MADV_PAGEOUT` to also leave the page cache. macOS remaps the range over itself with `MAP_FIXED`, because `MADV_DONTNEED` is only a hint there. Eviction never affects correctness: addresses stay valid and pages are faulted back in.
  - **Periodic check against the OS:** Linux uses `/proc/self/pagemap` present bits. It must not use `mincore`, which reports page-cache residency. macOS uses `mincore`, which errs toward overcounting (safe). Verify this empirically.
- **Dirty pages (hard limit):**
  - A fixed pool of dirty-page buffers replaces a per-transaction arena. When it is full, *spill*: `pwrite` the least recently touched leaves to their final, not-yet-visible locations.
  - A page number allocated by the current transaction can be re-touched without copy-on-write.
  - Large values go straight from the caller's buffer to overflow pages with `pwrite`.
  - The pool's memory is committed on demand and released when the writer is idle.
- **Example 20 MB budget:**

  | Component | Budget |
  |---|---|
  | Mapped pages, soft target | about 13–15 MB |
  | Dirty-page pool | 4 MB |
  | Fixed structures | under 1 MB |
  | Headroom | the remainder |

- **Rejected alternatives:**
  - **Process-wide limit** (cgroup `memory.high`): would also constrain the host's other data sources.
  - **Buffer pool instead of mmap:** gives an exact hard cap, but zero-copy slices would only last until the next cursor operation, and the concurrency code gets much more complex. Keep it as a fallback only if an exact limit is ever required.

### Zero-copy lifetime rules
- A slice from a read transaction is valid until that transaction ends.
- A slice from inside a write transaction is invalidated by the next `put` or `del`, or by commit or abort.
- Debug builds check transaction and cursor generation counters and support running under ASan.
- **Inline values have no alignment guarantee.** Callers read fields with unaligned loads rather than casting slices to struct pointers. Overflow values are 16-byte aligned.
- **Integer keys must be encoded big-endian** to sort numerically under `memcmp` ordering.

## Major Features

- **Core API:**

  | Group | Operations |
  |---|---|
  | Environment | `env_open(path, map_size, mapped_budget, dirty_budget, chunk_size, …)`, `env_close`, `env_stats` |
  | Transactions | `txn_begin(env, read_only)`, `txn_commit`, `txn_abort` (a no-op after commit, so `defer txn_abort` is idiomatic) |
  | Data | `get`, `put`, `del` |
  | Cursors | `cursor_open` (returns a value), `cursor_first`, `cursor_last`, `cursor_seek`, `cursor_next`, `cursor_prev` |

- **Errors:** an `Error` enum (`None`, `Not_Found`, `Map_Full`, `Key_Too_Large`, `Corrupted`, `Io`, `Txn_Read_Only`, `Locked`, `Invalid_Argument`, `Out_Of_Memory`) returned as multiple return values, which works with `or_return`.
- **Statistics:** `env_stats` reports the resident estimate, dirty pages, spills, evictions and fault rate, so the host can see the store's share of memory.

## Planned Build Order

1. Page and meta layout, open, mmap, and read-only search.
2. Write transaction, touch, insert and split, and commit with dual meta pages, always extending the file.
3. Cursors and range scans.
4. Delete with merge.
5. Free list and reader table for page reuse.
6. Memory budget: dirty-page pool with spilling, chunk accounting, sweeper, and platform-specific eviction.
7. Crash tests (kill the process during commit) and fuzzing against a `map[string]string` oracle.

## Success Criteria

- **Crash safety:** after a kill during any phase of commit, the database always reopens at the last committed state.
- **Correctness:** fuzzed operation sequences match the oracle, including range scans in both directions.
- **Zero allocation on reads:** reads allocate nothing and copy no data; returned slices point into the mmap.
- **Memory budget:** with a database of about 100 MB and a 20 MB budget, the store's resident footprint (mapped estimate plus dirty pool), checked against the OS, stays within about 1–2 chunks of the budget under mixed read, scan and write loads.
- **Page reuse:** with no long-lived readers, the file stops growing under steady-state updates.
- Runs on both macOS and Linux.

## Principles

- **Simplicity over completeness:** keep LMDB's core ideas and drop features we don't need.
- **Readers never block writers, and writers never block readers.**
- **Zero-copy reads are non-negotiable;** trade other things for them.
- **Memory is budgeted per store,** never per process, so the store can live alongside other in-memory data.
- **Evicting pages must never affect correctness,** only performance.
- **Crash safety comes from ordering and checksums,** not from logs or recovery code.
- **Use Odin idioms:** explicit allocators, `distinct` types, `or_return`, and value-type cursors.

## Constraints

- Single process only. Multi-process access is out of scope for now.
- No named sub-databases, duplicate keys, nested transactions or prefix compression in the first version.
- Only one writer at a time.
- 64-bit targets only.
- The memory budget for mapped pages is approximate (soft), and the address-space reservation (`map_size`) is fixed at open.
- Long-lived read transactions prevent page reuse and make the file grow.
- The host process's memory cannot be limited; the store can only limit its own.
- Eviction behaviour on macOS (remapping with `MAP_FIXED`, `mincore` semantics) needs to be verified empirically on the development platform.