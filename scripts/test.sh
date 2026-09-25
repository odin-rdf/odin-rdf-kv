#!/usr/bin/env bash
# Runs the test suite in every configuration a task is verified with:
# debug, optimised and AddressSanitizer builds with real syncs, a debug build
# with the I/O hook and no syncs (KV-I-0005 D1, D3: the journal and crash
# tests), plus type checks for the other supported targets. Extra arguments
# are passed to every `odin test`,
# e.g. -define:ODIN_TEST_NAMES=kv_tests.test_cursor_seek
# or  -define:ODIN_TEST_RANDOM_SEED=1234
#
# --steady (first argument) also runs the steady-state tests, which make
# thousands of synced commits: several minutes per configuration on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--steady" ]]; then
	shift
	set -- -define:KV_STEADY=true "$@"
fi

out="${TMPDIR:-/tmp}/kv_tests"
run() {
	echo "== odin test tests $*"
	odin test tests -vet -strict-style -out:"$out" "$@"
}

run -debug "$@"
run -o:speed "$@"
run -debug -sanitize:address "$@"
run -debug -define:KV_IO_HOOK=true -define:KV_NO_SYNC=true "$@"

for target in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
	echo "== odin check -target:$target"
	odin check kv -no-entry-point -vet -strict-style -target:"$target"
	odin check tests -no-entry-point -vet -strict-style -target:"$target"
	odin check tests -no-entry-point -vet -strict-style -target:"$target" -define:KV_IO_HOOK=true -define:KV_NO_SYNC=true
done
echo "== all configurations passed"
