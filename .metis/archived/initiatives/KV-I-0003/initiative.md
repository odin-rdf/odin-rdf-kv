---
id: delete-with-merge
level: initiative
title: "Delete with merge"
short_code: "KV-I-0003"
created_at: 2026-09-24T16:17:57.045959+00:00
updated_at: 2026-09-24T18:26:18.876854+00:00
parent: KV-V-0001
blocked_by: []
archived: true

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: false
estimated_complexity: M
initiative_id: delete-with-merge
---

# Delete with merge Initiative

## Context

This initiative is build step 4 of the vision (KV-V-0001): `del(txn, key)`. The vision's rule is: *remove the node, merge with a sibling when a page drops below 25% full, and collapse empty pages and single-child roots. There is no borrowing from siblings.*

It comes after step 5 (KV-I-0002), which is what makes it cheap now. Replaced pages already go to `Write_State.freed`, and pages this transaction wrote and then dropped go to `loose` (`overflow_free` already does both). So a page that delete frees is reused through the existing free list, and page reuse needs no changes. `space_check` already proves every page has exactly one owner after each commit, and a missing free is exactly what it catches.

What exists to build on:
- **`put`** (`write.odin`): search, touch the path top-down (`page_touch`), change the leaf, split upwards (`insert_node`), and check `Map_Full` up front (`pages_available`). Delete follows the same shape in reverse.
- **The page layer** (`page.odin`): `node_remove` compacts in place; `page_move_upper` rebuilds a page from a stack copy. Merging is the same rebuild in the other direction.
- **Checks:** `tree_check` already forbids an empty leaf below the root and an empty branch, and checks every key against its separators.
- **Cursors** are invalidated through `txn.mods`, which `del` bumps as `put` does.

## Goals & Non-Goals

**Goals:**
- `del` with the vision's semantics: remove a key and its value (inline or overflow run), merge underfull pages, drop empty ones, and collapse the root.
- Delete stays inside the existing copy-on-write and page-reuse machinery: every page it frees is reused, `space_check` passes after every commit, and aborting leaves nothing behind.
- A tree emptied by deletes is the empty tree (`root = 0`), with every page it used back on the free list.
- Under insert/delete churn with no readers, the file stays bounded (the vision's page-reuse criterion, extended to deletes).
- The randomized model test gains `del`, so the oracle covers it, including range scans in both directions.

**Non-Goals:**
- **Borrowing from siblings** (the vision rules it out). A page that is underfull but can't merge stays underfull.
- **A cursor delete** (`cursor_del`) or a range delete. After `del`, a cursor is repositioned with `cursor_seek`/`cursor_first`, as after `put`. Both could be added later on top of `del`.
- **Shrinking the file** or compacting it: freed pages go to the free list, as before.
- **Updating separators** when a leaf's first key is deleted: a separator only has to be a lower bound, and it still is (D6).
- The memory budget (step 6) and the crash harness (step 7).

## Requirements

### Functional requirements
- **REQ-001:** `del(txn, key) -> Error` removes `key` and its value. If `key` is absent it returns `Not_Found` and changes nothing: no page is copied, `txn.mods` doesn't move (cursors stay valid) and `txn.err` isn't set.
- **REQ-002:** on a read-only transaction `del` returns `Txn_Read_Only`. A transaction already failed returns its `txn.err`, as `put` does. A failure after the tree has started to change makes the transaction unusable, as with `put`.
- **REQ-003:** a value in an overflow run has its run freed: to `loose` if this transaction wrote it, otherwise to `freed` (`overflow_free`).
- **REQ-004:** after every `del`, no page below the root is empty, and a page that dropped below the threshold (D4) has been merged with a sibling whenever the two fit in one page.
- **REQ-005:** a root branch with one child is collapsed (repeatedly), and deleting the last key gives `root = 0`, `depth = 0`, `entries = 0`. `snapshot.entries` drops by one per deleted key.
- **REQ-006:** `del` returns `Map_Full` up front, changing nothing, unless `depth` single pages are available (D2). A map at `map_size` with reusable or loose pages still accepts deletes.
- **REQ-007:** `key` may point into this transaction's own pages, for example a slice from `get` or a cursor in the same write transaction. `del` reads the key only while searching, before anything changes. This is unlike `put`, and it's what makes "delete the key the cursor is on" safe.
- **REQ-008:** `del` invalidates the transaction's cursors and earlier slices, like `put` (the vision's lifetime rule already says so).

### Non-functional requirements
- **NFR-001:** `del` allocates nothing on the heap except through `page_alloc` (the path copies) and the `freed`/`loose` lists. Merges rebuild pages in a stack scratch page, as `page_move_upper` does.
- **NFR-002:** no format change. Files written with deletes open with the KV-I-0002 code, and the other way round.
- **NFR-003:** readers are unaffected: a read transaction that began before a `del` commit still sees every deleted key, including through its overflow run, until it ends (copy-on-write plus the KV-I-0002 reuse horizon).
- **NFR-004:** with no readers, `last_pgno` stays bounded under a steady insert/delete workload over a changing key set.

## Architecture

| File | Change |
|---|---|
| `page.odin` | Merge primitives: move all of one page's nodes to the front or back of another, giving a branch's slot-0 node a key on the way; make a branch's slot 0 −∞ after its first node is removed; the fill threshold and the fit test |
| `write.odin` (or a new `delete.odin`, decided in the first task) | `del`, `page_free` (a page to `loose` if dirty, else to `freed`), the rebalance loop, and root collapse |
| `check.odin` | No new invariant is expected (see D1). `tree_check` already rejects the states a broken delete would leave |
| `tests/delete_test.odin` (new) | Shape tests built with `build_tree_file` |
| `tests/model.odin`, `tests/model_test.odin`, `tests/steady_test.odin` | `del` in the randomized model and a churn steady state |

### Sequence: `del`
1. Check read-only, `txn.err`, then `tree_search`. Absent key → `Not_Found`, nothing changed (REQ-001).
2. Check `pages_available(txn, depth)` → `Map_Full` otherwise (D2, REQ-006).
3. `txn.mods += 1`; touch the whole path top-down (`page_touch`), as `put` does.
4. At the leaf: free the overflow run if any (`overflow_free`), `node_remove`, `entries -= 1`.
5. Rebalance upwards, from the leaf to level 1 (D3, D4, D5):
   1. If the page is empty: free it and remove its slot from the parent; if that was the parent's slot 0, make the new slot 0 −∞. Go on to the parent.
   2. Else if it isn't below the threshold, stop.
   3. Else try the right sibling, then the left one (within the same parent). If the two fit in one page, move the sibling's nodes into the page on the path (appended from the right, prepended from the left), free the sibling, and remove one slot from the parent (the right sibling's; or, for a left sibling, point the left slot at the path page and remove the path page's own slot). Go on to the parent.
   4. Else stop.
6. At the root: while it is a branch with one child, free it and make the child the root (`depth -= 1`). If it is an empty leaf, free it and set `root = 0`, `depth = 0`.

## Detailed Design

### Decisions
D1–D8 were approved as proposed on 2026-09-24.


- **D1: no borrowing, so the only fill guarantee is "not empty".** The vision rules borrowing out. An underfull page whose siblings are too full to merge stays as it is, and so can a branch with a single child below the root (its parent's merge didn't fit). The tree stays balanced (all leaves at one depth) and correct; it can just be less full than a B-tree with borrowing. `tree_check` keeps its current rules (no empty leaf below the root, no empty branch) and gains no fill check, because none is guaranteed. How full trees get after random deletes is measured in the last task, not asserted.
- **D2: merge the sibling into the page on the path, never the other way round.** Step 3 has already copied the path, so the surviving page is already dirty. The sibling is read and freed, never copied. A delete therefore needs at most `depth` new pages, the path copies, the same as touching the path: that is the up-front `Map_Full` check. Merging the other way would copy one sibling per level, up to `2 × depth − 1` pages, and a delete at a nearly full map would fail more often.
- **D3: the right sibling first, then the left.** Trying both makes a merge more likely than trying one. The rightmost child only has a left sibling, and the leftmost only a right one. (Alternative: try the emptier sibling first. Not worth the extra rule without a measurement.)
- **D4: the threshold is 25% of the usable page**, `page_used(page) < (page_size − 16) / 4`, the same for leaves and branches. Two pages fit together when `used(a) + used(b) + extra ≤ page_size − 16`, where `extra` is the separator key that a branch merge brings down (D6). The loop stops at the first level where nothing changed: a merge or a drop at level `L` removes one slot from `L − 1`, the only page whose fill could have changed. So a delete costs `O(depth)` page rebuilds at most.
- **D5: an empty page is always dropped, even without a sibling.** It can only be removed with its slot in the parent. Merging an empty page is just a drop, and a page whose parent has a single child has no sibling to merge with, so without this rule an empty leaf could survive below the root. Dropping cascades: a parent left with no nodes is dropped in turn, up to the root, where step 6 handles it.
- **D6: separators are never rewritten on delete, and a branch merge brings the parent's separator down.** A separator only has to be ≤ every key in its subtree and > every key to its left, and deleting keys keeps both true. When two branch pages merge, the right one's slot-0 node (−∞) gets the parent's separator for the right page as its key; it's copied to a stack buffer before the parent changes (the clone-before-modify rule). When a parent loses its slot 0, the new slot 0's key is dropped, which is always correct for the leftmost child.
- **D7: `del` never allocates a page for a missing key,** and reads its key only during the search (REQ-001, REQ-007). The search happens before the path is touched, so a miss costs a lookup and nothing else.
- **D8: freeing goes through one helper, `page_free(txn, pgno)`:** a page in `dirty` is removed from it and goes to `loose`; otherwise it goes to `freed`. `overflow_free` already does this for runs; a single page is the same with a count of one, so the two share it.

### Map_Full on delete
A delete at a full map with no reusable pages fails with `Map_Full`, as in LMDB: the path has to be copied before anything can be freed, and freed pages only become reusable one commit later (KV-I-0002 D1). Loose pages and reusable pages count (REQ-006), so this only bites a map full of live data. It's documented on `del`, not worked around.

### Deleting while iterating
A cursor is stale after `del`. The supported patterns, documented on `del`:
- Delete everything: `for k, _, err := cursor_first(&c); err == .None; k, _, err = cursor_first(&c) { del(txn, k) or_return }`. This is safe because of REQ-007.
- Delete a range: copy the key, `del`, then `cursor_seek` from the copy.

## Testing Strategy

- **Page layer:** the merge primitives on leaf and branch pages (append, prepend, separator brought down, slot 0 made −∞), each followed by `page_check`, and the fit test at its exact boundary.
- **Shapes,** built with `build_tree_file` on a committed tree so copy-on-write runs, then `tree_check` and `space_check` after the commit:
  - a delete that leaves the leaf above the threshold (no merge);
  - merge with the right sibling, and with the left one (the rightmost child);
  - an underfull page whose siblings are both too full (no merge, D1);
  - a branch merge, checking the separator brought down;
  - an empty leaf under a single-child parent (D5 cascade);
  - a cascade up to a root collapse, and a collapse of several single-child levels;
  - deleting the last key (empty tree, every page on the free list after the next commits);
  - a value in an overflow run, from a committed tree and one written in the same transaction (freed vs. loose).
- **Semantics:** `Not_Found` changes nothing (no dirty pages, `mods` unchanged, a cursor still valid); `Txn_Read_Only`; `Map_Full` at a full map without free pages, and success at a full map with them; `del` of a key taken from `get` or a cursor in the same transaction; abort after deletes leaves the database and the free list as they were.
- **Model test:** `del` added to the operation mix (of present keys and absent ones), against the `map[string]string` oracle, with `space_check` after every commit and reopen, held readers checked against their snapshots, and full scans both ways.
- **Readers:** a reader holding a snapshot across a commit that deletes half the keys (some with overflow values) still reads them all; the isolation test gains deletes and runs under `-sanitize:thread`.
- **Steady state:** a churn workload (insert and delete over a moving key set, no readers) keeps `last_pgno` bounded; deleting everything and committing returns the tree to empty with every page free. On demand, with the other steady tests.
- **Measurement:** the fill of leaf and branch pages after deleting 50% and 90% of keys at random, against an insert-only tree, to put a number on D1. Reported, not asserted.
- **Deliberate-bug checks** (working agreement), each confirmed to fail a test:
  - forget to free the merged sibling (`space_check`);
  - forget to bring the separator down in a branch merge (`tree_check`);
  - skip making slot 0 −∞ after the parent loses its first node (`page_check`);
  - skip dropping an empty page without a sibling (`tree_check`);
  - forget `entries -= 1` (`tree_check`);
  - skip freeing the overflow run (`space_check`);
  - touch the path before the search on a missing key (the `Not_Found` test).
- **Build matrix:** `scripts/test.sh` (debug, speed, ASan, cross-`odin check`) and `scripts/test-linux.sh` on arm64 and amd64.

## Alternatives Considered

- **Borrowing from a sibling when a merge doesn't fit** (LMDB moves one node across): gives a real fill guarantee, but the vision rules it out for simplicity, and it would copy the sibling (see D2). It's the fallback if the fill measurement shows trees degrading badly.
- **Merging the path page into its sibling** (keeping the sibling's page number): copies the sibling, one extra page per level, for no benefit under copy-on-write (see D2).
- **Rebalancing lazily** (only drop empty pages, never merge underfull ones): simpler, but a tree could end up with one key per leaf after a mass delete. The vision asks for merges.
- **Rewriting separators on delete** to keep them tight: costs a key rewrite that can grow the parent (a longer key) and so need a split during a delete. Loose separators are correct, and LMDB leaves them too.
- **A lower merge threshold** (for example merge only when empty or below 10%) would merge less and thrash less between split and merge at the boundary. 25% is the vision's number. A merged page can be nearly full, so an insert right after a merge can split it again, but only a delete that takes a page under 25% can merge it back: alternating one put and one del at the boundary can't thrash.

## Implementation Plan

The tasks were created at decompose time (2026-09-24), with one commit per task:

1. **KV-T-0016, page-level merge primitives** (`page.odin`): append and prepend another page's nodes, with the branch separator brought down; make slot 0 −∞; the threshold and fit tests; `page_free` shared with `overflow_free`. Unit tests with `page_check`.
2. **KV-T-0017, `del`:** search, `Map_Full` check, touch, leaf removal, overflow freeing, the rebalance loop, root collapse, documentation of the lifetime and iteration rules. The shape and semantics tests above, with `tree_check` and `space_check` after every commit.
3. **KV-T-0018, verification:** `del` in the randomized model and in the threaded isolation test (TSan), the reader test, the churn steady state, delete-everything, the fill measurement, the Linux runs; update the vision's Current State, `CLAUDE.md` and this document's Results.

**Exit criteria:** REQ-001 to REQ-008 and NFR-001 to NFR-004 are met, `space_check` passes after every commit in every test that commits, the deliberate-bug checks each fail a test, and the full matrix passes on macOS and Linux.

## Results (2026-09-24)

All three tasks (KV-T-0016 to KV-T-0018) are complete. The ordinary suite has 132 tests and passes on macOS arm64 (debug, speed, ASan; the threaded tests under TSan) and on Linux arm64 and amd64 (debug, speed). `scripts/test.sh --steady` (136 tests, the four steady-state tests included) passes in all three macOS configurations, 3½–4 minutes each. Each task's status section records its decisions, measurements and deliberate-bug checks.

### Exit criteria

| Requirement | Status | Evidence |
|---|---|---|
| REQ-001 a missing key changes nothing | ✓ | `test_del_not_found_changes_nothing` (no dirty page, `mods` unchanged, cursor still valid); the model's absent deletes (about 4,000 a run) |
| REQ-002 read-only, earlier errors, failure after changes | ✓ | `test_del_read_only`; `del` mirrors `put` (`txn.err` set by `del_unchecked`) |
| REQ-003 overflow run freed, loose or freed | ✓ | `test_del_overflow_value`; `space_check` after every commit with overflow deletes in the model |
| REQ-004 no empty page below the root; underfull pages merge when they fit | ✓ | the ten shape tests in `delete_test.odin`; `tree_check` rejects an empty page below the root and runs after every commit everywhere |
| REQ-005 root collapse, empty tree, entry count | ✓ | `test_del_collapses_several_levels`, `branch_merge_left_collapses_root`, `drops_empty_leaf_under_single_child_parent`, `last_key`; the model empties the tree 6–8 times a run |
| REQ-006 `Map_Full` up front | ✓, scoped | `test_del_map_full`: with no page left `del` returns `Map_Full` and changes nothing. At a full map with reusable pages, deletes succeed until those run out (each copies its path, and the pages it frees wait for later commits), then return `Map_Full` with the transaction usable |
| REQ-007 a key from the transaction's own pages | ✓ | `test_del_key_from_same_txn` (a value from `get`, the range and delete-everything patterns from `del`'s comment) |
| REQ-008 cursors and slices invalidated | ✓ | `test_del_not_found_changes_nothing` (stale after a real delete) |
| NFR-001 no heap allocation beyond pages and page lists | ✓ | `del` and the merge primitives use the path, a stack scratch page and `page_alloc`/`page_free` only |
| NFR-002 no format change | ✓ | no change to the page, meta or free-list layout |
| NFR-003 readers unaffected | ✓ | `test_del_reader_keeps_snapshot`; the model's held readers (about 110 a run, over about 930 commits); the isolation test with a third of its operations deletes, under TSan |
| NFR-004 bounded file under churn | ✓ | `steady_state_churn` at 10⁴ commits, three runs (one per configuration of `scripts/test.sh --steady`): loaded at 352 pages, 368–373 after 5,000 and the same after 10,000; the second half wrote about 27,500 pages and added none |

### Fill after deletes (D1, measured)

`test_bench_delete_fill` (under `KV_BENCH`), 50,000 keys of 8 bytes with 0–100-byte values: after deleting 50% at random the tree has about 1,050 leaves at 40% fill, where inserting the survivors gives 590 at 70%; after 90%, 181–193 leaves at 43–46% and depth 3, against 120 at 68% and depth 2. **No leaf fell below 25% and no branch below the root had a single child in either run**, so the case D1 allows for (an underfull page whose siblings are both too full to merge) didn't arise. Pages settle just above the merge threshold. Borrowing isn't needed on this evidence.

### Deviations from the design
- **The separator is read in place** (D6 said it would be copied to a stack buffer): `page_merge` only reads the parent, and the parent changes only after the merge.
- **`txn_commit` counts changes, not dirty pages.** It skipped any transaction with no dirty pages as unchanged, and a delete that empties the tree leaves none (every page it copied goes to `loose`). Found by `test_del_last_key`: the last batch's commit was silently dropped.
- **`del` doesn't set `txn.err` when its search fails** (`Corrupted`): nothing has changed yet.
- **Test helpers:** `build_tree_shape` builds any shape; the tree builders' page buffers are 16-aligned (`page_buf_make`), which `build_tree_file` had only been lucky about.
- **The model test** gained deletes and tides (rising 40% put / 10% del; falling the reverse until the tree is empty). `test_model_until_map_full` keeps a rising tide only and a 4 MiB map (was 5), because with deletes about 80% of keys stay present and 5 MiB never filled.

### Known limitations
- **Trees are less full after deletes** (above): about 1.6–1.8× the leaves of an insert-only tree, sometimes a level deeper. Space is reclaimed to the free list, not returned to the file.
- **A delete at a full map** needs its path's worth of pages before it can free anything, as in LMDB.
- **Merges only happen on the path a delete takes.** An underfull page whose siblings were too full is only reconsidered when a later delete passes through it, not when its siblings shrink.
- **Still ahead:** the memory budget (step 6) and the kill-during-commit harness (step 7).