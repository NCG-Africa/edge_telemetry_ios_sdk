#!/usr/bin/env bash
#
# Tools/gen-sample-xcodeproj.sh
#
# Generate Samples/EdgeRumSampleApp/EdgeRumSampleApp.xcodeproj from
# its project.yml via XcodeGen. The other two samples (SwiftUI, Crash)
# ship hand-crafted .xcodeproj files; this one is generated so the diff
# a future iOS engineer needs to read is project.yml, not pbxproj.
#
# Refs: PLAN-iOS.md §12.3 (sample apps); Samples/EdgeRumSampleApp/project.yml.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SAMPLE_DIR="${REPO_ROOT}/Samples/EdgeRumSampleApp"
SPEC="${SAMPLE_DIR}/project.yml"

fail() {
    echo "gen-sample-xcodeproj: $1" >&2
    exit 1
}

[[ -f "${SPEC}" ]] || fail "missing project.yml at ${SPEC}"

if ! command -v xcodegen >/dev/null 2>&1; then
    cat >&2 <<'MSG'
gen-sample-xcodeproj: xcodegen not on PATH.

Install with:

    brew install xcodegen

…then re-run this script. CI installs xcodegen via the brew step in
the `sample-build` job before invoking us.
MSG
    exit 1
fi

cd "${SAMPLE_DIR}"
xcodegen generate --spec "${SPEC}" --project "${SAMPLE_DIR}"

echo "gen-sample-xcodeproj: regenerated ${SAMPLE_DIR}/EdgeRumSampleApp.xcodeproj"
