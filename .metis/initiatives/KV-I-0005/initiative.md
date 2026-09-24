---
id: crash-tests-and-fuzzing
level: initiative
title: "Crash tests and fuzzing"
short_code: "KV-I-0005"
created_at: 2026-09-24T22:50:49.319079+00:00
updated_at: 2026-09-24T22:50:49.319079+00:00
parent: KV-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/discovery"


exit_criteria_met: false
estimated_complexity: M
initiative_id: crash-tests-and-fuzzing
---

# Crash tests and fuzzing Initiative

## Context

**Handoff (written 2026-09-25 at the end of the KV-I-0004 session).** This is a draft in discovery. Nothing is decided, no tasks exist, and no code has been written for it. The next session should read this, the vision (KV-V-0001) and `CLAUDE.md`, then settle the open questions below with the owner before moving the initiative to design.

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

**Goals (proposed, to be confirmed):**
- A crash harness that stops the store at every I/O cut point of `txn_commit`, and of a transaction that spilled, wrote overflow runs or streamed the free list before committing, then reopens and checks the database is exactly the last committed state (model comparison, `tree_check`, `space_check`), and that the next commit works.
- The same after a crash during `env_open` of a new file (between `truncate` and the two meta-page writes).
- A fuzzing mode over the existing model: long runs by seed, reproducible from the seed in the failure message, on demand like the steady tests.

**Non-Goals (proposed):**
- Multi-process access (out of scope in the vision).
- Recovering from corruption other than a torn commit (bad sectors, bit flips in data pages): a checksum on data pages isn't in the format.

## Open questions for the owner

1. **How to cut:** (a) an injectable I/O seam (a `File_Ops`-style table, or a test-only failpoint hook inside `os_pwrite`/`os_sync`/`os_truncate`) that can stop after operation *n*; or (b) real process kills: fork a child that commits and `SIGKILL` it at a random time, or at a failpoint. (a) is deterministic and sweeps every cut point; (b) is closer to the vision's words and catches things a seam can't (for example the mmap's behaviour). A combination is likely: a sweep through a seam, plus a smaller real-kill test.
2. **Power-loss simulation:** should the harness also model lost, torn and reordered unsynced writes (a simulated file that keeps the synced state and applies an arbitrary subset of unsynced page writes on "power loss")? That tests the meta-page checksum and the two syncs, and it's where a real bug would most likely hide. It needs the seam from question 1(a).
3. **Fuzzing depth:** seed-driven long runs of the existing model (cheap), or a coverage-guided fuzzer (Odin has no built-in one; it would mean a libFuzzer-style harness via the C ABI). Proposal to discuss: seeds only.
4. **CPU use:** the owner avoids long, all-core test runs (the steady-state tests hit 100–500%, and a suite run briefly pinned about 10 cores). The crash sweep and fuzzing should be on demand behind a define, with a short default, and able to run with `-define:ODIN_TEST_THREADS=2`.

## Known points to check (found during KV-I-0004)
- `env_open` of a **new** file writes both meta pages then syncs once; a crash between the truncate and the sync leaves a file of the right size with zero or one valid meta page. What should the next open do: recreate, or return `Corrupted`? Today `meta_choose` returns not-found → `Corrupted` for a zero-filled file.
- `file_grow` truncates the file larger before the writes; a crash after it leaves a longer file with unreferenced zero pages. That should be harmless (the meta page's `last_pgno` bounds everything); the harness should confirm it.
- If only the final sync of a commit fails, the doc comment says the next open sees whichever state is durable, while the process keeps the previous one. The harness should cover that case explicitly.
- Linux production, macOS development: `F_FULLFSYNC` on macOS, `fdatasync` on Linux. A kill test behaves the same on both; a power-loss simulation is platform-independent by construction.

## Detailed Design

*Not started. To be written after the open questions are settled.*

## Implementation Plan

*Not started. Tasks are created at decompose time, one commit per task, as in KV-I-0001 to KV-I-0004.*