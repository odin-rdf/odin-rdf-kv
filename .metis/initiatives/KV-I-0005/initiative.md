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

## Results (2026-09-25)

All eight tasks (KV-T-0026 to KV-T-0033) are done; KV-T-0033 was completed after the coordinator's steady-state run. The ordinary suite has 164 tests and the hooked build (`KV_IO_HOOK` + `KV_NO_SYNC`) 183: the 19 more are the ten crash sweeps, five journal tests and four poison tests, registered only there. Both pass on macOS arm64 (debug, `-o:speed`, ASan; hooked debug and `-o:speed`) and on Linux arm64 and amd64 (debug, `-o:speed`, hooked debug, hooked `-o:speed`). The fuzz mode and the real-kill test ran in their tasks (KV-T-0031, KV-T-0032), on demand, and not again here. **Steady-state tests (`scripts/test.sh --steady`):** run by the coordinator after KV-T-0033, on macOS arm64 (2026-09-25): **all pass** — debug 168 (4 min 10 s), `-o:speed` 168 (3 min 29 s), ASan 168 (3 min 41 s), hooked debug 187 (22 s: with `KV_NO_SYNC` the steady tests run without `F_FULLFSYNC`), and every cross-target check; 11 min 52 s wall, 177% CPU on average. Not run in the Linux container. Each task's status section records its decisions, measurements and deliberate-bug checks. The initiative itself awaits the owner's review.

### Exit criteria

| Goal | Status | Evidence |
|---|---|---|
| A crash harness cutting at every I/O operation of a commit, including transactions that spilled, wrote overflow runs or streamed the free list first; reopen checked against the model, `tree_check`, `space_check`, and the next commit | ✓ | `tests/crash.odin` and `tests/crash_sweep_test.odin` (KV-T-0026, -0027). Kill images at every cut of workloads 1–4: puts 17 cuts, spill 99 (spilling, overflow values, a free-list run of more than one page, one cut right after the file grew), deletes 6 (a merge and a root collapse), reuse 50 over three commits (each writing into pages at or below its starting `last_pgno`); each workload asserts it did what it is named for. Every image opens at exactly the expected txn, passes `model_diff` (every key, both scan directions), `space_check`, one more commit and a reopen |
| Both a process kill and a power loss simulated | ✓ | Power-loss images per window before each sync (KV-T-0028): none, all, only the meta page, the meta page torn, and 16 random subsets with 512-byte sector tears (a meta write torn to a byte prefix): 222 images over workloads 1–4 by default, 2,430 with `KV_CRASH_SUBSETS=200`. Each opens at the last synced commit or, only if the successor's meta page is whole in the image, the successor. Plus a meta-corruption image per cut (the newest meta page unreadable → S − 1, KV-I-0002 D1's horizon). Plus a real `SIGKILL` of a helper process with real syncs, on demand (KV-T-0032) |
| The same across `env_open` of a new file (D6) | ✓, with an open exception | `env_open` recreates an all-zero two-page file (KV-T-0029). Every kill cut of creation opens as an empty database, at 4 KiB and 16 KiB pages. Of the 50 fixed power-loss creation images, 11 open and 39 stay `.Corrupted` under D6 as decided; the sweep pins them. **KV-T-0035**, an open owner decision. *(Amended 2026-09-25: recounted, 12 open and 38 refused, 14 torn and 24 short. KV-T-0035 then added a sync after the truncate: creation is 6 kill cuts per page size, and the power sweep 27 fixed images over two windows, of which 13 open and 14 stay `.Corrupted`, all a torn meta write with neither whole; none with the sizing lost, which the sweep asserts. The remainder is KV-T-0038, an open owner decision.)* |
| The env refuses writes after a failed sync or meta-page write (D7), with a test that fails without it | ✓ | `Error.Poisoned`, `Stats.poisoned` (KV-T-0030); `tests/poison_test.odin` injects each of the three failures. Without the flag, the final-sync case reproduces D7's hazard: the next transaction rewrote all 14 pages the failed commit wrote, and the kill image before its meta page opened as `.Corrupted` |
| A fuzzing mode over the model, by seed, reproducible (D4, D5) | ✓ | `-define:KV_FUZZ=true`, `test_fuzz_model` (KV-T-0031); options derived from the seed alone; a failure at seed 7, op 251,718 of a six-seed run reproduced alone at the same operation, at k = 10 and k = 1 |
| Cheap by default, on CPU and CI minutes (D3, D8, D9) | ✓ | The default sweep costs 0.27 s at `-o:speed` and 0.9 s debug on one thread (below); `KV_NO_SYNC` halves the hooked suite's time; everything long is behind a define; the CI invocation is below |

The vision's two criteria: **crash safety** (a kill at any phase of commit reopens at the last committed state) is met for every cut of five workloads, by construction of the kill images and by the real-kill test, and holds under the stronger power-loss model except for creation (KV-T-0035). *(Amended 2026-09-25: except for a torn meta write during creation, KV-T-0038; KV-T-0035's sync after the truncate removed the other class.)* **Correctness** (fuzzed sequences match the oracle, both scan directions) is met by the model and its fuzz mode; see the vision's Current State, amended 2026-09-25.

**Deliberate-bug checks**, each failing a test (details in the tasks): skipping the hook in each of the three procedures, recording a wrong offset, ignoring the hook's error or `NO_SYNC`, a global hook (KV-T-0026); the meta page before the data pages, copy-on-write freeing a committed page as loose, `page_free` making committed pages loose (KV-T-0027); no meta checksum, the first sync dropped, the lower `txn_id` chosen, the meta page into a fixed slot, a reuse horizon of S (KV-T-0028); accepting any all-zero file, removing the rule, dropping the zero check, the wrong page size (KV-T-0029); the flag never set, ignored, set too early, or not set on the final sync (KV-T-0030); an overflow off-by-one caught by the fuzz mode at the three seeds the ordinary tests missed (KV-T-0031); the real-kill test does **not** see ordering bugs, by design, and does see a meta page synced before its data (KV-T-0032).

### Measurements (KV-T-0033)

The default sweep is every test registered only by `KV_IO_HOOK` in `crash_sweep_test.odin`: kill and power-loss images over workloads 1–5 and the meta-corruption images. Hooked build, `KV_NO_SYNC`, `-define:ODIN_TEST_THREADS=1`, time as the test runner reports it (building not included). macOS arm64 is an M4 Pro, with a load average of 3–5 from other work; Linux arm64 is the OrbStack container (`scripts/linux.Dockerfile`).

| | macOS arm64 `-o:speed` | macOS arm64 debug | Linux arm64 `-o:speed` | Linux arm64 debug |
|---|---|---|---|---|
| default sweep (10 tests) | 0.27 s (268, 271 ms) | 0.85, 0.89 s | 0.35, 0.37 s | 0.96, 0.96 s |
| the other hooked-only tests (5 journal, 4 poison) | 0.09 s | 0.24 s | 0.06 s | 0.23 s |
| `KV_CRASH=true` sweep (10 tests) | 10.5 s | — | 15.9 s | — |

Per workload in the default sweep at `-o:speed`, macOS: kill: create 5 + 5 cuts, 12 ms; deletes 6, 7 ms; puts 17, 18 ms; reuse 50, 28 ms; spill 99, 53 ms. Power loss: create 66 + 66 images, 19 ms; deletes 37 images + 2 meta-corruption, 14 ms; puts 37 + 2, 31 ms; reuse 111 + 4, 49 ms; spill 37 + 2, 39 ms. The rest of the 0.27 s is building each workload's trees. Under `KV_CRASH` on macOS the kill sweep is most of it: reuse 1,064 cuts 7.5 s, spill 605 cuts 0.70 s, deletes 74 cuts 0.43 s, puts 24 cuts 0.16 s; the power sweeps 0.2–0.9 s each (Linux: reuse kill 10.5 s, spill kill 2.4 s).

**Nothing was shrunk or moved behind `KV_CRASH`:** the default sweep is 0.27 s at `-o:speed` and under 1 s in a debug build, against the criterion's 2 s.

### CI (D9)

**The default sweep is admitted to the ordinary suite as it stands**: it is registered by `KV_IO_HOOK`, which the CI invocation sets, so CI runs it with no further define. The ordinary unhooked builds don't register it (the hook is compiled out of them, by design), and `scripts/test.sh` and `scripts/test-linux.sh` already run a hooked build. The invocation, ready for the workflow's steps (one build per runner, D9; the Odin release pinned to `dev-2026-09` like `scripts/linux.Dockerfile`):

```sh
# Type checks for every supported target (compile, don't run)
for target in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
	odin check kv -no-entry-point -vet -strict-style -target:"$target"
	odin check tests -no-entry-point -vet -strict-style -target:"$target"
	odin check tests -no-entry-point -vet -strict-style -target:"$target" -define:KV_IO_HOOK=true -define:KV_NO_SYNC=true
	odin check tests/killer -vet -strict-style -target:"$target"
done
# The suite, once, optimised, with the I/O hook (the crash sweeps) and no syncs
odin test tests -vet -strict-style -o:speed -define:KV_IO_HOOK=true -define:KV_NO_SYNC=true
```

Measured: the 16 checks take 1.0 s on macOS arm64 and 1.5 s on Linux arm64. The test step is about 5 s of build and 2.8–2.9 s of run for 183 tests: 8.1 s wall on macOS arm64 with 3 test threads (a `macos-latest` runner has 3 cores), 8.6 s in the Linux arm64 container with 4 (`ubuntu-latest` has 4). So about 10 s per runner beyond setup, on hardware faster than a runner's. Nothing on demand runs in CI: not the debug or ASan builds, TSan, `--steady`, `KV_CRASH`, the fuzz mode, the real-kill test, the criterion or the benchmarks.

**Found by timing the invocation, fixed here:** two tests of the ordinary suite failed in exactly this configuration, neither a store bug.
- `test_reader_table_across_threads` failed **every time on Linux** with `KV_NO_SYNC`, debug or `-o:speed` ("only 54 read transactions across 300 commits", 47–237 in a dozen runs): without syncs its 300 commits end before the six reader threads are well under way. It had passed in `scripts/test-linux.sh`'s hooked debug run only because the rest of the suite loaded the CPU. The writer now commits until the readers have begun more than 300 read transactions (a shared atomic count), up to 30,000 commits; on Linux that is 370–1,140 commits, on macOS still 300. Checked under TSan on macOS, with and without the hook.
- `test_env_stats` failed at about 1% of seeds, in every build (3 of 300 random seeds; seed 6136440337835298 reproduces it in a plain debug build): a round of 20 random keys can draw a key twice, and a key overwritten twice with overflow values frees the run it allocated first as a loose page, which the commit puts straight into the free list's `ready` part, so "freed pages pending, none ready" did not hold. `steady_commit` gained `unique_keys` (no key drawn twice in a commit) and the test uses it; the three seeds pass, and 500 random seeds after the fix all pass. The other steady tests keep their random draws.

`scripts/test-linux.sh` now runs the hooked build at `-o:speed` too, so the CI invocation runs natively on Linux locally before a push; it was the configuration that showed the first failure.

### Deviations from the design

- **KV-T-0026:** `IO_HOOK` and `NO_SYNC` live in `os_posix.odin`, beside the procedures they change, not beside `CHUNK_ACCOUNTING`. `journal_image_kill`'s `n` is a count. `NO_SYNC` turned out assertable after all (`os_sync(-1)`).
- **KV-T-0027:** three of the four deliberate bugs its criterion named are invisible to a kill image by construction (a missing sync, the meta slot written, the reuse horizon); kill-visible equivalents were checked, and the three moved to KV-T-0028. The cut after `file_grow`'s truncate needed a baseline built with a small map, since the file grows by at least 1 MiB.
- **KV-T-0028:** power-loss images per **window** before each sync, not per cut (an intermediate cut can only produce a subset of the images of the window it is in), and 16 random subsets by default, not 4. A **meta-corruption** image was added, beyond the power-loss model, because it is the only way to show the S − 1 horizon.
- **KV-T-0029:** power-loss creation images that D6 refuses are pinned as `.Corrupted` and counted, not made to open (KV-T-0035). The sweep also runs at 16 KiB pages.
- **KV-T-0030:** the reopen after a failure is asserted exactly per point (the hook fails an operation whole), rather than "either state".
- **KV-T-0031:** a seed's pool and key count come from the seed alone; `KV_FUZZ_CHECK_EVERY` counts transaction ends, not commits. The oracle is the existing model (a version and size per key, values regenerated), not a `map[string]string`.
- **KV-T-0032:** on Linux it runs through a direct `docker run`, since `scripts/test-linux.sh`'s hooked runs set `KV_NO_SYNC`, which the test refuses.
- **KV-T-0033:** `KV_CRASH` selects larger trees only; the design said "larger trees and more random subsets", and the subsets are `KV_CRASH_SUBSETS` on its own. Two timing- and seed-dependent tests fixed (above), and a fourth configuration in `scripts/test-linux.sh`.

### Known limitations

- **A power loss during creation can leave a file that never opens** (KV-T-0035, **an open decision for the owner**): the truncate lost under a kept meta write, or a meta write torn with no whole one beside it. It holds no data, since nothing was committed. Recommended there: a sync after the truncate now, and the sector-atomicity question separately. *(Amended 2026-09-25: the owner took the sync after the truncate (KV-T-0035, done), so the sizing can no longer be lost under a kept meta write. What remains is a meta write torn with neither whole, possible only if a write inside one 512-byte sector can tear: **KV-T-0038**, the sector-atomicity question, still an open decision for the owner.)*
- **The simulation assumes the sync contract** (a sync that returned made everything before it durable) and tests none of the physical durability of `F_FULLFSYNC` or `fdatasync`. Directory entries (a new file's name) are not modelled.
- **Fault injection fails an operation whole**: a partial meta write followed by a poisoned env isn't simulated (KV-T-0028's torn images cover what the file then holds). After a failed `fsync` the kernel may drop pages; no image models that, and poisoning is the answer to it.
- **The real-kill test is a smoke test**, not an ordering detector: it can't see a missing or misplaced sync, and a kill almost never lands in a window of a few `pwrite`s.
- **Only the newest meta page's loss is recovered**; data pages carry no checksum (a non-goal).
- **The journal is per thread**: it sees a store's I/O because every write happens on the thread holding the write transaction. A future background writer would escape it.
- **Coverage gaps filed as tech debt:** the reuse-horizon bug is caught by one workload only (KV-T-0034); an overflow size boundary is caught reliably only by the fuzz mode, not the default suite (KV-T-0036); fuzz seeds with 100 keys never spill and no seed passes depth 4 (KV-T-0037).
- **No CI workflow yet**: the owner adds it (D9); the invocation above is what it needs.

### Backlog filed

- KV-T-0034 (tech debt): let the spill crash sweep reach the reuse-horizon bug.
- KV-T-0035 (bug, **owner decision**): a power loss during creation can leave a file that never opens. *(Done 2026-09-25, option 1; its remainder filed as KV-T-0038.)*
- KV-T-0038 (bug, **owner decision**, filed 2026-09-25 from KV-T-0035): can a sector write tear? A torn meta write during creation leaves a file that never opens.
- KV-T-0036 (tech debt): a directed test for overflow value size boundaries.
- KV-T-0037 (tech debt): make fuzz seeds reach spills and depth 5.
