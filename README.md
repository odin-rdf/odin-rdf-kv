# odin-rdf-kv

An embedded key/value store for Odin, in the style of LMDB: a copy-on-write B+tree in one memory-mapped file, zero-copy reads, snapshot isolation with one writer and many readers, and crash safety without a write-ahead log. Pure Odin, with no dependency beyond the C library.

What sets it apart is that **the store limits its own memory**. It is built to run inside a process that holds other data too, where no process-wide limit (a cgroup, an rlimit) can single it out, and where there may be hundreds of such processes on one machine. You give it a budget for the pages of the file it keeps mapped in and a budget for a write transaction's dirty pages, and it stays within them. A database can be much larger than its budget (100 MB on disk, 20 MB resident), with the OS paging data in on demand. An idle store can be put to sleep with one call, and wakes on the next read.

- **API:** `put`, `get` and `del` on byte-string keys and values, sorted in `memcmp` order, and cursors with `first`, `last`, `seek`, `next` and `prev`.
- **Zero-copy reads:** `get` and cursors return slices that point straight into the map. A read allocates nothing.
- **Snapshots:** a reader sees the database as it was committed when it began, however many commits follow. Readers never block the writer and the writer never blocks readers.
- **Crash safety by ordering:** a commit writes its pages, syncs, writes a checksummed meta page, and syncs again. After a crash or power loss the file opens at the last commit that completed, with no recovery step.
- **Bounded memory:** a mapped-page budget (soft) and a dirty-page budget (hard; a large transaction spills to the file instead of growing).
- **Freed pages are reused** once no reader can still see them, so the file stays bounded under a steady workload.

## Status

All seven steps of the original design are built and tested: the file format, reads and writes, cursors, delete with merge, page reuse, the memory budget, and crash tests with fuzzing. The suite has 165 tests (184 in the build with the crash sweeps) and passes on macOS arm64 and on Linux arm64 and amd64.

- **No release is tagged yet**, and there is no CI workflow yet.
- **The file format is version 1**, and there is no migration path to any later version.
- **Platforms:** macOS (development) and Linux (production), 64-bit only. There is no Windows support.
- **Toolchain:** Odin `dev-2026-09`.

## Adding it to a project

Check the repository out beside your project and reach it through a collection, as the rest of the odin-rdf family does:

```sh
odin build . -collection:kv=../odin-rdf-kv
```

```odin
import kv "kv:kv"
```

If you use the Odin language server, mirror the collection in your `ols.json`. A relative import (`import kv "../odin-rdf-kv/kv"`) works too.

## Quick start

```odin
package example

import "core:bytes"
import "core:fmt"

import kv "kv:kv"

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
```

This is compiled and run by the test suite (`tests/readme_test.odin`), so it can't drift from the API.

## Concepts

### The environment

`env_open(path, options)` opens or creates the database file and returns an `^Env`. It takes an exclusive lock on the file, so a second `env_open` of the same file returns `.Locked`, whether it comes from another process or from this one. One `Env` per file per process, shared by all its threads. `env_close` needs every transaction ended first.

At open, the store reserves `Options.map_size` bytes of address space (1 GiB by default) and maps the file into it once. The mapping is never moved, which is what keeps every returned slice valid while the file grows. `map_size` is address space, not memory: it caps how large the database can grow, and a write that would pass it returns `.Map_Full` without changing anything. The file grows in steps of at least 1 MiB (or an eighth of its size) and never shrinks.

### Transactions

- **Read transactions**, `txn_begin(env)`, are cheap: a brief mutex to copy the current snapshot and register it. After that a reader holds no lock.
- **The write transaction**, `txn_begin(env, read_only = false)`, is one at a time: beginning a second blocks until the first ends, so a thread must never begin two.
- **Ending:** every transaction ends with `txn_abort`, which is also what `txn_commit` does once it has made the commit durable. Calling `txn_abort` more than once, or after `txn_commit`, is safe, so `defer kv.txn_abort(&txn)` right after `txn_begin` is the pattern.
- **A `Txn` is a value.** Begin it into a variable and pass that same variable by pointer. Use a transaction from one thread at a time.

A reader that stays open pins the snapshot it began on: pages freed after it cannot be reused until it ends, and the file grows to make room instead. Keep read transactions short, as you would with LMDB.

### Keys, values and slice lifetimes

- **Keys** are byte strings of 0 to 1,002 bytes (at 4 KiB pages; `kv.max_key_size(page_size)` in general), ordered by `memcmp`. Encode integers **big-endian** so they sort numerically.
- **Values** can be up to 4 GiB − 1. A value larger than about a quarter of a page goes into a contiguous run of overflow pages, so it is still returned as one slice.
- **A slice from a read transaction** (from `get` or a cursor) is valid until the transaction ends.
- **A slice from a write transaction** is valid only until that transaction's next `put` or `del`, which may move or spill the page it points into.
- **`put` must not be given a slice that points into the same transaction's pages.** Copy it first.
- **Values have no alignment guarantee.** Don't cast a slice to a struct pointer; copy the bytes out.

### Cursors

A `Cursor` is a value with no heap allocation and nothing to close. `cursor_seek(&c, key)` positions at the first key ≥ `key`; a range scan is `cursor_seek` followed by `cursor_next` until the key reaches the end of the range. At either end the cursor returns `.Not_Found`. In a write transaction, a `put` or `del` makes the transaction's cursors stale: reposition them with `cursor_first`, `cursor_last` or `cursor_seek` before stepping again (`cursor_stale` tells you; a debug build asserts).

### Errors

Every fallible call returns a `kv.Error`, an enum whose zero value is `.None`, so `or_return` works on it.

| Error | Meaning |
|---|---|
| `Not_Found` | No such key, or a cursor ran past the end. |
| `Map_Full` | The change would pass `map_size`. Nothing was changed; abort or commit what you have and reopen with a larger `map_size`. |
| `Key_Too_Large` | The key is longer than `max_key_size`. |
| `Txn_Read_Only` | A write through a read transaction. |
| `Locked` | The file is already open, in this process or another. |
| `Invalid_Argument` | An option out of range (page size, chunk size, budgets). |
| `Out_Of_Memory` | The environment's own memory, or the dirty-page pool, couldn't be allocated. |
| `Corrupted` | The file has no valid meta page, or a structure failed validation at open. |
| `Io` | A system call failed. |
| `Poisoned` | An earlier commit failed at or after its first sync; see below. |
| `Unsupported` | `env_resident_check` on macOS. |

A failure inside `put` or `del` after the tree has started to change leaves the transaction unusable: later calls return the same error, and it can only be aborted.

## API

These are the procedures to build on. The package also exports lower-level names (page layout, the dirty-page pool, the platform layer) because its tests reach them; treat those as internal.

| Procedure | |
|---|---|
| `env_open(path, options) -> (^Env, Error)` | Open or create a database. |
| `env_close(env)` | Unmap and close. All transactions must have ended. |
| `env_stats(env) -> Stats` | Sizes, readers, free pages, the memory figures; see below. |
| `env_sweep(env, target := -1) -> int` | Evict mapped pages. `target = 0` puts an idle store to sleep. |
| `env_resident_check(env) -> (int, Error)` | Ask the OS how much of the map is resident (Linux only). |
| `txn_begin(env, read_only := true) -> (Txn, Error)` | Begin a transaction. |
| `txn_commit(&txn) -> Error` | Make a write transaction durable and visible, then end it. |
| `txn_abort(&txn)` | End a transaction, discarding any changes. |
| `get(&txn, key) -> ([]byte, Error)` | Look up a key, zero-copy. |
| `put(&txn, key, value) -> Error` | Insert or replace. |
| `del(&txn, key) -> Error` | Remove a key (`.Not_Found` if absent). |
| `cursor_open(&txn) -> Cursor` | A cursor over the transaction's snapshot. |
| `cursor_first`, `cursor_last`, `cursor_seek`, `cursor_next`, `cursor_prev` | Position and step; each returns `(key, value, Error)`. |
| `cursor_stale(&c) -> bool` | Whether the cursor must be repositioned. |
| `tree_check(&txn)`, `space_check(&txn)` | Full structural checks, for tests and diagnostics: every page is walked. |

Every exported procedure has a contract-level doc comment in the source; those are the reference.

## Memory

`Options` has three knobs for memory, and `env_stats` reports each of them.

- **`dirty_budget`** (default 4 MiB): the pool a write transaction's modified pages live in. It is address space until a write transaction uses it, and returned to the OS when the transaction ends, so an idle store holds no dirty memory. A transaction that modifies more than this doesn't fail or grow: it spills its least recently used dirty pages to their final places in the file and carries on. This budget is hard.
- **`mapped_budget`** (default 0, no limit): how much of the file may stay mapped into the process. The store keeps an estimate in chunks of the map (`chunk_size`, 256 KiB by default, at least 64 KiB).
  - At the end of every transaction, if the estimate is above the budget, it evicts down to 7/8 of it.
  - A read that takes the estimate past the budget plus two chunks evicts inline.
  
  So the budget holds with no background thread and no call from the application. It is soft: under concurrency it can be passed by about one chunk per thread reading at that moment. Evicting never invalidates a slice: the address stays valid, and the page is read back from the OS page cache when next touched.
- **`env_sweep(env, 0)`** is the sleep path. After a long idle period (hours without a request), it evicts every mapped page while the store stays open. What remains is the `Env`, its tables and the free list: about 40–70 KiB, plus 16 bytes per free-list record. The next read wakes it with no reopen. `env_close` followed by `env_open` on wake is the alternative when even that should go.

**Per store, in use:** at most `mapped_budget` plus two chunks (plus about one chunk per concurrently reading thread), plus the dirty pool while a write transaction runs. With a 100 MB database, a 15 MiB mapped budget and the default pool, under mixed read, scan and write threads that never call `env_sweep`, the OS's resident figure plus the pool peaked at 7.2–10.0 MiB against a limit of 19.5 MiB, on macOS and Linux.

`env_stats` returns a `Stats`. The fields for sizing and monitoring:
- `resident_chunks` (the estimate), `chunk_faults` and `evictions`;
- `dirty_pages`, `dirty_committed` and `spills`;
- `readers` and `oldest_reader`;
- `free_ready` and `free_pending`;
- `file_pages`;
- `poisoned`.

The dirty-pool and chunk figures are live, readable while transactions run. `env_resident_check` asks Linux for the true resident size of the map (a `/proc/self/pagemap` walk, 0.1–0.3 ms for 100 MB). macOS has no per-range source for this, so there it returns `.Unsupported`.

## Durability and crash safety

A commit:
1. writes the free list and every dirty page, then syncs;
2. writes the other of the two meta pages, checksummed, then syncs again;
3. publishes the new snapshot to readers.

A sync is `F_FULLFSYNC` on macOS and `fdatasync` on Linux. At open, the valid meta page with the higher transaction id wins, and a bad checksum discards a meta page. There is no log to replay.

**What is tested.** A test-only hook records every write, sync and truncate the store makes; crash images are then built from that journal and opened with the real `env_open`.
- **Process kill:** at every I/O cut point of five workloads (a plain commit; a commit that spills, writes overflow values and a multi-page free list and grows the file; deletes that merge pages; commits that reuse pages; creating a file), the file reopens at exactly the last commit or the next one, and then passes a full structural check and takes another commit.
- **Power loss:** writes after the last sync lost, torn at 512-byte sectors, or kept in any subset. Every image opens at the last synced commit, or the next one only if its meta page is whole.
- **A damaged newest meta page** falls back to the previous commit.
- **A real `SIGKILL`** of a process committing with real syncs is tested too.

**If a commit's sync fails,** the environment is **poisoned**: every later write transaction returns `.Poisoned`, while reads carry on at the last commit this process published. Close and reopen the environment to recover; the open finds whichever commit is durable. Writing on would be unsafe, because the file may hold a meta page that points at pages this process still counts as free. LMDB's `MDB_PANIC` exists for the same reason. A failure before the first sync doesn't poison: those pages are unreferenced, and the environment carries on as if the transaction had been aborted.

**Limits:**
- **Only the meta pages are checksummed.** Bit rot in a data page is not detected; the durability argument assumes a sync that returns has made everything before it durable.
- **Creation:** a power loss that tears a meta-page write while the file is being created, with neither meta page whole, leaves a file that no rule opens (`.Corrupted`). Nothing was ever committed to it, but it must be deleted before the application can start. Whether a disk can tear a 512-byte sector write at all is an open question (KV-T-0038).
- **One process.** The reader table is in memory, so multi-process access is not supported; the file lock enforces that.
- **The directory entry** of a newly created file is not synced.

## Performance

Measured on an Apple M4 (macOS) and in an arm64 Linux VM, `-o:speed`, with the data in the page cache:

| | macOS | Linux arm64 |
|---|---|---|
| Random `get`, 200,000 keys | 385 ns | 415 ns |
| Random `get`, 1,000 hot keys | 226 ns | 226 ns |
| Random `get`, 4 threads (per get, all threads) | 110 ns | 112 ns |
| Random `get` of an 8 KiB overflow value | 259 ns | 266 ns |
| Cursor scan, per entry | 16.6 ns | 17.6 ns |

A commit is dominated by its two syncs: a small commit takes about 8 ms with `F_FULLFSYNC` on macOS, and about 1 ms on the Linux VM. So write throughput comes from batching many puts into one transaction, not from the per-put cost. Rewriting the free list costs about 4.5 ns per free page per commit. Putting a store to sleep takes 50–150 µs, and waking one by `env_open` takes 7 µs to 5 ms, depending on the length of its free list.

## Development

The design, every decision and the evidence behind it are in the Metis documents under `.metis/`, starting with `.metis/vision.md`; `CLAUDE.md` has the conventions, invariants and the full list of test commands.

```sh
scripts/test.sh                 # debug, -o:speed, AddressSanitizer, the crash sweeps, and type checks for darwin/linux × arm64/amd64
scripts/test.sh --steady        # plus the slow steady-state tests (minutes, thousands of synced commits)
scripts/test-linux.sh arm64     # the same in a Linux container (needs Docker); amd64 runs emulated
```

Two on-demand modes, never part of the default run:
- `-define:KV_FUZZ=true` runs the randomized model against an in-memory oracle for 10⁶ operations per seed; a failure reproduces from its seed alone.
- `-define:KV_KILL=true` runs the real-kill test.

The build switches `KV_IO_HOOK` and `KV_NO_SYNC` are for tests only; `KV_NO_SYNC` skips every sync and must never be used in a build that keeps data.

## License

MIT — see [LICENSE](LICENSE).
