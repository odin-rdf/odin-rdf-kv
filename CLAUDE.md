# odin-rdf-kv

An embedded, LMDB-style key/value store in Odin: a copy-on-write B+tree in one memory-mapped file, zero-copy reads, crash safety without a WAL, and a memory budget enforced by the store itself. Package `kv/`, tests in `tests/` (package `kv_tests`, importing `../kv`). `liblmdb/` is a local, git-ignored copy of upstream LMDB kept for reference only.

## Where the state lives

Metis (`.metis/`) is the system of record for plans, decisions and progress. Start here:

- `.metis/vision.md` (KV-V-0001): the design, the build order (steps 1–7) and the current state.
- `.metis/archived/initiatives/KV-I-0001/initiative.md`: steps 1–3 (completed and archived). Its **Results** section lists the exit-criteria evidence, every deviation from the design, and the known limitations.
- `.metis/archived/initiatives/KV-I-0002/initiative.md`: step 5, page reuse (completed and archived). Its **Results** section has the same, plus the steady-state and free-list cost measurements.
- `.metis/archived/initiatives/KV-I-0003/initiative.md`: step 4, delete with merge (completed and archived). Its **Results** section has the exit-criteria evidence, the fill measurement after deletes, and the deviations.
- Each task's **Status Updates** section records decisions made during implementation and the reasons for them.

`metis list` shows everything. `metis.db` is gitignored runtime state; after a fresh clone, run `metis sync` to rebuild it from the markdown.

- `.metis/archived/initiatives/KV-I-0004/initiative.md`: step 6, the memory budget (completed and archived; tasks KV-T-0019 to KV-T-0024). Its **Results** section has the exit-criteria evidence, the success criterion per platform, the capacity-planning table per store, the measurements, the deviations and the known limitations. Decisions D1, D8, D9 and D10 carry dated amendments; read those, not only the first text.

- `.metis/initiatives/KV-I-0005/initiative.md`: step 7, crash tests and fuzzing. **Decomposed (2026-09-25):** decisions D1–D9 (a recording I/O journal behind `KV_IO_HOOK`, kill and power-loss images built from it, `KV_NO_SYNC` for fuzzing and CI, seeds-only fuzzing, recreating an all-zero new file, `.Poisoned` after a failed sync), the detailed design, and tasks KV-T-0026 to KV-T-0033.

**Next up:** KV-T-0026, then the rest of KV-I-0005 in order.

## Memory budget in one paragraph

`Options` has `dirty_budget` (default 4 MiB: the pool a write transaction's dirty pages live in; it spills to the file instead of growing, and is released when the transaction ends), `mapped_budget` (default 0: no eviction, estimate still kept) and `chunk_size` (default 256 KiB, at least 64 KiB, a power of two). The store keeps a resident estimate of the map in chunks (`Stats.resident_chunks`). **The end of every transaction** evicts above the budget B down to 7/8 B, and **a read past B + 2 chunks** evicts inline. `env_sweep(env, 0)` is the **sleep path**: the application calls it after hours without a request, and every mapped page leaves the process while the store stays open. Nothing needs to call `env_sweep` otherwise. `env_resident_check` asks the OS (Linux `pagemap`; `.Unsupported` on macOS). `env_stats` reports everything; the dirty and chunk figures are live.

## Working agreement

- Put durable plans and findings in Metis documents, not in standalone notes. Update the active task's Status Updates as you go.
- When executing an initiative's tasks:
  1. Transition the task to active.
  2. Implement it.
  3. Verify with `scripts/test.sh`.
  4. Tick the acceptance criteria and add a dated status update recording decisions and deviations.
  5. Transition the task to completed.
  6. Make **one commit per task**, including its Metis document changes.
- Carry on from task to task without pausing. The user reviews once the whole initiative is done, and pushing waits until they ask.
- Check new tests against deliberate bugs: break a piece of logic on purpose, confirm a test fails, then restore it. Record in the task what was checked.

## Build and test

```sh
scripts/test.sh                 # debug, -o:speed, -sanitize:address, plus odin check for darwin/linux × arm64/amd64
scripts/test.sh --steady        # the same, plus the slow steady-state tests (-define:KV_STEADY=true)
scripts/test.sh -define:ODIN_TEST_NAMES=kv_tests.test_cursor_seek      # extra args go to every `odin test`
scripts/test.sh -define:ODIN_TEST_RANDOM_SEED=1234                      # reproduce a randomized failure (seed is in the message)
scripts/test-linux.sh arm64     # Linux container, debug and -o:speed; also amd64 (emulated)
```

- **Linux tests:** these need Docker. On macOS that is OrbStack, which is normally stopped: run `orb start` first and `orb stop` afterwards. `scripts/linux.Dockerfile` pins the Odin release, so keep its `ODIN_VERSION` in step with `odin version` (currently dev-2026-09).
- **ThreadSanitizer:** `-sanitize:thread` works on macOS arm64. Use it for `test_snapshot_isolation_across_threads`, `test_snapshot_isolation_min_pool`, `test_reader_table_across_threads`, `test_chunk_concurrent_readers`, `test_sweep_concurrent`, `test_sweep_estimate_not_under`, `test_sweep_try_lock` and `test_evict_budget_no_sweep`. Under TSan the process's resident size includes the sanitizer's shadow of every byte read (three times the file), so a macOS check of residency uses `process_file_resident` (`task_info` `external`), not `resident_size`. A race only shows when the two accesses overlap, so run a threaded check more than once.
- **Steady-state tests are on demand:** the plateau, full-map, long-reader and churn tests make thousands of synced commits (all but the long reader 10⁴ each; `F_FULLFSYNC` on macOS is about 4 ms), about 3½–4 minutes per configuration, so they only run with `-define:KV_STEADY=true` or `scripts/test.sh --steady`. Run them after changing allocation, the free list or commit. While iterating, also pass `-define:KV_STEADY_COMMITS=1000`. `-define:KV_STEADY_DIRTY_BUDGET=200704` runs them with the smallest dirty-page pool (49 pages) instead of the default.
- **Free-list cost measurement:** `odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_free_list_cost`.
- **Read throughput (the cost of chunk accounting):** `odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_read`, then again with `-define:KV_NO_CHUNK_ACCOUNTING=true`, which compiles accounting out (for this measurement only: the chunk tests fail without it).
- **Spill cost:** `odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_spill_cost` (reported, not asserted).
- **Fill after deletes:** `odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_delete_fill` (reported, not asserted).
- **The memory-budget criterion and capacity figures (KV-T-0024):** a 100 MB database, both settings, about 30 s; resident sizes are process-wide, so run it alone:
  `odin test tests -o:speed -define:KV_CRITERION=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=kv_tests.test_memory_criterion`, and on Linux `scripts/test-linux.sh arm64 -define:KV_CRITERION=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=kv_tests.test_memory_criterion`. `-define:KV_CRITERION_SECONDS=n` (default 10) sets the mixed load's length, and `-define:KV_CRITERION_PAUSE_US=n` (default 200) the readers' pause between requests. It logs a `CAPACITY` line per setting.
- **Platform measurement (KV-T-0019):** `-define:KV_PLATFORM=true` registers `test_platform_residency` and `test_platform_remap_under_load` (run with `-define:ODIN_TEST_THREADS=1`).
- **Eviction cost:** `odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_sweep`.
- **The real-kill test (KV-T-0032):** `odin test tests -define:KV_KILL=true -define:ODIN_TEST_NAMES=kv_tests.test_kill_real`, about 5 s; on Linux run it directly, not through `scripts/test-linux.sh` (whose third configuration sets `KV_NO_SYNC`, which the test refuses): `docker run --rm --platform linux/arm64 -v "$PWD":/src:ro odin-rdf-kv-test:arm64 odin test tests -define:KV_KILL=true -define:ODIN_TEST_NAMES=kv_tests.test_kill_real -out:/tmp/kv_tests` (the image `scripts/test-linux.sh` builds). It builds the helper `tests/killer/` with `odin build` (so `odin` must be on PATH), then kills it with `SIGKILL` 20 times on one file, with real syncs: it refuses to run under `KV_NO_SYNC`. `-define:KV_KILL_REPEATS=n` (default 20) and `-define:KV_KILL_MAX_DELAY_MS=n` (default 250) change the kills and the longest run before one. Not in `scripts/test.sh` (which only checks the helper compiles) and not in CI.
- **The I/O hook and the journal (KV-I-0005, KV-T-0026):** `-define:KV_IO_HOOK=true` compiles a call to the thread-local `kv.io_hook` into `os_pwrite`, `os_sync` and `os_truncate` (every write, sync and truncate the store makes); `-define:KV_NO_SYNC=true` makes `os_sync` skip the system call after the hook. Both are test-only. `scripts/test.sh` runs one debug configuration with both; the others keep real syncs. `tests/crash.odin` holds the journal (`journal_start`, `fail_at` for injecting a failure) and crash images (`baseline_take`, `image_apply`, `journal_image_kill`).
- **Fuzz mode (KV-T-0031), on demand only, never in the default suite or CI:** `-define:KV_FUZZ=true` registers `test_fuzz_model`, `run_model` for `KV_FUZZ_OPS` operations (default 10⁶, about 8 s at 3,000 keys, up to 16 s at 10,000, with `KV_NO_SYNC` on macOS arm64) over `KV_FUZZ_SEEDS` consecutive seeds (default 1) from the runner's. A seed's pool (odd: `MIN_DIRTY_BUDGET`) and key count come from the seed alone. Always pass `KV_NO_SYNC` (real syncs make it about 4× slower and wear the SSD) and one thread:
  `odin test tests -o:speed -define:KV_FUZZ=true -define:KV_NO_SYNC=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=kv_tests.test_fuzz_model -define:KV_FUZZ_SEEDS=8 -define:KV_FUZZ_CHECK_EVERY=10`.
  `KV_FUZZ_CHECK_EVERY=k` (default 1) runs the full check every k transactions (about 2.5× faster at 10; a failure surfaces up to k transactions late). A failure prints `[seed N] op M`; reproduce it alone with `-define:ODIN_TEST_RANDOM_SEED=N -define:KV_FUZZ_SEEDS=1` and the same `KV_FUZZ_OPS`, at `KV_FUZZ_CHECK_EVERY=1` to see it at its transaction (the checks draw no random numbers, so the operations are the same).
- **Supported targets:** only 64-bit targets are supported (`#assert(size_of(int) == 8)`).

## Code map

| File | Contents |
|---|---|
| `types.odin` | `Pgno`, `Txn_Id`, `Error`, format constants |
| `page.odin` | On-disk page and node layout, size limits, slotted-page operations, split and merge helpers, `page_check` |
| `meta.odin` | Meta page layout and checksum |
| `env.odin` | Open and close, choosing the meta page, `meta_write`, the reader table, `env_stats`, `file_grow` |
| `txn.odin` | `Txn` (a value type), `Write_State` (on the heap; `dirty` maps a page number to its pool slots, `spilled` the pages already written to the file), the reuse horizon, `page_ptr` |
| `chunks.odin` | `Chunk_Table`, the resident estimate of the map (KV-I-0004 D7): one byte per chunk (`resident`, `referenced`), `chunk_touch` (page_ptr's fast path), `chunk_mark` (the CAS), `chunk_resident_added` (raises `end`, evicts inline at the hard watermark); eviction (D8, D9): `chunks_evict` (CLOCK under `evict_mutex`), `chunks_evict_all` (target 0), `chunks_txn_end` (called by `txn_abort`), `env_sweep`; `env_resident_check` (D10) |
| `pool.odin` | `Dirty_Pool`, the dirty-page pool (KV-I-0004 D1): slots reserved at open, committed on first use, released when the write transaction ends; `pool_make_room` and `spill` (D2–D4: the least recently touched quarter, written in page order) |
| `tree.odin` | `tree_search`, `get` |
| `write.odin` | `page_alloc` (loose, then reusable, then the end of the file), `page_take` (the same page numbers without pool slots), `pages_available`, `page_free`, `page_touch` (a spilled page comes back under its own number), `put`, splits |
| `freelist.odin` | Free-list records and run layout, load and validate at open, release at `txn_begin`, build and place at commit, `freelist_write` (a page at a time through one slot, D6) |
| `overflow.odin` | Overflow value runs; `overflow_write` writes a run straight to the file (D5) |
| `commit.odin` | `txn_commit`; `commit_poison` (KV-I-0005 D7) |
| `delete.odin` | `del`: removal, the rebalance loop (merge with a sibling, drop empty pages) and root collapse |
| `cursor.odin` | Cursors |
| `check.odin` | `tree_check`, and `space_check` (every page owned exactly once) |
| `os_*.odin` | Platform layer, including the map reserved at a chunk-aligned address, the pool's reserve, commit and release (`os_pool_release`: `MAP_FIXED` remap on macOS, `madvise(MADV_DONTNEED)` on Linux) eviction of mapped pages (`os_evict`: `MAP_FIXED` remap of the same file range plus `MADV_RANDOM` again on macOS, `madvise(MADV_DONTNEED)` on Linux) and the OS's residency of a range (`os_resident`: `/proc/self/pagemap` on Linux, `.Unsupported` on macOS) |

**Test helpers:**
- `tests/tree_helpers.odin`: `build_tree_file` builds a packed tree directly; `build_tree_shape` builds any shape, with each leaf's entries and each level's grouping given (underfull pages, single-child branches).
- `tests/model.odin`: the randomized model and `model_diff`. `run_model` in `tests/model_test.odin` also holds up to 4 readers across commits.
- `tests/helpers.odin`: temporary directories, `Page_Buf`, `dirty_buf` (a dirty page's pool buffer), `written_pgnos` (every dirty and spilled page or run of a write transaction), `MIN_DIRTY_BUDGET` (the smallest pool) and `expect_pool_within` (the pool within its budget).
- `tests/freelist_test.odin`: `open_hand_list` opens a database with a hand-written free list.
- `tests/steady_test.odin`: the steady-state workload (`steady_commit`) and `expect_latest_ok` (`space_check` and `tree_check` on a new reader).

**Other test files:** `delete_test.odin` (delete shapes and semantics; `sized_entries`, `expect_shape_keys`, `commit_ok`), `reader_test.odin` (reader table), `reuse_test.odin` (reuse rules), `steady_test.odin` (`env_stats`; plateau, full map, long reader and insert/delete churn on demand), `isolation_test.odin` (threads, including readers that come and go while pages are reused), `pool_test.odin` (the dirty-page pool: budget, live figures, release checked against the OS), `spill_test.odin` (spilling with the smallest pool: ten times the pool, re-touch and free of spilled pages, abort, readers, a value larger than the pool), `spill_bench_test.odin` (the spill cost, only registered with `-define:KV_BENCH=true`), `chunk_test.odin` (chunk accounting: options, boundaries, dirty reads, overflow runs, `freelist_load`, concurrent readers; `expect_chunks_consistent`), `evict_test.odin` (eviction: `env_sweep`'s targets, CLOCK, eviction at transaction ends and inline, held slices, writes across evictions, the budget under threads with no `env_sweep`, requests during a sleep sweep, `try_lock`, the estimate never under the OS's view; `test_bench_sweep` with `-define:KV_BENCH=true`), `resident_test.odin` (`env_resident_check` against the estimate on Linux, and the same checks against `task_info` on macOS), `criterion_test.odin` (the memory-budget criterion and the capacity figures, only registered with `-define:KV_CRITERION=true`), `read_bench_test.odin` (read throughput, only registered with `-define:KV_BENCH=true`), `platform_test.odin` (KV-T-0019's measurement, only registered with `-define:KV_PLATFORM=true`; `platform_residency` is usable by any test, and so are `chunks_present` (Linux `pagemap`; none on macOS), `advice_random` (a range's `MADV_RANDOM`) and `process_file_resident` (the process's file-backed resident size: `task_info` `external` on macOS, `RssFile` on Linux) from the per-platform files), `bench_test.odin` and `fill_test.odin` (the free-list cost and the fill after deletes, only registered with `-define:KV_BENCH=true`), `kill_test.odin` (the real-kill test, only registered with `-define:KV_KILL=true`; its helper is `tests/killer/`, a `main` package of its own, and the workload both share, deterministic by commit number, is `tests/killer/workload/`).

## Invariants and conventions

- **`page_ptr(txn, pgno)` is the only way to reach a page,** and it accounts the page's chunk as read when the page comes from the map (`chunk_touch`; a dirty page counts nothing). Overflow runs are read through `overflow_value`, which validates the run and accounts every chunk of it. Anything else that reads the map directly must call `chunks_touch_range` (as `freelist_load` and `space_check` do; `env_open` marks chunk 0 for the meta pages). Keep `chunk_touch`'s fast path a shift and one atomic load, with no write when both flags are set.
- **Eviction** (KV-I-0004 D8, D9): only eviction clears `CHUNK_RESIDENT`, always by CAS **before** the range is evicted, so a racing read can only make the estimate too high. It runs under `evict_mutex`: transaction ends and `env_sweep` take it with `try_lock` (they don't wait), and a read past the hard watermark (B + 2 chunks) **waits** for it, which is what bounds the estimate at about B + 2 plus one chunk per thread under concurrency. So **no code holding `evict_mutex` may reach `page_ptr`** (or `chunk_touch`, `chunks_touch_range`): it would wait on itself. Eviction reads no page; a test that holds the lock to simulate an evictor must hold it from another thread. Every transaction ends in `txn_abort` (`txn_commit` too), which evicts above the budget once it has released the reader table and the writer mutex. Evicting keeps every address valid, so held slices stay valid, but pages they fault back in aren't counted (Q4): a test comparing the estimate with the OS must not read held slices after an eviction.
- **Checking residency against the OS:** on Linux, `env_resident_check` (a `pagemap` walk, 0.1–0.3 ms for 100 MB) isn't atomic: under load it can count chunks that were never resident together, so only trust a sample during which `chunk_faults` and `evictions` didn't change. On macOS, compare `process_file_resident` with a baseline taken after `env_open`: `resident_size` also carries malloc's retained pages (4–8 MiB after a threaded test, staying after `env_close`), and the test runner's 4 MiB temporary-allocator block becomes resident as it is first used (`temp_warm` in `criterion_test.odin`).
- **The map starts at a chunk-aligned address** (`os_map_reserve`'s `align`): Linux fault-around maps a 64 KiB window aligned by *address*, which stays inside one chunk only if the chunks are aligned in the address space. `mmap` alone aligns to the OS page.
- **Zero-copy lifetimes:**
  - a slice from a read transaction is valid until the transaction ends;
  - a slice from a write transaction is valid until the next `put` or `del`, which may spill the page it points into and reuse its slot;
  - `put` must not receive slices that point into the same transaction's pages, dirty or spilled (a slice into a spilled page points into the map).
- **Clone before modifying:** copy any key or value you still need before rewriting the page it points into. Splits rewrite both pages, and a test helper got this wrong once.
- **Alignment:**
  - node headers are `#packed` and are read and written by value only; never take the address of a packed field;
  - page buffers outside the map must be at least 8-aligned (dirty pages are page-aligned);
  - in tests, cast only `Page_Buf` (`#align(16)`) to page structs, never a plain `[N]byte`.
- **Byte order:** integer keys must be encoded big-endian to sort numerically, and inline values have no alignment guarantee.
- **Write-path tests need a committed tree underneath.** Put into a tree that was committed first (for example with `build_tree_file`), otherwise every page is already dirty and copy-on-write never runs.
- **Structural checks:** tests call `kv.tree_check` or `kv.page_check` after changes, and `kv.space_check` after every commit.
- **Dirty pages live in `Env.pool`,** not in the transaction: `page_free` of a dirty page frees its slots for the next `page_alloc`, so don't read a page after freeing it. Every slot is released when the write transaction ends.
- **Spill only between operations** (KV-I-0004 D2): `pool_make_room` runs at the start of `put` and `del` (with their worst case, next to `pages_available`) and in `txn_commit`, never inside an operation, which holds slices into its dirty pages across `page_alloc`. It asserts `Write_State.in_op`. `page_alloc` never spills.
- **A page is in `dirty` or `spilled`, never both.** A spilled page (or an overflow run, which is written straight to the file) is still the transaction's own: `page_ptr` reads it through the map, `page_touch` copies it back into a slot under the same number (no copy-on-write, no `freed` entry), and `page_free` makes it loose. Writing it before the commit is safe because pages a write transaction allocates are in no snapshot anyone can read (KV-I-0002 D1); the file is grown (`file_grow`) before anything is written past its end.
- **A failed first sync, meta-page write or final sync poisons the env** (KV-I-0005 D7): `txn_commit` sets `Env.poisoned` there and nowhere earlier, and every later `txn_begin(rw)` returns `.Poisoned` (checked under `writer_mutex`) until `env_close`; reads, `env_stats` (`Stats.poisoned`) and `env_sweep` carry on. A failure before the first sync leaves only unreferenced pages and doesn't poison. `tests/poison_test.odin` (hooked build) shows the corruption it prevents.
- **Free pages:** a page freed by commit `T` is reused only once `T ≤ min(oldest reader, S − 1)` (KV-I-0002 D1). `Env.free` changes only at `txn_begin(rw)` (the release) and after a durable commit; a write transaction records what it takes instead.

## Pitfalls hit so far

**Odin (dev-2026-09):**
- `or_return` needs the last return value to be a bool, or an error that can be compared with nil. A `(ok: bool, reason: string)` result can't use it.
- `where` is a keyword, so it can't be used as a parameter name.
- `x if c else y` can't choose between calls that return several values. Choose the procedure first, then call it.
- `testing.logf` doesn't exist; use `core:log`.
- Procedures can't capture variables. Pass data to a comparator through `context.user_ptr`.
- `offset_of` returns `uintptr`, so it needs a cast before mixing with `int`.
- A width on an integer in `fmt` (`%7d`, `%7v`) pads it with zeros. Format the number first, then pad the string (`%7s`).
- `flock` and `F_FULLFSYNC` aren't in `core:sys/posix`; they're declared locally in `kv/os_*.odin`.
- Don't keep a path from `temp_dir_file` (temporary allocator) across a `free_all(context.temp_allocator)`: clone it.
- `thread.create_and_start_with_poly_data(..., init_context = context)` shares the caller's random generator state between threads: `rand` then races (TSan reports it). Leave `init_context` out, and each thread gets its own.

**Platform:**
- glibc's `posix_madvise(POSIX_MADV_DONTNEED)` is a no-op; call `madvise` itself (declared in `kv/os_linux.odin`). `posix_madvise` is fine for `RANDOM`.
- A `MAP_FIXED` remap on macOS makes a new mapping with default advice: give `MADV_RANDOM` again.
- Apple Silicon OS pages are 16 KiB. A 4 KiB database page just past the end of the file can read as zeros instead of raising SIGBUS, so bounds checks must not rely on a SIGBUS.

**Shell:**
- zsh does not word-split `$flags`: a variable holding "-debug -sanitize:address" is passed as a single argument. Run each configuration explicitly, or use `${=flags}`.
- macOS `sed` has no `\b`. Use python for word-boundary or multi-line edits.
- A glob that matches nothing aborts the whole zsh command line ("no matches found"), including anything chained after it with `&&` or `;`. Use `find … -exec rm` for cleanup, or quote the pattern.

**Metis:**
- `edit_document` refuses to edit a document not yet read with `read_document`. Editing the markdown file directly, then running `metis sync` and `metis validate <file>`, works.
- Metis writes files without a trailing newline, so a search anchored on a final `\n` fails.
- No command changes the project prefix. Edit `config.toml` and each document's `short_code`, then run `metis sync`.
