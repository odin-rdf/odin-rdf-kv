---
id: crash-tests-and-fuzzing
level: initiative
title: "Crash tests and fuzzing"
short_code: "KV-I-0005"
created_at: 2026-09-24T22:50:49.319079+00:00
updated_at: 2026-09-25T09:18:22.992592+00:00
parent: KV-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: M
initiative_id: crash-tests-and-fuzzing
---

# Crash tests and fuzzing Initiative

## Context

**Handoff (written 2026-09-25 at the end of the KV-I-0004 session).** This is a draft in discovery. Nothing is decided, no tasks exist, and no code has been written for it. The next session should read this, the vision (KV-V-0001) and `CLAUDE.md`, then settle the open questions below with the owner before moving the initiative to design.

*(Amended 2026-09-25: **the open questions are settled** — see **Decisions** below, D1–D9, the owner taking the recommendations on every point and adding `KV_NO_SYNC` (D3) because the GitHub organization is keeping CI runner minutes down across its repositories. The **Detailed Design** is drafted from them. The initiative stays in discovery until the owner has reviewed the design; no tasks exist yet.)*

This initiative is build step 7 of the vision: *crash tests (kill the process during commit) and fuzzing against a `map[string]string` oracle.* It carries two of the vision's success criteria:
- **Crash safety:** after a kill during any phase of commit, the database always reopens at the last committed state.
- **Correctness:** fuzzed operation sequences match the oracle, including range scans in both directions.

Steps 1–6 are done and archived (KV-I-0001 to KV-I-0004). The store has 161 tests, passing on macOS arm64 (debug, `-o:speed`, ASan, TSan for the threaded tests) and Linux arm64 and amd64 (containers).

### What already exists
- **An oracle-based randomized model test.** `tests/model.odin` and `tests/model_test.odin` (`test_model_randomized`, `test_model_randomized_min_pool`, `test_model_until_map_full`) run random puts, deletes, commits, aborts, reopens and held readers against an in-memory model, with full scans in both directions, `tree_check` and `space_check` after commits. The model stores `(version, size)` per key id rather than bytes. **So the correctness half of step 7 is partly built:** what is missing is a fuzzing mode (long or coverage-guided runs, seeds, minimization) rather than an oracle.
- **The commit order** (`kv/commit.odin`, `txn_commit`'s doc comment): build the free list and place its run; grow the file; write the dirty pages; sync; write the meta page for `txn_id + 1` into the other slot; sync; publish. At open, `meta_choose` (`kv/env.odin`) takes the valid meta page with the highest `txn_id`, and a bad checksum discards a meta page.
- **Writes before commit (KV-I-0004).** Pages can reach the file before the meta page for other reasons: spilled pool pages (`spill` in `kv/pool.odin`), overflow values written straight from the caller's buffer (`kv/overflow.odin`), and the free-list run streamed page by page (`kv/freelist.odin`). The safety argument is in the comment at `spill`: pages the write transaction allocated are in no snapshot anyone can read (the reuse horizon keeps snapshot S − 1 intact, KV-I-0002 D1), so a crash leaves only unreferenced bytes in free pages. **The crash tests must exercise this**, the amendment to vision step 7 says so explicitly.
- **The I/O call sites.** Every write and sync goes through the platform layer (`kv/os_posix.odin`, `os_darwin.odin`, `os_linux.odin`): `os_pwrite` from `commit.odin`, `env.odin` (meta pages), `freelist.odin`, `overflow.odin` and `pool.odin`; `os_sync` from `commit.odin` and `env.odin`; `os_truncate` from `env.odin` (file growth, and creating a new file). There is **no injectable I/O seam** today: these are direct procedure calls.
- **The sibling repository odin-rdf-record** solved the same problem for its log (`RECORD-T-0002`): a single-writer append path behind an injectable `File_Ops` seam, **crash-swept at every operation cut point**, with an in-memory file system (`Mem_FS`). It is a useful precedent, not a dependency: this store has no seam, and whether to add one is open question 1.

### What a crash can and cannot mean here
- **A process kill** (`SIGKILL`): every `pwrite` that returned is in the OS page cache and survives; nothing the process didn't write exists. This tests ordering against the process's own view, and is what the vision literally asks for.
- **A power loss or kernel crash:** writes after the last completed sync may be lost, partly written, or reordered at block or page granularity. This is the stronger claim ("crash safety comes from ordering and checksums") and needs a simulated disk that drops or tears unsynced writes. A kill test cannot show it.

## Goals & Non-Goals

**Goals (confirmed 2026-09-25):**
- A crash harness that cuts the store at every I/O operation of `txn_commit`, and of transactions that spilled, wrote overflow runs or streamed the free list before committing, then reopens and checks that the database is a state it is allowed to be in (model comparison, `tree_check`, `space_check`) and that the next commit works. Both a **process kill** and a **power loss** (lost, torn and reordered unsynced writes) are simulated (D1, D2).
- The same across `env_open` of a new file (between `truncate` and the sync after the two meta-page writes), with the defined outcome of D6.
- The env refuses further writes after a failed sync or meta-page write (D7), with a test that fails without it.
- A fuzzing mode over the existing model: long runs by seed, reproducible from the seed in the failure message, on demand (D4, D5).
- Cheap by default, on CPU and on CI minutes (D3, D8, D9).

**Non-Goals:**
- Multi-process access (out of scope in the vision).
- Recovering from corruption other than a torn commit (bad sectors, bit flips in data pages): a checksum on data pages isn't in the format.
- A coverage-guided fuzzer (D4), and test-case minimization.
- Testing the physical durability of `F_FULLFSYNC` or `fdatasync` themselves: the simulation assumes a sync that returns has made everything before it durable, which is the contract the store is written against.

## Decisions (2026-09-25)

The owner took the recommendations on every point. The open questions below are kept as the record; each is answered here.

- **D1 (Q1): cut through a recording I/O journal, not failpoints; plus one small real-kill test on demand.** A test-only hook in `os_pwrite`, `os_sync` and `os_truncate`, compiled in only with `-define:KV_IO_HOOK=true`, records every operation (kind, offset, a copy of the bytes, the new size) while still performing it for real — spilled pages are read back through the map within the transaction, so the writes must happen. Crash images are then built from the journal after the fact, one per cut point, and opened with the real `env_open`. A hook that *returns an error* at operation *n* is not a crash (the process runs on and the transaction aborts) and is used only for D7's fault injection. The real-kill test is one test behind `-define:KV_KILL=true`, never in CI: it runs a separate helper binary (`fork()` in the multithreaded test runner is unsafe in the child) and `SIGKILL`s it.
- **D2 (Q2): power loss is simulated.** From the same journal: the durable image is everything up to the last completed sync plus a subset of the later writes, each of which may be torn at 512-byte granularity; a truncate after the last sync may or may not have taken effect. Per cut point the sweep takes fixed images (none of the later writes, all of them, only the meta page, a torn meta page) and a number of random subsets by seed.
- **D3 (new): `-define:KV_NO_SYNC=true` makes `os_sync` a no-op**, after the hook has recorded it, so the journal still sees every sync. **Why it loses nothing:** a sync is observable by a test only through its cost and its error return. No test can see durability — a process kill loses nothing a `pwrite` handed to the OS, and D2 simulates power loss from the journal. Its error return is covered by D7's fault injection. **Why it matters:** the model test spends about 2.7 of its 4 s in `F_FULLFSYNC` on macOS (measured 2026-09-25: 336 synced commits in 100,000 operations, about 8 ms each), and the GitHub organization is keeping CI runner minutes down. It is test-only, like `KV_NO_CHUNK_ACCOUNTING`, and never meant for a production build. `scripts/test.sh` keeps real syncs in its configurations, so `os_sync` itself still runs locally.
- **D4 (Q3): fuzzing is seeds only.** Long runs of the existing `run_model` by seed. No coverage-guided fuzzer (it would need a libFuzzer harness through the C ABI) and no minimizer; a failure reports its seed and operation number, as today.
- **D5 (Q4): everything long is on demand behind a define, with a short default,** and runs with `-define:ODIN_TEST_THREADS=2`. The fuzz mode (`KV_FUZZ`) runs with `KV_NO_SYNC` unless told otherwise, so it is CPU-bound and uses exactly the threads it is given. `KV_FUZZ_CHECK_EVERY=k` runs the full `model_compare` and `space_check` every *k* commits instead of every commit (default 1), the lever if CPU is the limit; a failure then surfaces up to *k* commits late.
- **D6 (known point 1): a new file with nothing written is recreated.** If `env_open` finds a file of exactly two pages (at the page size this open would use) whose bytes are all zero, it initialises it as new. Anything else without a valid meta page stays `Corrupted`, so a damaged database is never quietly replaced by an empty one. A file of size 0 is already treated as new; one torn meta slot next to a valid one already opens.
- **D7 (known point 3): a failed sync or meta-page write poisons the env.** Found while settling the questions: after `meta_write` or either `os_sync` in `txn_commit` fails, the new meta page may be durable while the env keeps the previous snapshot and `env.free`. The next write transaction can reuse pages the failed commit wrote into (from `env.free`, or past the old `last_pgno`), overwrite them and crash before its own meta page, leaving a durable meta page that points at overwritten pages. A failure of the first sync is poisoned too: it can't make that happen directly, but after a failed `fsync` the kernel may have dropped the dirty pages it could not write, and the store can no longer vouch for the file. So the env records the failure, and every later `txn_begin(rw)` returns a new `Error` value, `.Poisoned`; read transactions carry on, and `env_close` plus `env_open` recovers from whatever is durable. LMDB's equivalent is `MDB_PANIC`. The test injects the failure through the D1 hook, and must fail without the flag.
- **D8 (known points 2 and 4): confirmed by the harness, no design needed.** Unreferenced zero pages after `file_grow` are covered by the sweep's cut after the truncate; the platform difference is outside what the simulation can show and is covered by the D3 argument.
- **D9: CI.** This repository has **no CI workflow** today; the owner will add one soon, modelled on odin-rdf-record's `.github/workflows/ci.yml` (2026-09-25). That workflow is outside this initiative. What this initiative needs from it, and what it gives it:
  - **Its shape carries over:** the `ubuntu-latest` and `macos-latest` matrix with `fail-fast: false`; `paths-ignore` for `.metis/**` (so this initiative's document commits run nothing); `concurrency` with `cancel-in-progress`; `workflow_dispatch`; `laytan/setup-odin`. Simpler than the record's: this store has no sibling checkout, no python and no Makefile, so the steps are `odin check` and `odin test` directly. Both runners are worth keeping: macOS has its own code paths here (`F_FULLFSYNC`, the `MAP_FIXED` remap for eviction and pool release, `task_info`), and the ubuntu runner is native Linux amd64, which locally is only reached through an emulated container.
  - **The test step passes `-define:KV_NO_SYNC=true`** (D3). On the macOS runner every commit would otherwise pay `F_FULLFSYNC`, and macOS minutes are the expensive ones (GitHub bills them at 10× Linux for private repositories).
  - **One build per runner, `-o:speed`**, plus the cross-target `odin check`s, which compile but don't run and cost little. The debug and ASan builds, TSan, `--steady`, the fuzz mode, the real-kill test, the criterion and the benchmarks stay local.
  - **The small crash sweep is in the ordinary suite, so CI runs it**, once measured at about a second (see the design). The large sweep (`KV_CRASH`) does not run in CI.
  - The Odin release: the record uses `release: latest`; this repository pins `dev-2026-09` in `scripts/linux.Dockerfile`, and the workflow should pin the same, so CI and the container agree.

## Open questions for the owner

*(Settled 2026-09-25 — see Decisions D1–D5. Kept as the record.)*

1. **How to cut:** (a) an injectable I/O seam (a `File_Ops`-style table, or a test-only failpoint hook inside `os_pwrite`/`os_sync`/`os_truncate`) that can stop after operation *n*; or (b) real process kills: fork a child that commits and `SIGKILL` it at a random time, or at a failpoint. (a) is deterministic and sweeps every cut point; (b) is closer to the vision's words and catches things a seam can't (for example the mmap's behaviour). A combination is likely: a sweep through a seam, plus a smaller real-kill test.
2. **Power-loss simulation:** should the harness also model lost, torn and reordered unsynced writes (a simulated file that keeps the synced state and applies an arbitrary subset of unsynced page writes on "power loss")? That tests the meta-page checksum and the two syncs, and it's where a real bug would most likely hide. It needs the seam from question 1(a).
3. **Fuzzing depth:** seed-driven long runs of the existing model (cheap), or a coverage-guided fuzzer (Odin has no built-in one; it would mean a libFuzzer-style harness via the C ABI). Proposal to discuss: seeds only.
4. **CPU use:** the owner avoids long, all-core test runs (the steady-state tests hit 100–500%, and a suite run briefly pinned about 10 cores). The crash sweep and fuzzing should be on demand behind a define, with a short default, and able to run with `-define:ODIN_TEST_THREADS=2`.

## Known points to check (found during KV-I-0004)

*(Settled 2026-09-25 — see Decisions D6–D8.)*

- `env_open` of a **new** file writes both meta pages then syncs once; a crash between the truncate and the sync leaves a file of the right size with zero or one valid meta page. What should the next open do: recreate, or return `Corrupted`? Today `meta_choose` returns not-found → `Corrupted` for a zero-filled file.
- `file_grow` truncates the file larger before the writes; a crash after it leaves a longer file with unreferenced zero pages. That should be harmless (the meta page's `last_pgno` bounds everything); the harness should confirm it.
- If only the final sync of a commit fails, the doc comment says the next open sees whichever state is durable, while the process keeps the previous one. The harness should cover that case explicitly.
- Linux production, macOS development: `F_FULLFSYNC` on macOS, `fdatasync` on Linux. A kill test behaves the same on both; a power-loss simulation is platform-independent by construction.

## Detailed Design

*Draft, 2026-09-25, for the owner's review before the initiative moves to design.*

### The I/O hook (D1, D3)

- A procedure variable in `kv/`, `@(thread_local) io_hook: proc(op: Io_Op) -> Error`, and an `Io_Op` carrying the kind (`Write`, `Sync`, `Truncate`), the fd, the offset, the bytes and the size. `os_pwrite`, `os_sync` and `os_truncate` call it first when it is set, inside `when IO_HOOK { … }` (`IO_HOOK :: #config(KV_IO_HOOK, false)`), so a production build has no branch. A non-`.None` return is returned from the operation without performing it (D7's fault injection).
- **Thread-local, not global:** tests run in parallel threads, and every write of a transaction happens on the thread that holds it, so each test's hook sees only its own env's I/O. `env_open`'s `init_meta_pages` runs on the opening thread too.
- `os_sync` with `KV_NO_SYNC` returns `.None` after the hook, without the system call. Both are `#config` constants beside `CHUNK_ACCOUNTING`, documented as test-only.
- `kv.IO_HOOK` and `kv.NO_SYNC` are exported so a test can refuse to run (or log) in the wrong build.

### The journal and crash images (D1, D2)

- A test helper (`tests/crash.odin`) installs a hook that appends each operation to a journal, copying the bytes. The harness starts from a **baseline**: the database file copied at a point where it is fully synced (after a commit, or before the file exists), plus the model state and the list of committed models the workload will produce.
- **Kill image at cut *n*:** the baseline with operations 0..*n* applied in order.
- **Power-loss image at cut *n*:** the baseline, operations up to the last sync before *n*, then a subset of the operations after it. Each write in the subset is applied whole, or torn: a random subset of its 512-byte sectors. A truncate in the subset changes the size (growing with zeros); one outside it does not. Fixed images per cut: none, all, meta page only, torn meta page; then `KV_CRASH_SUBSETS` random ones (default 4).
- **What an image may open as:** the committed state of the last commit whose second sync precedes the cut, or — only if that commit's successor has its meta-page write in the image, whole — the successor's state. A kill image is exact: the successor's state if and only if its meta write precedes the cut. Every image must also pass `tree_check` and `space_check`, take one more commit, and reopen at that commit.
- Images are written to one temporary file per test and reused; a sweep of *k* cuts makes *k* × (1 + 4 + subsets) opens and no syncs under `KV_NO_SYNC`.

### The workloads swept

Each is small enough that its whole journal is swept, cut by cut:
1. A single commit of a few puts on a committed tree (the plain commit order).
2. A commit with the smallest pool (`MIN_DIRTY_BUDGET`) that spills, with overflow values, and a free list long enough for a multi-page run written through `freelist_write`.
3. Deletes that merge and collapse the root.
4. Three commits in a row, so a cut in the second or third lands on a file with reused pages (the reuse horizon, KV-I-0002 D1).
5. `env_open` of a new file (D6).

The default sweep runs these at a size that is measured to take about a second in total, and is part of the ordinary suite; `KV_CRASH=true` runs larger trees and more random subsets.

### New file (D6)

`env_open`: if the file is exactly `2 × page_size` and both pages are all zero, treat it as size 0 and call `init_meta_pages`. The check reads 2 pages, only when `meta_choose` found no valid meta page.

### Poisoning (D7)

- `Env.poisoned` (atomic bool). Set in `txn_commit` when `meta_write` or either `os_sync` fails, and in `init_meta_pages`'s callers never (a failed open returns its error and leaves no env).
- `txn_begin(rw)` returns `.Poisoned` while it is set; read transactions, `env_stats` and `env_sweep` are unaffected; `env_close` works as ever. `Stats.poisoned` reports it.
- Tests: inject a failure at each of the three points through the hook; the next `txn_begin(rw)` returns `.Poisoned`; readers still see the previous commit; reopening yields either commit, both passing the checks. A deliberate-bug check: without the flag, a scripted sequence (failed final sync with the meta page durable, a second transaction reusing the failed commit's pages, a kill image before its meta write) must open as corrupted.

### Fuzz mode (D4, D5)

- `-define:KV_FUZZ=true` registers `test_fuzz_model`: `run_model` for `KV_FUZZ_OPS` operations (default 10⁶, about 13 s of CPU with `KV_NO_SYNC` by the 2026-09-25 measurement) over `KV_FUZZ_SEEDS` consecutive seeds (default 1) starting at the runner's seed, alternating the default and the smallest pool, and varying the key count per seed.
- `KV_FUZZ_CHECK_EVERY=k` (default 1) passes through to `run_model`'s `verify_committed` and `space_check` calls.
- The model's existing seed-and-operation messages are the reproduction; nothing else is recorded.

### The real-kill test (D1)

`-define:KV_KILL=true` registers one test that builds and runs a helper (`tests/killer/`, its own package) which commits numbered values in a loop, printing each commit's id after `txn_commit` returns. The test kills it with `SIGKILL` after a random delay, several times, and checks each reopen is at the last printed commit or the one after. With real syncs, by design.

## Implementation Plan

Decomposed 2026-09-25, the owner moving the initiative through design and ready to decompose. One commit per task, in this order:

1. **KV-T-0026** — the I/O hook, `KV_NO_SYNC` and the journal (D1, D3).
2. **KV-T-0027** — the kill-image sweep over workloads 1–4 (D1, D8).
3. **KV-T-0028** — power-loss images: lost, torn and reordered writes (D2).
4. **KV-T-0029** — recreate a new file with nothing written, and sweep creation (D6, workload 5).
5. **KV-T-0030** — poison the env after a failed sync or meta-page write (D7).
6. **KV-T-0031** — the seeded fuzz mode (D4, D5).
7. **KV-T-0032** — the real-kill test with a helper process (D1).
8. **KV-T-0033** — measure the sweep, admit it to the suite and CI (D9), and document step 7.