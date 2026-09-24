---
id: memory-budget
level: initiative
title: "Memory budget"
short_code: "KV-I-0004"
created_at: 2026-09-24T18:29:10.325375+00:00
updated_at: 2026-09-24T19:00:03.192731+00:00
parent: KV-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: L
initiative_id: memory-budget
---

# Memory budget Initiative

## Context

This initiative is build step 6 of the vision (KV-V-0001): *memory budget: dirty-page pool with spilling, chunk accounting, sweeper, and platform-specific eviction.* The vision's reason for it: the store runs inside a host process that holds other data in memory, so no process-wide limit (cgroup, rlimit) can be applied, and the store has to limit itself. The target is a database much larger than its budget (for example 100 MB on disk, about 20 MB resident).

The vision fixes the design at the level of mechanisms (its *Store-scoped memory budget* section). This initiative turns that into decisions against the code as it is after KV-I-0001 to KV-I-0003. **Status: D1–D12 approved on 2026-09-24, with Q1–Q4 settled; tasks KV-T-0019 to KV-T-0024 created the same day.**

**The first deployment (2026-09-24):** about 250 processes on one physical server, each embedding a store. It holds AI agent conversations and a few other things users work with in the embedding application. Load is low, a few hundred entries a day, and every access is initiated by an HTTP request. Two consequences shape the design: any per-store fixed cost is paid 250 times (a thread per store would be 250 threads), and a request is a natural trigger for application-driven housekeeping.

Two halves, with different kinds of risk:
- **Dirty pages (hard limit):** pure engineering against our own code. Today every dirty page is a buffer in the write transaction's arena (`Write_State.arena`, `dirty: map[Pgno][]byte`), so a transaction's write-side memory grows with its size, without limit. That includes overflow runs and the free-list run, which `commit` writes from dirty buffers.
- **Mapped pages (soft limit):** depends on platform behaviour the vision says must be *verified empirically*: whether eviction really lowers the resident size of a read-only `MAP_SHARED` file mapping on macOS (`MAP_FIXED` remap) and Linux (`MADV_DONTNEED`), and what `mincore` and `/proc/self/pagemap` actually report. So a measurement comes first, and its results can change D8–D10.

What exists to build on:
- **`page_ptr(txn, pgno)` is the only way to reach a page.** It already has the comment marking where accounting hooks in. Three direct reads of `map_base` bypass it: `overflow_value` (the value run), `freelist_load` at open, and `check.odin` (tests only).
- **Cursors and paths hold page numbers, not slices** (`Path_Entry{pgno, idx}`), so a dirty page moving from a buffer to the file between operations invalidates nothing a cursor holds.
- **Pages this transaction allocated are invisible to every snapshot**, reused or new (KV-I-0002 D1: the reuse horizon keeps snapshot S − 1 intact). So they can be written to their final place in the file *before* commit, and a crash or abort leaves only unreferenced garbage in free pages. This is what makes spilling safe without any format change.
- **`pwrite` is coherent with the mapping** on macOS and Linux; `commit` already relies on it.
- **`env_stats`** and the `Stats` struct were built to take step 6's figures.

## Goals & Non-Goals

**Goals:**
- A **hard limit on dirty-page memory**: a fixed pool, set at open, that no transaction exceeds whatever its size, by writing pages to their final locations early (spilling).
- A **soft limit on mapped pages**: a resident estimate kept by the store itself, `env_sweep`, which the application calls to evict chunks and stay under it, and inline eviction by a reader that pushes it past a hard watermark.
- **Eviction never affects correctness**: every zero-copy slice stays valid across evictions; pages are faulted back in.
- **Statistics** the host can inspect: resident estimate, dirty pages, spills, evictions, faults, and a check of the estimate against the OS.
- **The vision's success criterion:** with a database of about 100 MB and a 20 MB budget, the resident footprint (mapped estimate plus dirty pool), checked against the OS, stays within about 1–2 chunks of the budget under mixed read, scan and write loads, on macOS and Linux.

**Non-Goals:**
- **An exact limit on mapped pages.** The vision's rejected alternative (a buffer pool) is the only way to get one, and it gives up zero-copy lifetimes.
- **Limiting memory outside the page pool and the map:** the reader table, `Env.free` (16 bytes per free-list record, in RAM), and `Write_State`'s page lists (8 bytes per page touched). They are small next to the pages, and are reported (D11), not budgeted.
- **The OS page cache.** It is shared, isn't charged to the process's resident size, and is the kernel's to manage. Eviction drops the store's mapping of a page, not the cached page (so no `MADV_PAGEOUT`; see Alternatives).
- **Changing the file format.** Spilling writes pages where commit would have.
- The crash harness and fuzzing (step 7), though spilling adds commit-phase cut points step 7 must cover.

## Requirements

### Functional
- **REQ-001:** `Options` gains `dirty_budget`, `mapped_budget` and `chunk_size` (D1, D7). Invalid values return `Invalid_Argument` from `env_open`.
- **REQ-002:** the dirty-page memory of a write transaction never exceeds `dirty_budget`, including transactions that write far more than that: every put, del and commit completes by spilling.
- **REQ-003:** spilling is invisible to the transaction's API: gets, cursors, puts and deletes after a spill see the same data as without one, and commit and abort mean the same.
- **REQ-004:** abort after spilling leaves the database and the free list at the previous commit (`space_check` after the next commit).
- **REQ-005:** overflow values and the free-list run are written to the file without passing through the pool as whole runs (D5, D6), so neither a large value nor a long free list needs a pool larger than a few pages.
- **REQ-006:** with `mapped_budget > 0`, the store keeps a resident estimate in chunks, evicts down to its target when the application calls `env_sweep` (D9), and evicts inline above the hard watermark (D8) whether or not the application sweeps.
- **REQ-007:** every slice returned by `get`, a cursor or `overflow_value` stays valid and unchanged across any eviction.
- **REQ-008:** `env_stats` reports the figures in D11, safe to call from any thread at any time.
- **REQ-009:** `env_resident_check` (D10) counts the map's pages actually present in the process, by asking the OS.

### Non-functional
- **NFR-001:** reads still allocate nothing and take no lock on the fast path. Accounting in `page_ptr` is a shift, an atomic byte load and, only when a bit changes, an atomic store or CAS.
- **NFR-002:** read throughput with accounting on is measured against the current code and reported (target: under 5% slower on the read benchmarks; not asserted).
- **NFR-003:** no format change; files open in both directions with the KV-I-0003 code.
- **NFR-004:** the steady-state tests still hold with a small `dirty_budget` (the file stays bounded; spilling uses the same page allocation).
- **NFR-005:** fixed structures stay under 1 MB for the vision's example (a 1 GiB map with 256 KiB chunks needs a 4 KiB chunk table).

## Detailed Design

### Decisions
D1–D12 were approved as written on 2026-09-24, after the use-case discussion recorded in Context, Q2 and Q3.

**Dirty pages**

- **D1: the pool is fixed at open, reserved once, committed on demand.** `env_open` reserves `dirty_budget` bytes of address space (`virtual.reserve`) as page-sized slots. A slot is committed when first used, and every committed slot is decommitted when the write transaction ends (the vision: *released when the writer is idle*). There is no warm floor: with 250 stores and a few hundred writes a day, an idle store should hold no dirty memory at all, and refaulting a few pages per transaction costs microseconds against a synced commit's milliseconds. **Releasing must really drop the pages:** `core:mem/virtual`'s `decommit` uses `MADV_FREE` on both platforms, which is lazy. The kernel reclaims those pages only under memory pressure, and until then they still count toward the process's resident size. So the pool releases with its own call: `MADV_DONTNEED` on Linux (immediate for private anonymous memory), and on macOS `MAP_FIXED` anonymous memory over the range (or `MADV_FREE_REUSABLE`, if the measurement shows it lowers the footprint). D12 measures both. The dirty map becomes `map[Pgno]slot`. Default `dirty_budget`: 4 MiB (Q2). Minimum: `(2 × MAX_DEPTH + 1)` pages (49; 196 KiB at 4 KiB pages), the worst case of one put, so that every operation fits once the rest is spilled; smaller returns `Invalid_Argument`.
- **D2: spill only between operations, never during one.** At the start of `put` and `del` (next to the `pages_available` check), if the pool has fewer free slots than the operation's worst case (`2·depth + 1` for put, `depth` for del), spill. Inside an operation `page_ptr` slices into dirty pages are live across `page_alloc` (for example `insert_node` holds the page it's splitting), so spilling there would free a buffer still in use. Checking at the boundary keeps every slice inside an operation valid with no pinning, and matches the lifetime rule the vision already states (a write transaction's slices end at the next put or del).
- **D3: what to spill: least recently touched, in a batch.** Each slot records the `mods` value of its last touch. A spill takes the least recently touched quarter of the pool (at least as many slots as the operation needs), sorts them by page number and writes them with `pwrite`, so spills are rare and sequential. Branch pages are touched by every operation on their path, so LRU keeps them without a leaf-only rule. (The vision says *least recently touched leaves*; this is the same in practice, and simpler.)
- **D4: a spilled page stays the transaction's page.** Spilled page numbers go in a `spilled` set. Reading one goes through the map (coherent with `pwrite`). Touching one copies it back into a pool slot **under the same page number**: no copy-on-write, no `freed` entry (the vision: *a page number allocated by the current transaction can be re-touched without copy-on-write*). `page_free` of a spilled page puts it on `loose`, like a dirty one. Commit writes the dirty slots, then syncs once, which covers the spilled writes too. The file is grown before a spill writes past its end (`file_grow`, moved out of `commit.odin`).
- **D5: overflow runs are written straight to the file.** `overflow_write` writes the run's header page through one pool slot and the rest of the value with `pwrite` from the caller's buffer, and records the run as spilled (the vision: *large values go straight from the caller's buffer*). An in-place same-length update of an overflow value doesn't exist today (only inline values are updated in place), so nothing needs the run in memory.
- **D6: the free-list run is streamed.** `freelist_write` fills one page at a time into a pool slot and writes each with `pwrite`, instead of building the whole run in a dirty buffer. At 10⁵ records the run is 400 pages (1.6 MB), which would otherwise need a pool that large at commit.

**Mapped pages**

- **D7: chunk table.** The map is divided into aligned chunks of `chunk_size` bytes (a power of two, at least 64 KiB and at least the page size; default 256 KiB). `map_size` is rounded up to a whole number of chunks. One byte per chunk holds two bits, `resident` and `referenced`, updated atomically. `resident_chunks` is an atomic count. `page_ptr`, for a page read from the map, loads the byte; if `referenced` is clear it sets it; if `resident` is clear it sets it with a CAS and, if it won, increments `resident_chunks` and checks the watermarks (out of line). `overflow_value` marks every chunk of the run, and `freelist_load` the chunks it read. Accounting runs whenever the map is open (so the estimate is in `env_stats` even without a budget); eviction only when `mapped_budget > 0`.
- **D8: watermarks.** With budget B chunks: `env_sweep` does nothing at or below **B**, and above it evicts down to **7/8 B**; a thread whose page_ptr takes the count past **B + 2 chunks** (the hard watermark) evicts until the count is back to B itself, then continues. The criterion's "within 1–2 chunks" is the hard watermark's margin. An application that never sweeps still stays within B + 2 chunks, only with the eviction cost landing on reads.
- **D9: sweeping is driven by the application; the store starts no thread (Q3).** `env_sweep(env, target := -1) -> (evicted: int)` runs CLOCK over the chunk table under `evict_mutex`: a chunk with `referenced` set has it cleared and survives; one without is evicted. With the default target it evicts only when above B, down to 7/8 B, so calling it after every request costs one atomic load when there's nothing to do. An explicit `target` (in bytes, 0 allowed) trims below the budget, for an application that wants an idle store to give its mapped pages back. **Target 0 is the sleep path** for the first deployment, whose main RDF store unloads itself on inactivity: it drops every mapped page while the env stays open, and unlike `env_close` it leaves slices valid and needs no reopen. What remains is the `Env`, the chunk table, the reader table and `Env.free`. `env_close` plus `env_open` on wake is the alternative when even that should go (the testing strategy measures both). It's safe from any thread, with or without a transaction open, and uses `try_lock`: a second concurrent call returns 0 at once rather than waiting. Inline eviction at the hard watermark goes through the same code. **Why no thread is enough:** the estimate only grows through `page_ptr`, which only runs inside a transaction, which in this deployment only runs inside a request. So a store with no requests has a resident count that isn't moving, and sweeping after requests covers every point where it can grow. Eviction clears `resident` first (and decrements the count), then evicts the range, so a racing reader can only cause an overestimate, never an underestimate (the vision's order). Evicting: **Linux** `madvise(MADV_DONTNEED)`, which drops the mapping's page table entries and leaves the page cache; **macOS** `mmap(MAP_FIXED)` of the same file range over itself, then `MADV_RANDOM` again, because `MADV_DONTNEED` is only a hint there. Both keep every address valid. Chunks past the end of the file are never marked resident and are skipped.
- **D10: `env_resident_check`, on demand.** Counts the map's pages that are present, in chunk-sized units, over the file's extent (not all of `map_size`). **Linux:** the present bits of `/proc/self/pagemap` (never `mincore`, which reports the page cache). **macOS:** `mincore`, if the measurement (task 1) confirms it errs only toward overcounting; otherwise the per-region resident count from `mach_vm_region`. It's a statistic and a test oracle: it doesn't correct the estimate (see Q4).
- **D11: `Stats` gains:** `mapped_budget`, `resident_chunks` (estimate) and `chunk_size`; `chunk_faults` (chunks that became resident, the fault-rate figure), `evictions`, `sweeps` (calls to `env_sweep` that evicted something) and `inline_evictions` (cumulative, so an application can see whether it is sweeping often enough); `dirty_pages` (pool slots in use by the current writer), `dirty_committed` (bytes of the pool committed), `dirty_budget` and `spills` (pages spilled, cumulative); `free_list_bytes` (the RAM `Env.free` holds). The cumulative and live counters are atomics, so they're read without waiting for a write transaction. This relaxes the current doc comment ("a write transaction in progress shows in none of them") for the dirty figures only.
- **D12: the first task is a measurement, not code in `kv/`.** A test-only program that maps a file read-only and shared, touches ranges, evicts them with each candidate, and records what each method reports: `mincore`, `pagemap`, the per-region resident count, and process RSS. It also checks D1's release of anonymous pool memory: resident size after `MADV_FREE`, `MADV_DONTNEED`, `MADV_FREE_REUSABLE` (macOS) and a `MAP_FIXED` remap. On both platforms, with a threaded reader faulting the range during the remap on macOS. Its results decide D9's macOS method and D10's oracle, and are recorded in the task before anything is built on them.

### Known limits of the mapped budget
- **A value larger than a few chunks is resident in full while the caller reads it.** `overflow_value` marks every chunk of its run (D7), and eviction can drop them again, but the caller's slice faults the whole value back in as it is read. A single value larger than the budget can't be read within it. For conversations, store messages as separate entries, not as one value that grows: that keeps reads within budget and also avoids rewriting the whole overflow run on every append.
- **Pages faulted in through a slice held across an eviction aren't counted** until a later `page_ptr` touches that chunk (Q4: measured, not corrected).
- **Outside the budget:** `Env.free` (16 bytes per free-list record), the reader table, the write transaction's page lists and the chunk table (D11 reports the first). Small, but a tight budget should leave room for them.

### Questions settled in review
- **Q1 (settled 2026-09-24): one initiative**, with the dirty half first because it doesn't depend on the measurement.
- **Q2 (settled 2026-09-24, 4 MiB kept):** `dirty_budget` defaults to **4 MiB**. It's address space until used and released after every transaction (D1), so at a few hundred writes a day it costs nothing when idle, and a large conversation value goes straight to the file (D5). `mapped_budget` defaults to **0**, meaning no eviction, with accounting still on. That's a library default only: the embedding application is expected to set it (with 250 stores on one machine, the budget per store is the host's decision). `0 = unlimited` for the dirty pool as well was the alternative, but it keeps today's unbounded write path as the default.
- **Q3 (settled 2026-09-24): no sweeper thread.** The application calls `env_sweep`, for example after each HTTP request, and inline eviction at the hard watermark is the backstop (D8, D9). This saves 250 threads per server in the first deployment. It departs from the vision, which describes a background thread, and the vision is amended when this initiative completes.
- **Q4 (settled 2026-09-24): no correction for now.** Should `env_sweep` also run `env_resident_check` periodically and *correct* the estimate toward the OS figure? That catches pages faulted in through slices held across an eviction, which `page_ptr` never sees. Proposal: **not now**. Report the drift in the success-criterion test, and add correction only if it's large.

## Testing Strategy

- **Dirty pool, with a small budget (the minimum, 49 pages):**
  - a transaction writing 10× its pool commits, and every key reads back before and after commit, through `get` and both cursor directions;
  - `dirty_pages` never exceeds the budget (checked after every operation);
  - a spilled page re-touched keeps its page number (no `freed` entry); a spilled page freed goes to `loose`; an aborted transaction after spills leaves the database and free list as they were (`space_check` after the next commit);
  - large overflow values (bigger than the pool) and a free list longer than the pool commit;
  - readers holding snapshots across spilling transactions still read their data;
  - the randomized model, isolation (TSan) and steady-state tests run with a small `dirty_budget` as well as the default.
- **Accounting:** the chunk bits and count after reads that cross chunk boundaries, overflow values spanning chunks, and `freelist_load`; the count never falls below the true number of chunks touched since the last eviction (checked against `env_resident_check`).
- **Eviction:** readers hold slices across evictions (`env_sweep` and inline) and compare the bytes; a threaded stress under TSan where reader threads call `env_sweep` concurrently, as request handlers would; a store that never sweeps stays within B + 2 chunks through inline eviction alone; `env_sweep` with target 0 empties the estimate and the OS check agrees; evicted chunks' pages report absent to the OS check.
- **The success criterion:** a 100 MB database, a 20 MB budget (13–15 MB mapped plus 4 MB dirty), mixed read, scan and write threads each calling `env_sweep` after every simulated request; `env_resident_check` plus the dirty pool sampled throughout, asserted within 2 chunks of the budget, on macOS and Linux (arm64, amd64). On demand, like the steady tests.
- **Measurements, reported:** read throughput with accounting on and off (NFR-002); spill cost per page; the time `env_sweep` adds to a request, with nothing to do and when it evicts; the memory left after `env_sweep(env, 0)` against `env_close`, and the time `env_open` takes to wake a store (the free list is loaded into RAM, so it depends on the free list's length).
- **Deliberate-bug checks** (the working agreement), each confirmed to fail a test: spill during an operation instead of at the boundary; copy-on-write a spilled page; forget to grow the file before a spill; free a spilled page to `freed`; evict before clearing `resident`; skip marking an overflow run's chunks.
- **Build matrix:** `scripts/test.sh`, `scripts/test.sh --steady`, TSan for the threaded tests, and `scripts/test-linux.sh` on arm64 and amd64.

## Alternatives Considered

- **A buffer pool instead of the map** (the vision's rejected alternative): exact limit, but slices would only last until the next cursor operation.
- **Spilling during an operation, with pinned pages:** spills less and later, but every slice held inside `insert_node` and `del`'s rebalance would need pinning, for a gain only in a pool too small for one operation, which D1's minimum rules out.
- **Pure LRU without batching:** one `pwrite` per page spilled and a scan of the pool each time; batching a quarter makes spills rare and sequential.
- **`MADV_PAGEOUT` on Linux:** also drops the page cache, which isn't charged to the process and is shared; it would only make later reads slower.
- **`MADV_DONTNEED` on macOS:** a hint for shared file mappings there (the vision); D12 measures it anyway, so if it turns out to work it is the simpler method.
- **A sweeper thread owned by the store** (the vision): one thread per store, 250 per server in the first deployment, mostly asleep, for work that only becomes necessary during requests anyway. Rejected at Q3. The inline eviction path means an application that never sweeps still stays near its budget.
- **Measuring residency from the OS instead of accounting:** a `mincore` or `pagemap` walk per decision is far too slow for `page_ptr`, which is why the vision chose self-accounting with an OS check.

## Implementation Plan

The tasks were created at decompose time (2026-09-24), with one commit per task:

1. **KV-T-0019, platform measurement (D12):** the eviction and residency spike on macOS and Linux; results recorded in the task; D9 and D10 amended if they disagree.
2. **KV-T-0020, dirty-page pool (D1):** the reserved pool, slots, commit on demand and release, `dirty_budget`, the dirty map on slots; no spilling yet (a transaction bigger than the pool returns `Out_Of_Memory`).
3. **KV-T-0021, spilling (D2–D6):** the boundary check, LRU batch spill, the `spilled` set and re-touch, `file_grow` shared, overflow runs and the free-list run written directly; the dirty-pool tests above and the model, isolation and steady tests with a small budget.
4. **KV-T-0022, chunk accounting (D7, D11):** the chunk table, `page_ptr` and the two bypasses, the `Stats` fields, the read-throughput measurement.
5. **KV-T-0023, eviction (D8, D9):** the platform eviction calls, `env_sweep`, inline eviction at the hard watermark, the slice-validity and TSan tests.
6. **KV-T-0024, OS check and the criterion (D10):** `env_resident_check`, the 100 MB/20 MB mixed-load test on macOS and Linux, the vision's Current State and its memory-budget section (no sweeper thread), `CLAUDE.md` and this document's Results.

**Exit criteria:** REQ-001 to REQ-009 and NFR-001 to NFR-005 are met, the success-criterion test passes on macOS and Linux, the deliberate-bug checks each fail a test, and the full matrix passes.