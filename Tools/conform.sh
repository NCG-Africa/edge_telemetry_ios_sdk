#!/usr/bin/env bash
# Conformance gate (#269, spec 2026-11-23 stable goldens): check the raw batches CatalogueGoldenTests
# dumps to Tests/golden-raw against the event catalogue at the tag pinned in catalogue.version, and
# their derived shape against Tests/shape.txt. Pass -update to rewrite the shape file. Run the golden
# test first (see Tests/EdgeRumCrashTests/CatalogueGoldenTests.swift). Needs go and git.
# PROCESSOR_DIR reuses a local checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag="$(cat "$root/catalogue.version")"
src="${PROCESSOR_DIR:-}"
if [ -z "$src" ]; then
  src="$(mktemp -d)"
  trap 'rm -rf "$src"' EXIT
  git clone -q --depth 1 --branch "$tag" https://github.com/NCG-Africa/edge_telemetry_processor_go.git "$src"
fi
cd "$src" && go run ./cmd/conform "$@" "$root/Tests/golden-raw" "$root/Tests/shape.txt"
