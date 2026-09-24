#!/usr/bin/env bash
# Runs the test suite (debug and optimised builds) in a Linux container.
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
echo "== linux/${arch} passed"
