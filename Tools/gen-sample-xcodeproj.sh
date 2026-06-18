#!/usr/bin/env bash
#
# Tools/gen-sample-xcodeproj.sh
#
# Generate the XcodeGen-managed sample .xcodeproj files (UIKit and
# Crash) from their project.yml. The SwiftUI sample is the only one
# that still ships a checked-in .xcodeproj — both generated samples
# keep the diff a future engineer reads as project.yml, not 1k+ lines
# of pbxproj.
#
# Refs: PLAN-iOS.md §12.3 (sample apps); Samples/*/project.yml.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

fail() {
    echo "gen-sample-xcodeproj: $1" >&2
    exit 1
}

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

regenerate() {
    local sample="$1"
    local sample_dir="${REPO_ROOT}/Samples/${sample}"
    local spec="${sample_dir}/project.yml"
    [[ -f "${spec}" ]] || fail "missing project.yml at ${spec}"
    (cd "${sample_dir}" && xcodegen generate --spec "${spec}" --project "${sample_dir}")
    echo "gen-sample-xcodeproj: regenerated ${sample_dir}/${sample}.xcodeproj"
}

regenerate EdgeRumSampleApp
regenerate EdgeRumCrashSampleApp
