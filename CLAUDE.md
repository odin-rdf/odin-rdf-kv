# odin-rdf-kv

An embedded, LMDB-style key/value store in Odin: a copy-on-write B+tree in one memory-mapped file, zero-copy reads, crash safety without a WAL, and (planned) a memory budget enforced by the store itself. Package `kv/`, tests in `tests/` (package `kv_tests`, importing `../kv`). `liblmdb/` is a local, git-ignored copy of upstream LMDB kept for reference only.

## Where the state lives

Metis (`.metis/`) is the system of record for plans, decisions and progress. Start here:

- `.metis/vision.md` (KV-V-0001): the design, the build order (steps 1–7) and the current state.
- `.metis/archived/initiatives/KV-I-0001/initiative.md`: steps 1–3 (completed and archived). Its **Results** section lists the exit-criteria evidence, every deviation from the design, and the known limitations.
- `.metis/archived/initiatives/KV-I-0002/initiative.md`: step 5, page reuse (completed and archived). Its **Results** section has the same, plus the steady-state and free-list cost measurements.
- Each task's **Status Updates** section records decisions made during implementation and the reasons for them.

`metis list` shows everything. `metis.db` is gitignored runtime state; after a fresh clone, run `metis sync` to rebuild it from the markdown.

**Next up:** step 4 (delete with merge), then step 6 (the memory budget). Delete frees pages through the same `freed` list, so page reuse needs no changes for it. `Stats` (`env_stats`) is where step 6's figures go. Two backlog items came out of KV-I-0002: KV-T-0014 (placing the free list's run in a fragmented pool) and KV-T-0015 (linear run searches).

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
scripts/test.sh -define:ODIN_TEST_NAMES=kv_tests.test_cursor_seek      # extra args go to every `odin test`
scripts/test.sh -define:ODIN_TEST_RANDOM_SEED=1234                      # reproduce a randomized failure (seed is in the message)
scripts/test-linux.sh arm64     # Linux container, debug and -o:speed; also amd64 (emulated)
```

- **Linux tests:** these need Docker. On macOS that is OrbStack, which is normally stopped: run `orb start` first and `orb stop` afterwards. `scripts/linux.Dockerfile` pins the Odin release, so keep its `ODIN_VERSION` in step with `odin version` (currently dev-2026-09).
- **ThreadSanitizer:** `-sanitize:thread` works on macOS arm64. Use it for `test_snapshot_isolation_across_threads` and `test_reader_table_across_threads`. A race only shows when the two accesses overlap, so run a threaded check more than once.
- **Suite time:** the plateau and full-map tests make 10⁴ synced commits each, and on macOS (`F_FULLFSYNC`, about 4 ms) they take about 3 minutes per configuration. While iterating, pass `-define:KV_STEADY_COMMITS=1000`.
- **Free-list cost measurement:** `odin test tests -o:speed -define:KV_BENCH=true -define:ODIN_TEST_NAMES=kv_tests.test_bench_free_list_cost`.
- **Supported targets:** only 64-bit targets are supported (`#assert(size_of(int) == 8)`).

## Code map

| File | Contents |
|---|---|
| `types.odin` | `Pgno`, `Txn_Id`, `Error`, format constants |
| `page.odin` | On-disk page and node layout, size limits, slotted-page operations, split helpers, `page_check` |
| `meta.odin` | Meta page layout and checksum |
| `env.odin` | Open and close, choosing the meta page, `meta_write`, the reader table, `env_stats` |
| `txn.odin` | `Txn` (a value type), `Write_State` (on the heap), the reuse horizon, `page_ptr` |
| `tree.odin` | `tree_search`, `get` |
| `write.odin` | `page_alloc` (loose, then reusable, then the end of the file), `pages_available`, `page_touch`, `put`, splits |
| `freelist.odin` | Free-list records and run layout, load and validate at open, release at `txn_begin`, build and place at commit |
| `overflow.odin` | Overflow value runs |
| `commit.odin` | `txn_commit`, file growth |
| `cursor.odin` | Cursors |
| `check.odin` | `tree_check`, and `space_check` (every page owned exactly once) |
| `os_*.odin` | Platform layer |

**Test helpers:**
- `tests/tree_helpers.odin`: `build_tree_file` builds any tree shape directly.
- `tests/model.odin`: the randomized model and `model_diff`. `run_model` in `tests/model_test.odin` also holds up to 4 readers across commits.
- `tests/helpers.odin`: temporary directories and `Page_Buf`.
- `tests/freelist_test.odin`: `open_hand_list` opens a database with a hand-written free list.
- `tests/steady_test.odin`: the steady-state workload (`steady_commit`) and `expect_latest_ok` (`space_check` and `tree_check` on a new reader).

**Other test files:** `reader_test.odin` (reader table), `reuse_test.odin` (reuse rules), `steady_test.odin` (`env_stats`, plateau, full map, long reader), `isolation_test.odin` (threads, including readers that come and go while pages are reused), and `bench_test.odin` (the free-list cost measurement, only registered with `-define:KV_BENCH=true`).

## Invariants and conventions

- **`page_ptr(txn, pgno)` is the only way to reach a page,** and step 6's memory accounting will hook in there. Overflow runs are read through `overflow_value`, which validates the run.
- **Zero-copy lifetimes:**
  - a slice from a read transaction is valid until the transaction ends;
  - a slice from a write transaction is valid until the next `put`;
  - `put` must not receive slices that point into the same transaction's dirty pages.
- **Clone before modifying:** copy any key or value you still need before rewriting the page it points into. Splits rewrite both pages, and a test helper got this wrong once.
- **Alignment:**
  - node headers are `#packed` and are read and written by value only; never take the address of a packed field;
  - page buffers outside the map must be at least 8-aligned (dirty pages are page-aligned);
  - in tests, cast only `Page_Buf` (`#align(16)`) to page structs, never a plain `[N]byte`.
- **Byte order:** integer keys must be encoded big-endian to sort numerically, and inline values have no alignment guarantee.
- **Write-path tests need a committed tree underneath.** Put into a tree that was committed first (for example with `build_tree_file`), otherwise every page is already dirty and copy-on-write never runs.
- **Structural checks:** tests call `kv.tree_check` or `kv.page_check` after changes, and `kv.space_check` after every commit.
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

**Platform:**
- Apple Silicon OS pages are 16 KiB. A 4 KiB database page just past the end of the file can read as zeros instead of raising SIGBUS, so bounds checks must not rely on a SIGBUS.

**Shell:**
- zsh does not word-split `$flags`: a variable holding "-debug -sanitize:address" is passed as a single argument. Run each configuration explicitly, or use `${=flags}`.
- macOS `sed` has no `\b`. Use python for word-boundary or multi-line edits.
- A glob that matches nothing aborts the whole zsh command line ("no matches found"), including anything chained after it with `&&` or `;`. Use `find … -exec rm` for cleanup, or quote the pattern.

**Metis:**
- `edit_document` refuses to edit a document not yet read with `read_document`. Editing the markdown file directly, then running `metis sync` and `metis validate <file>`, works.
- Metis writes files without a trailing newline, so a search anchored on a final `\n` fails.
- No command changes the project prefix. Edit `config.toml` and each document's `short_code`, then run `metis sync`.
