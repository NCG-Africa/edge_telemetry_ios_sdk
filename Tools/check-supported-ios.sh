#!/usr/bin/env bash
#
# Tools/check-supported-ios.sh
#
# Cross-checks the iOS deployment floor across every source of truth so
# the SDK cannot ship with a drifted "Supported iOS" promise:
#
#   1. Package.swift    — `.iOS(.vNN)` in the platforms array.
#   2. EdgeRum.podspec  — `s.ios.deployment_target = 'NN.0'`.
#   3. PLAN-iOS.md §2.2 — "**Minimum**: **iOS NN.0**" line.
#   4. README.md        — "Supported iOS" table (when README exists).
#
# Any mismatch exits non-zero with a diff. Run locally before committing;
# CI runs this on every PR.
#
# Refs: PLAN-iOS.md §2.2, F1/T1.5 (issue #6), §12.5 Doc-quality CI.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

PACKAGE_SWIFT="${REPO_ROOT}/Package.swift"
PODSPEC="${REPO_ROOT}/EdgeRum.podspec"
PLAN="${REPO_ROOT}/PLAN-iOS.md"
README="${REPO_ROOT}/README.md"

fail() {
    echo "check-supported-ios: $1" >&2
    exit 1
}

[[ -f "${PACKAGE_SWIFT}" ]] || fail "missing Package.swift at ${PACKAGE_SWIFT}"
[[ -f "${PLAN}" ]]          || fail "missing PLAN-iOS.md at ${PLAN}"

# 1. Package.swift — extract the major version from `.iOS(.vNN)`.
pkg_version="$(grep -Eo '\.iOS\(\.v[0-9]+\)' "${PACKAGE_SWIFT}" \
    | head -n1 \
    | grep -Eo '[0-9]+')"
if [[ -z "${pkg_version}" ]]; then
    fail "Package.swift has no .iOS(.vNN) platform declaration"
fi

# 2. PLAN-iOS.md §2.2 — extract from `**Minimum**: **iOS NN.0**`.
plan_version="$(grep -Eo '\*\*Minimum\*\*:[[:space:]]*\*\*iOS[[:space:]]+[0-9]+(\.[0-9]+)?\*\*' "${PLAN}" \
    | head -n1 \
    | grep -Eo '[0-9]+' \
    | head -n1)"
if [[ -z "${plan_version}" ]]; then
    fail "PLAN-iOS.md §2.2 is missing the '**Minimum**: **iOS NN.0**' line"
fi

# 3. EdgeRum.podspec — optional during F1, required from T1.4 onward.
pod_version=""
if [[ -f "${PODSPEC}" ]]; then
    pod_version="$(grep -Eo "deployment_target[[:space:]]*=[[:space:]]*'[0-9]+(\.[0-9]+)?'" "${PODSPEC}" \
        | head -n1 \
        | grep -Eo "[0-9]+" \
        | head -n1)"
    if [[ -z "${pod_version}" ]]; then
        fail "EdgeRum.podspec is present but has no 's.ios.deployment_target' line"
    fi
fi

# 4. README.md — optional until F18 ships the README.
readme_version=""
if [[ -f "${README}" ]]; then
    # Look for a row like `| iOS NN.0+ |` or `Minimum iOS: NN`.
    readme_version="$(grep -Eo '(iOS[[:space:]]+|Minimum iOS:[[:space:]]*)[0-9]+(\.[0-9]+)?\+?' "${README}" \
        | head -n1 \
        | grep -Eo '[0-9]+' \
        | head -n1 || true)"
    if [[ -z "${readme_version}" ]]; then
        echo "check-supported-ios: warning: README.md exists but no 'iOS NN' floor line was found." >&2
    fi
fi

# Compare every source we found against Package.swift.
mismatch=0
report() {
    local source="$1" value="$2"
    if [[ -n "${value}" ]] && [[ "${value}" != "${pkg_version}" ]]; then
        echo "check-supported-ios: ${source} floor is iOS ${value}, expected iOS ${pkg_version}" >&2
        mismatch=1
    fi
}

report "PLAN-iOS.md §2.2" "${plan_version}"
report "EdgeRum.podspec"  "${pod_version}"
report "README.md"        "${readme_version}"

if (( mismatch != 0 )); then
    echo "check-supported-ios: iOS floor mismatch — fix the drifted source(s)." >&2
    exit 1
fi

echo "check-supported-ios: iOS ${pkg_version} floor consistent across:"
echo "    Package.swift"
echo "    PLAN-iOS.md §2.2"
[[ -n "${pod_version}" ]]    && echo "    EdgeRum.podspec"
[[ -n "${readme_version}" ]] && echo "    README.md"
exit 0
