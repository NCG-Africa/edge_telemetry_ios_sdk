#!/usr/bin/env bash
#
# Tools/build-xcframework.sh
#
# Builds the EdgeRum XCFramework across three slices —
#   - iphoneos        (arm64)
#   - iphonesimulator (arm64 + x86_64)
#   - maccatalyst     (arm64 + x86_64)
# — then packages them with `xcodebuild -create-xcframework`, signs with
# the identity in $CODESIGN_IDENTITY (no-op + warning when empty for
# local runs), and zips to build/EdgeRum.xcframework.zip.
#
# Refs: PLAN-iOS.md §2.5, F1/T1.2 (issue #3).
#
# Pre-reqs:
#   - Xcode 16+
#   - Tools/fetch-plcrashreporter.sh has been run (auto-invoked here).
#
# Environment overrides:
#   SCHEME             = EdgeRum             (default)
#   ARCHIVE_DIR        = build/archives
#   OUTPUT_DIR         = build
#   OUTPUT_FRAMEWORK   = build/EdgeRum.xcframework
#   OUTPUT_ZIP         = build/EdgeRum.xcframework.zip
#   CODESIGN_IDENTITY  = ""                  (skip signing when empty)
#   SKIP_CATALYST      = ""                  ("1" skips the maccatalyst slice)
#   SIZE_BUDGET_BYTES  = 1677721600          (~16 MB soft cap; real F20 budget)

set -euo pipefail

SCHEME="${SCHEME:-EdgeRum}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_DIR="${ARCHIVE_DIR:-${REPO_ROOT}/build/archives}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/build}"
OUTPUT_FRAMEWORK="${OUTPUT_FRAMEWORK:-${OUTPUT_DIR}/EdgeRum.xcframework}"
OUTPUT_ZIP="${OUTPUT_ZIP:-${OUTPUT_DIR}/EdgeRum.xcframework.zip}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
SKIP_CATALYST="${SKIP_CATALYST:-}"
SIZE_BUDGET_BYTES="${SIZE_BUDGET_BYTES:-1677721600}"

cd "${REPO_ROOT}"

# Ensure PLCrashReporter is on disk; the binary target won't resolve
# without it.
"${REPO_ROOT}/Tools/fetch-plcrashreporter.sh"

rm -rf "${ARCHIVE_DIR}" "${OUTPUT_FRAMEWORK}" "${OUTPUT_ZIP}"
mkdir -p "${ARCHIVE_DIR}" "${OUTPUT_DIR}"

# Build the slice list: (label,destination) pairs.
slices=(
    "iphoneos|generic/platform=iOS"
    "iphonesimulator|generic/platform=iOS Simulator"
)
if [[ -z "${SKIP_CATALYST}" ]]; then
    slices+=("maccatalyst|generic/platform=macOS,variant=Mac Catalyst")
fi

archive_slice() {
    local label="$1" destination="$2" archive="$3"

    echo "" >&2
    echo "==> archiving ${label}" >&2
    xcodebuild archive \
        -scheme "${SCHEME}" \
        -destination "${destination}" \
        -archivePath "${archive}" \
        -derivedDataPath "${ARCHIVE_DIR}/dd-${label}" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARIES_FOR_DISTRIBUTION=YES \
        ONLY_ACTIVE_ARCH=NO \
        >&2
}

framework_in_archive() {
    local archive="$1"
    # SwiftPM dynamic library product → Products/usr/local/lib/<SCHEME>.framework.
    local candidate="${archive}/Products/usr/local/lib/${SCHEME}.framework"
    if [[ -d "${candidate}" ]]; then
        echo "${candidate}"
        return 0
    fi
    # Fallback: scan the archive in case Xcode chose a different install path.
    local hit
    hit="$(find "${archive}/Products" -type d -name "${SCHEME}.framework" -print -quit 2>/dev/null)"
    if [[ -n "${hit}" ]]; then
        echo "${hit}"
        return 0
    fi
    return 1
}

# Stage 1: archive each slice in turn.
declare -a archives=()
for entry in "${slices[@]}"; do
    label="${entry%%|*}"
    destination="${entry#*|}"
    archive="${ARCHIVE_DIR}/EdgeRum-${label}.xcarchive"
    archive_slice "${label}" "${destination}" "${archive}"
    archives+=("${archive}")
done

# Stage 2: collect framework paths + inject PrivacyInfo into each slice.
#
# SwiftPM puts .copy() resources into a side bundle (EdgeRum_EdgeRum.bundle)
# that xcodebuild's archive flow does not propagate into the framework
# product. App Store Connect requires PrivacyInfo.xcprivacy at the
# framework root (iOS / Catalyst-versioned location), so we copy the
# source manifest in by hand before create-xcframework.
PRIVACY_SRC="${REPO_ROOT}/Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy"
if [[ ! -f "${PRIVACY_SRC}" ]]; then
    echo "build-xcframework: missing ${PRIVACY_SRC}" >&2
    exit 1
fi

declare -a create_xcframework_args=()
for archive in "${archives[@]}"; do
    fw="$(framework_in_archive "${archive}")" || {
        echo "build-xcframework: could not find ${SCHEME}.framework inside ${archive}" >&2
        exit 1
    }
    if [[ -d "${fw}/Versions/A/Resources" ]]; then
        # Versioned (Mac Catalyst) bundle.
        cp "${PRIVACY_SRC}" "${fw}/Versions/A/Resources/PrivacyInfo.xcprivacy"
    else
        # Flat (iOS / iOS Simulator) bundle.
        cp "${PRIVACY_SRC}" "${fw}/PrivacyInfo.xcprivacy"
    fi
    create_xcframework_args+=("-framework" "${fw}")
done

# Stage 3: combine.
echo ""
echo "==> create-xcframework"
xcodebuild -create-xcframework \
    "${create_xcframework_args[@]}" \
    -output "${OUTPUT_FRAMEWORK}"

# Stage 4: optional codesign.
if [[ -n "${CODESIGN_IDENTITY}" ]]; then
    echo ""
    echo "==> codesign (--options=runtime, identity: ${CODESIGN_IDENTITY})"
    codesign --force --sign "${CODESIGN_IDENTITY}" \
        --options=runtime --timestamp \
        "${OUTPUT_FRAMEWORK}"
else
    echo ""
    echo "build-xcframework: \$CODESIGN_IDENTITY is empty; produced an UNSIGNED xcframework."
    echo "  Set CODESIGN_IDENTITY=\"Developer ID Application: ...\" for a signed build."
fi

# Stage 5: zip + size report.
echo ""
echo "==> zipping"
(cd "${OUTPUT_DIR}" && ditto -c -k --keepParent \
    "$(basename "${OUTPUT_FRAMEWORK}")" \
    "$(basename "${OUTPUT_ZIP}")")

size_bytes="$(stat -f%z "${OUTPUT_ZIP}")"
size_human="$(du -h "${OUTPUT_ZIP}" | cut -f1)"
echo ""
echo "==> done"
echo "  xcframework: ${OUTPUT_FRAMEWORK}"
echo "  zip:         ${OUTPUT_ZIP} (${size_human}, ${size_bytes} bytes)"

if (( size_bytes > SIZE_BUDGET_BYTES )); then
    echo "build-xcframework: WARNING: zip exceeds soft budget of ${SIZE_BUDGET_BYTES} bytes." >&2
fi
