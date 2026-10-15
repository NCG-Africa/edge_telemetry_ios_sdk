#!/usr/bin/env bash
#
# Tools/verify-privacy-manifest.sh
#
# Greps Sources/ for Apple's required-reason APIs, maps each hit to its
# NSPrivacyAccessedAPICategory, and diffs that set against
# NSPrivacyAccessedAPITypes in PrivacyInfo.xcprivacy. Fails on an API
# used but not declared, and on a category declared but no longer used.
# Comment-only lines are ignored. Reason codes are not checked —
# PrivacyManifestTests pins those.
#
# Refs: #255 (SDK-008), #254, PLAN-iOS.md § F20, ADR-030.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

MANIFEST="Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy"
[[ -f "${MANIFEST}" ]] || { echo "verify-privacy-manifest: missing ${MANIFEST}" >&2; exit 1; }

# category|pattern (grep -E). ponytail: name-based grep, misses an API
# reached only through a wrapper in a binary dependency.
RULES=(
    "UserDefaults|\\b(NS)?UserDefaults\\b"
    "SystemBootTime|\\bmach_absolute_time\\b|\\bsystemUptime\\b|kern\\.boottime|KERN_BOOTTIME"
    "DiskSpace|\\bstatv?fs\\b|\\bsystem(Free)?Size\\b|volume(Available|Total)Capacity|NSFileSystem(Free)?Size|volumeAvailableCapacityFor"
    "FileTimestamp|\\b(f|l)?stat(at)?\\(|\\bf?getattrlist(at|bulk)?\\b|\\bsetattrlist(bulk)?\\b|\\b(creation|modification|contentModification|fileModification)Date\\b|NSFile(Creation|Modification)Date"
    "ActiveKeyboards|\\bactiveInputModes\\b"
)

used=()
for rule in "${RULES[@]}"; do
    category="${rule%%|*}"
    pattern="${rule#*|}"
    hits="$(grep -rnE --include='*.swift' --include='*.m' --include='*.c' --include='*.h' "${pattern}" Sources \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' || true)"
    if [[ -n "${hits}" ]]; then
        used+=("NSPrivacyAccessedAPICategory${category}")
        echo "${category}: $(wc -l <<<"${hits}" | tr -d ' ') call site(s), e.g. $(head -n1 <<<"${hits}" | cut -d: -f1,2)"
    fi
done

declared="$(grep -oE 'NSPrivacyAccessedAPICategory[A-Za-z]+' "${MANIFEST}" | sort -u)"
used_sorted="$(printf '%s\n' "${used[@]+"${used[@]}"}" | sed '/^$/d' | sort -u)"

missing="$(comm -23 <(echo "${used_sorted}") <(echo "${declared}") | sed '/^$/d')"
stale="$(comm -13 <(echo "${used_sorted}") <(echo "${declared}") | sed '/^$/d')"

status=0
if [[ -n "${missing}" ]]; then
    echo "verify-privacy-manifest: used in Sources/ but not declared in ${MANIFEST}:" >&2
    sed 's/^/  - /' <<<"${missing}" >&2
    status=1
fi
if [[ -n "${stale}" ]]; then
    echo "verify-privacy-manifest: declared in ${MANIFEST} but no call site found:" >&2
    sed 's/^/  - /' <<<"${stale}" >&2
    status=1
fi
[[ ${status} -eq 0 ]] && echo "verify-privacy-manifest: OK"
exit ${status}
