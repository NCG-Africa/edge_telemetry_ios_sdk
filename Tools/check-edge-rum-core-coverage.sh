#!/usr/bin/env bash
#
# Tools/check-edge-rum-core-coverage.sh
#
# F19 / T19.1 — Gate on the §13.1 acceptance bar: ≥ 80% line coverage
# on `EdgeRumCore`.
#
# Runs `swift test --enable-code-coverage` (unless invoked with
# `--reuse-build`), parses `xcrun llvm-cov report` for the TOTAL line
# percentage across `Sources/EdgeRumCore/`, and exits non-zero if the
# number falls below the threshold (default 80; override via
# `EDGE_RUM_CORE_COVERAGE_MIN`).
#
# Some platform-specific paths in `EdgeRumCore` (real KeychainStore,
# BackgroundUploader's URLSession lifecycle) are only reachable from
# iOS hosts. The xcodebuild matrix in CI (test-device-matrix) gives
# them their coverage when it runs against iOS Simulator slices; this
# script focuses on the SwiftPM run because `swift test` is faster
# and runs on every PR. The threshold can be tuned independently per
# environment via the env var if a tighter bound is required on
# specific runners.
#
# Refs: PLAN-iOS.md §13.1, CLAUDE.md "CI checks".

set -euo pipefail

REUSE_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --reuse-build) REUSE_BUILD=true ;;
        -h|--help)
            cat <<'EOF'
Usage: check-edge-rum-core-coverage.sh [--reuse-build]

Env vars:
  EDGE_RUM_CORE_COVERAGE_MIN   Minimum line % to require (default 80).
EOF
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

THRESHOLD="${EDGE_RUM_CORE_COVERAGE_MIN:-80}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ "$REUSE_BUILD" != true ]]; then
    echo "check-edge-rum-core-coverage: running 'swift test --enable-code-coverage'"
    swift test --enable-code-coverage >/dev/null
fi

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="${BIN_PATH}/codecov/default.profdata"
TEST_BUNDLE="${BIN_PATH}/EdgeRumPackageTests.xctest/Contents/MacOS/EdgeRumPackageTests"

if [[ ! -f "$PROFDATA" ]]; then
    echo "check-edge-rum-core-coverage: missing $PROFDATA" >&2
    echo "  did 'swift test --enable-code-coverage' run yet?" >&2
    exit 3
fi
if [[ ! -f "$TEST_BUNDLE" ]]; then
    echo "check-edge-rum-core-coverage: missing $TEST_BUNDLE" >&2
    echo "  the test binary should sit alongside the .profdata file." >&2
    exit 3
fi

REPORT="$(xcrun llvm-cov report \
    "$TEST_BUNDLE" \
    -instr-profile="$PROFDATA" \
    Sources/EdgeRumCore 2>&1)"

echo "$REPORT"

# llvm-cov's TOTAL row looks like:
#   TOTAL  761  170  77.66%  366  58  84.15%  2438  506  79.25%  0  0  -
# Tokenised columns (1-indexed):
#   1=TOTAL  2=regions  3=miss  4=region%  5=funcs  6=miss  7=func%
#   8=lines  9=miss     10=line%  11=branches 12=miss 13=branch%
# We want the 10th column (line cov%) on the TOTAL row.
TOTAL_LINE=$(printf '%s\n' "$REPORT" | grep -E '^TOTAL' | tail -1)
if [[ -z "$TOTAL_LINE" ]]; then
    echo "check-edge-rum-core-coverage: could not find TOTAL row in report" >&2
    exit 4
fi

LINE_PCT=$(awk '{ print $10 }' <<<"$TOTAL_LINE" | tr -d '%')
# Guard against malformed input — the percentage must be numeric and
# carry the trailing % (now stripped).
if [[ -z "$LINE_PCT" || ! "$LINE_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "check-edge-rum-core-coverage: could not parse line % from '$TOTAL_LINE'" >&2
    echo "  got token: '$LINE_PCT'" >&2
    exit 4
fi

# Compare floats via awk so we don't depend on bc.
PASS=$(awk -v actual="$LINE_PCT" -v wanted="$THRESHOLD" 'BEGIN { print (actual + 0 >= wanted + 0) ? "yes" : "no" }')
if [[ "$PASS" == "yes" ]]; then
    printf "\ncheck-edge-rum-core-coverage: line coverage %s%% ≥ %s%% threshold\n" "$LINE_PCT" "$THRESHOLD"
    exit 0
fi

cat <<EOF >&2

check-edge-rum-core-coverage: FAIL — line coverage ${LINE_PCT}% is below the ${THRESHOLD}% threshold.

Acceptance bar lives in PLAN-iOS.md §13.1 (T19.1):
    ≥ 80% line coverage on EdgeRumCore.

Closest gaps in the report above:
  - Files with the lowest line %.
  - Path-conditional code (#if os(iOS), background URLSession) may
    show as 0% on the macOS swift-test host; the test-device-matrix
    CI job exercises those paths under iOS Simulator.

Lower the threshold temporarily via EDGE_RUM_CORE_COVERAGE_MIN=<n>
if a known-good drop is acceptable for the current PR.
EOF
exit 5
