#!/usr/bin/env bash
# Runs the test suite (debug and optimised builds, then both again with the
# I/O hook and no syncs, KV-I-0005 D1, D3, D9) in a Linux container.
# Needs Docker; on macOS that's OrbStack: run `orb start` first and
# `orb stop` afterwards. amd64 runs under emulation on Apple Silicon.
#
# Usage: scripts/test-linux.sh [arm64|amd64] [extra odin test args...]
# e.g. scripts/test-linux.sh arm64 -define:ODIN_TEST_NAMES=kv_tests.test_cursor_seek
set -euo pipefail
cd "$(dirname "$0")/.."

arch="${1:-arm64}"
shift || true
image="odin-rdf-kv-test:${arch}"
docker build -q --platform "linux/${arch}" --build-arg ODIN_ARCH="${arch}" \
	-t "${image}" -f scripts/linux.Dockerfile scripts >/dev/null

for flags in -debug -o:speed; do
	echo "== linux/${arch} odin test tests ${flags} $*"
	docker run --rm --platform "linux/${arch}" -v "$PWD":/src:ro "${image}" \
		odin test tests -vet -strict-style "${flags}" -out:/tmp/kv_tests "$@"
done
# The hooked build in both modes: -o:speed with the hook and no syncs is the
# CI invocation (KV-I-0005 D9), and native Linux is where CI's ubuntu runner
# differs most from a Mac (KV-T-0033: a reader test's timing failed only here).
for flags in -debug -o:speed; do
	echo "== linux/${arch} odin test tests ${flags} -define:KV_IO_HOOK=true -define:KV_NO_SYNC=true $*"
	docker run --rm --platform "linux/${arch}" -v "$PWD":/src:ro "${image}" \
		odin test tests -vet -strict-style "${flags}" -define:KV_IO_HOOK=true -define:KV_NO_SYNC=true -out:/tmp/kv_tests "$@"
done
echo "== linux/${arch} passed"
