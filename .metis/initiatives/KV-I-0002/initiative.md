---
id: page-reuse-free-list-and-reader
level: initiative
title: "Page reuse: free list and reader table"
short_code: "KV-I-0002"
created_at: 2026-09-24T09:58:51.754782+00:00
updated_at: 2026-09-24T11:25:55.358165+00:00
parent: KV-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: M
initiative_id: page-reuse-free-list-and-reader
---

# Page reuse: free list and reader table Initiative

## Context

This initiative is build step 5 of the vision (KV-V-0001): reclaim pages freed by copy-on-write and reuse them without disturbing readers that still hold older snapshots.

After KV-I-0001 the file grows with every commit. Every `put` copies its whole root-to-leaf path, so a steady stream of small updates adds about `depth` pages per commit, forever. Replaced pages are already recorded (`Write_State.freed`, and `loose` for overflow runs this transaction wrote and then replaced), and the meta page already reserves `freelist_pgno` and `freelist_count`. Nothing reads them yet.

The vision's rule is: pages freed by transaction `T` can be reused once every active reader has a snapshot ≥ `T`. The free list is a flat, sorted array of `(txn_id, pgno)` records in a contiguous run, rewritten on every commit, whose own pages come from the reusable pool first.

Step 4 (delete with merge) is not a prerequisite. Delete will free pages through the same `freed` list, so it slots in afterwards without changes here.

## Goals & Non-Goals

**Goals:**
- A **reader table**, so a writer knows the oldest snapshot still in use.
- A **persistent free list:** written at commit, loaded and validated at open.
- **Page reuse:** the writer allocates from reusable pages before extending the file, for single pages and for contiguous overflow runs.
- **Crash safety as before:** after a crash at any point, the database opens at the last commit. Falling back to the older meta page (`test_commit_falls_back_when_newest_meta_damaged`) still finds an intact tree.
- **A space-accounting check:** every page is owned exactly once, by the tree, the free list or the free list's own run. This is the main correctness evidence.
- Meet the vision's success criterion: *with no long-lived readers, the file stops growing under steady-state updates.*

**Non-Goals:**
- **Shrinking the file:** free pages at the end of the file stay allocated. `last_pgno` never decreases.
- **Multi-process readers:** the reader table is in memory only. The vision puts multi-process access out of scope.
- **Mitigating long-lived readers:** they still pin pages and make the file grow (a vision caveat). This initiative only reports them through `env_stats`.
- **Delete** (step 4), the **memory budget and spilling** (step 6) and the **kill-during-commit harness** (step 7).
- **A free-list tree or extent encoding:** the flat list is the vision's decision. Its cost is measured here, and an extent encoding is recorded as the fallback (see Alternatives).

## Requirements

### Functional requirements
- **REQ-001:** a read transaction registers its snapshot's `txn_id` in the reader table in `txn_begin`, under the same lock that copies the snapshot, and deregisters in `txn_abort` or `txn_commit`.
- **REQ-002:** a page freed by transaction `T` is reused only when `T ≤ oldest`, where `oldest = min(oldest registered reader, S − 1)` and `S` is the snapshot the writer began from. The `S − 1` term is decision D1.
- **REQ-003:** `txn_commit` writes the free list (every pending and reusable page, tagged with the transaction that freed it) to a contiguous run and records it in the meta page (`freelist_pgno`, `freelist_count`).
- **REQ-004:** `env_open` loads the free list of the chosen meta page and validates it. A malformed list returns `Corrupted`.
- **REQ-005:** `page_alloc` uses reusable pages before extending the file:
  - for a single page, a loose page first, then the lowest reusable page number;
  - for an `n`-page run, the lowest run of `n` consecutive reusable pages;
  - otherwise it extends the file.
- **REQ-006:** an aborted write transaction leaves the free list exactly as it was. Nothing the transaction took is lost, and nothing it freed is released.
- **REQ-007:** `put`'s up-front `Map_Full` check counts reusable pages. A database at `map_size` still accepts updates while free pages exist.
- **REQ-008:** `env_stats` reports `last_pgno`, reusable and pending free pages, the number of live readers, and the oldest reader's `txn_id`.

### Non-functional requirements
- **NFR-001:** read paths still allocate nothing (KV-I-0001 NFR-001). `txn_begin(ro)` allocates only when the reader table needs more capacity than ever before.
- **NFR-002:** readers never wait for a writer. The reader table and the snapshot share one mutex, which is only ever held for O(live snapshots) work, never across I/O.
- **NFR-003:** no format version bump. Old files (with `freelist_pgno = 0`) open as having an empty free list. A file written by this code and opened by the KV-I-0001 code simply leaks its free pages, which is safe.
- **NFR-004:** with no readers, `last_pgno` stops growing under a steady-state overwrite workload.

## Architecture

### Overview

| File | Change |
|---|---|
| `types.odin` | `PAGE_FREELIST` page flag |
| `env.odin` | Reader table and free state in `Env`; load the free list in `env_open`; `env_stats` |
| `txn.odin` | Register and deregister readers; compute the reuse horizon when a write transaction begins |
| `freelist.odin` (new) | Record layout, load and validate, build and serialize at commit, run search |
| `write.odin` | `page_alloc` takes from loose, then reusable pages, then extends; `pages_available` counts free pages |
| `commit.odin` | Build the free list, allocate its run, write it with the dirty pages, record it in the meta page, then publish the snapshot and the free state together |
| `check.odin` | `space_check` |

### Ownership of state
- **`Env.readers`** (guarded by `snapshot_mutex`): sorted `[dynamic]Reader_Slot{txn_id, count}`. Snapshots are published in increasing order, so a new reader either increments the last slot or appends one. `readers[0]` is the oldest.
- **`Env.free`** (owned by the writer; guarded by `writer_mutex`): the committed free state.
  - `ready`: sorted page numbers that are reusable now.
  - `pending`: `(txn_id, pgno)` records ordered by `txn_id`, waiting for readers.
- **The write transaction** never changes `Env.free` until its commit is durable. It records what it takes from `ready` and what it frees, and at commit it builds the new state in its arena. Abort just drops that record, which is REQ-006 for free.
  - Moving pending records with `txn_id ≤ oldest` into `ready` at `txn_begin(rw)` is the one exception. It's a valid transformation whatever the transaction does later, so it's done in place.

### Sequence: write transaction with reuse
1. `txn_begin(rw)`: take the writer mutex, then under `snapshot_mutex` copy the snapshot and read `readers[0]`. Compute `oldest = min(readers[0], S − 1)` and move eligible `pending` records into `ready`.
2. `put` / `page_touch` / `overflow_write` call `page_alloc`, which takes a loose page, then a `ready` page (or run), then extends. The old pages go to `freed` as before.
3. `txn_commit`:
   1. Build the new list: `ready` minus what was taken, plus unused loose pages (both tagged 0, meaning *reusable*); then `pending`; then this transaction's `freed` pages and the old free-list run (tagged `S + 1`).
   2. Allocate the run for it: `k = pages for n records`, from a contiguous reusable run if one exists (which removes `k` records, so `k` pages still suffice), otherwise by extending the file. There's no fixed-point iteration.
   3. Write the dirty pages and the run in page order, then sync. Write the meta page with `freelist_pgno`/`freelist_count`, then sync.
   4. Publish the snapshot under `snapshot_mutex`, and replace `Env.free` with the new state (copied out of the arena with the env allocator).

## Detailed Design

### Decisions
D1–D6 were approved as proposed on 2026-09-24.

- **D1: keep snapshot `S − 1` intact.** The vision's rule alone would let transaction `S + 1` reuse pages freed by `S`, which are still part of `S − 1`. The meta slot `S + 1` is about to overwrite still holds `S − 1`, and it's what `env_open` falls back to if meta `S` is ever unreadable. Treating `S − 1` as a reader (LMDB does the same) keeps that fallback valid. The cost is that pages wait one extra commit. `test_commit_falls_back_when_newest_meta_damaged` must keep passing with reuse active.
- **D2: reader table as a mutex-guarded sorted array** keyed by snapshot, with a count per snapshot. LMDB instead uses fixed, lock-free per-thread slots, which matter for multi-process access and bring a `Readers_Full` limit. Here the vision already has readers take `snapshot_mutex` briefly in `txn_begin`, so registering costs one more increment under that lock. Deregistering takes the lock too, once per read transaction.
- **D3: flat records, as the vision says.** Each record is 16 bytes, `pgno: u64le` then `txn_id: u64le`, sorted by `(txn_id, pgno)`. Tag 0 means *reusable*. The run is laid out like an overflow run: a `Page_Header` with `PAGE_FREELIST` and `overflow_count`, then the records from offset 16 across contiguous pages.
  - Tags must survive a reopen for D1's sake. At open (no readers), every record with `txn_id < S` is reusable, and those tagged `S` stay pending.
- **D4: compute the horizon once, at `txn_begin(rw)`.** A reader that finishes mid-transaction isn't noticed until the next write transaction. This keeps allocation deterministic in tests and lock-free. Rescanning on the growth path is a later option if measurements ask for it.
- **D5: lowest page numbers first.** Single pages come from the front of `ready`, and runs are first-fit. This keeps live data toward the start of the file, which suits the non-goal of never shrinking it, and a later compaction step.
- **D6: commit can return `Map_Full`.** If the free-list run can't be placed, neither in reusable pages nor by extension, the commit fails and the database stays at `S`. That only happens with the map full and no free run, and it's tested.

### Free-list validation at open
- The run must lie in `[2, last_pgno]`, its header must have `PAGE_FREELIST` and record its own page number, and `overflow_count` must equal `overflow_pages(16 × count)`.
- Records must be strictly ordered by `(txn_id, pgno)`, with `txn_id ≤ S` and `pgno` in `[2, last_pgno]`. No page may appear twice (checked while merging into `ready`), and none may lie inside the run itself.
- A bad list returns `Corrupted`. It doesn't fall back to the other meta page, because a valid checksum with a bad list means a bug, not a torn write.
- `freelist_pgno = 0` requires `freelist_count = 0`, which is how every KV-I-0001 file looks (NFR-003).

### `space_check(txn)`
Walks the tree like `tree_check`, then marks the free-list run and every record in the free list (plus, in a write transaction, the pages taken or freed so far). It requires that every page in `[2, last_pgno]` is marked exactly once. It runs in tests after every commit, and it's the check that catches a leaked or doubly-owned page.

### `Map_Full` accounting (REQ-007)
`pages_available(txn, singles, run)` succeeds when the overflow run (if any) fits in a contiguous reusable run or at the end of the map, and the remaining single pages fit in loose pages, plus reusable pages not used for that run, plus the room left at the end of the map. It stays conservative, so a `put` that passes can't hit `Map_Full` part-way.

### Costs, to be measured
- **Commit** rewrites the whole list: 16 bytes per free page. At a 100 MB database with 10% free, that's about 40 KiB, or 10 pages per commit. KV-T-0013 measures commit time against list size, and the result decides whether the extent fallback is needed.
- **Resident memory for the free state:** 8 bytes per reusable page and 16 per pending one, allocated with the env allocator.

## Testing Strategy

- **Unit tests:**
  - reader table register, deregister and oldest, including many readers on one snapshot;
  - free-list serialization round-trip;
  - every validation rule at open, using hand-written runs;
  - first-fit run search;
  - `space_check` catching a deliberately leaked page and a deliberately doubled one.
- **Reuse rules:**
  - a page freed by `T` is not reused while a reader holds `T − 1`, and is reused after it ends;
  - pages freed by `S` are not reused by `S + 1` (D1);
  - loose pages are reused within the transaction;
  - an abort leaves `Env.free` unchanged.
- **Crash-safety equivalents** (without killing a process):
  - the damaged-newest-meta fallback test with heavy reuse in between;
  - an I/O error during commit leaves both the free state and the file at `S`;
  - reopening restores exactly the free list that was committed.
- **Model test:**
  - `space_check` after every commit and reopen;
  - random readers held across a random number of commits, each checked at release against its snapshot's oracle state, including a full scan;
  - a reader-free phase to show the plateau.
- **Steady state:**
  - overwriting a fixed key set for 10⁴ commits keeps `last_pgno` bounded;
  - with one long-lived reader the file grows, then stops growing after the reader ends.
- **Threads:** the isolation test runs with reuse active and readers starting and ending continually. It runs under `-sanitize:thread` on macOS arm64.
- **Map full:** a database at `map_size` keeps accepting overwrites, and a commit that can't place its free-list run returns `Map_Full` and leaves the database intact.
- **Deliberate-bug checks** (working agreement), each confirmed to fail a test:
  - drop the `S − 1` term;
  - use `<` instead of `≤` in the horizon;
  - skip deregistration;
  - forget to free the old run;
  - release taken pages on abort.
- **Build matrix:** `scripts/test.sh` (debug, speed, ASan, cross-`odin check`) and `scripts/test-linux.sh` on arm64 and amd64.

## Alternatives Considered

- **LMDB-style free-list B+tree** (the free DB): rejected by the vision. Allocating its own pages recurses, and LMDB's history of free-list bugs comes from exactly that. A flat run needs no recursion: taking its pages only shrinks it.
- **Extent records `(txn_id, start, count)`:** smaller when free pages cluster, as they do for overflow runs and whole freed subtrees. It's the fallback if KV-T-0013 finds the rewrite cost significant. The meta fields and run layout would stay the same, with only a record format bump.
- **Pages only, without `txn_id`, on disk:** reopening has no readers, so the tags look unnecessary. They're kept because D1 needs to know which pages `S` freed after a reopen.
- **Lock-free reader slots (LMDB):** see D2. They're only worth their fixed limit and complexity with multiple processes.
- **Chained free-list pages instead of a contiguous run:** any single reusable page would do, so no contiguity search. It was rejected to keep one run layout shared with overflow values and a single `pwrite`. Reconsider it if run placement fails in practice.
- **Rescanning readers during a write transaction:** see D4. It was deferred.

## Implementation Plan

The tasks were created at decompose time (2026-09-24), with one commit per task:

1. **KV-T-0010, reader table:**
   - `Reader_Slot`, register and deregister in `txn_begin`/`txn_abort`, `oldest_reader`;
   - unit and threaded tests;
   - `txn_begin(ro)` allocation behaviour (NFR-001).
2. **KV-T-0011, persistent free list without reuse:**
   - `PAGE_FREELIST`, `freelist.odin`;
   - commit writes `freed` and loose pages plus the previous run, extending the file for the run;
   - `env_open` loads and validates it;
   - `space_check`.
   - The file still grows, but every page is now accounted for, and `space_check` passes after every commit in the existing model test.
3. **KV-T-0012, reuse:**
   - the horizon with D1 at `txn_begin(rw)`;
   - `page_alloc` from loose pages and `ready`, with first-fit runs;
   - the free-list run placed in reusable pages;
   - `Map_Full` accounting (REQ-007) and D6;
   - abort semantics;
   - the reuse-rule and fallback tests.
4. **KV-T-0013, verification and stats:**
   - `env_stats`;
   - the model test with held readers;
   - steady-state and long-reader tests;
   - threaded isolation with reuse under TSan;
   - commit-cost measurement against free-list size;
   - the Linux runs;
   - update the vision's Current State, `CLAUDE.md` and this document's Results.

**Exit criteria:** REQ-001 to REQ-008 and NFR-001 to NFR-004 are met, `space_check` passes after every commit in every test that commits, and the full matrix passes on macOS and Linux.