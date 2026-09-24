# odin-rdf-kv

An embedded, LMDB-style key/value store in Odin: a copy-on-write B+tree in one memory-mapped file, zero-copy reads, crash safety without a WAL, and (planned) a memory budget enforced by the store itself. Package `kv/`, tests in `tests/` (package `kv_tests`, importing `../kv`). `liblmdb/` is a local, git-ignored copy of upstream LMDB kept for reference only.

## Where the state lives

Metis (`.metis/`) is the system of record for plans, decisions and progress. Start here:

- `.metis/vision.md` (KV-V-0001): the design, the build order (steps 1–7) and the current state.
- `.metis/initiatives/KV-I-0001/initiative.md`: steps 1–3 (completed). Its **Results** section lists the exit-criteria evidence, every deviation from the design, and the known limitations.
- Each task's **Status Updates** section records decisions made during implementation and the reasons for them.

`metis list` shows everything. `metis.db` is gitignored runtime state; after a fresh clone, run `metis sync` to rebuild it from the markdown.

**Next up:** step 5 (reuse freed pages, with the reader table) or step 4 (delete with merge). The `freed`/`loose` page lists and the meta page's free-list fields are already in place for step 5.

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
- **ThreadSanitizer:** `-sanitize:thread` works on macOS arm64. Use it for `test_snapshot_isolation_across_threads`.
- **Supported targets:** only 64-bit targets are supported (`#assert(size_of(int) == 8)`).

## Code map

| File | Contents |
|---|---|
| `types.odin` | `Pgno`, `Txn_Id`, `Error`, format constants |
| `page.odin` | On-disk page and node layout, size limits, slotted-page operations, split helpers, `page_check` |
| `meta.odin` | Meta page layout and checksum |
| `env.odin` | Open and close, choosing the meta page, `meta_write` |
| `txn.odin` | `Txn` (a value type), `Write_State` (on the heap), `page_ptr` |
| `tree.odin` | `tree_search`, `get` |
| `write.odin` | `page_alloc`, `page_touch`, `put`, splits |
| `overflow.odin` | Overflow value runs |
| `commit.odin` | `txn_commit`, file growth |
| `cursor.odin` | Cursors |
| `check.odin` | `tree_check` |
| `os_*.odin` | Platform layer |

**Test helpers:**
- `tests/tree_helpers.odin`: `build_tree_file` builds any tree shape directly.
- `tests/model.odin`: the randomized model and `model_diff`.
- `tests/helpers.odin`: temporary directories and `Page_Buf`.

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
- **Structural checks:** tests call `kv.tree_check` or `kv.page_check` after changes.

## Pitfalls hit so far

**Odin (dev-2026-09):**
- `or_return` needs the last return value to be a bool, or an error that can be compared with nil. A `(ok: bool, reason: string)` result can't use it.
- `where` is a keyword, so it can't be used as a parameter name.
- `x if c else y` can't choose between calls that return several values. Choose the procedure first, then call it.
- `testing.logf` doesn't exist; use `core:log`.
- Procedures can't capture variables. Pass data to a comparator through `context.user_ptr`.
- `offset_of` returns `uintptr`, so it needs a cast before mixing with `int`.
- `flock` and `F_FULLFSYNC` aren't in `core:sys/posix`; they're declared locally in `kv/os_*.odin`.

**Platform:**
- Apple Silicon OS pages are 16 KiB. A 4 KiB database page just past the end of the file can read as zeros instead of raising SIGBUS, so bounds checks must not rely on a SIGBUS.

**Shell:**
- zsh does not word-split `$flags`: a variable holding "-debug -sanitize:address" is passed as a single argument. Run each configuration explicitly, or use `${=flags}`.
- macOS `sed` has no `\b`. Use python for word-boundary or multi-line edits.

**Metis:**
- `edit_document` refuses to edit a document not yet read with `read_document`. Editing the markdown file directly, then running `metis sync` and `metis validate <file>`, works.
- Metis writes files without a trailing newline, so a search anchored on a final `\n` fails.
- No command changes the project prefix. Edit `config.toml` and each document's `short_code`, then run `metis sync`.
