#!/usr/bin/env bash
#
# Tools/fetch-plcrashreporter.sh
#
# Downloads the pinned PLCrashReporter Static XCFramework release from
# https://github.com/microsoft/plcrashreporter/releases, verifies its
# SHA-256, and extracts CrashReporter.xcframework into Frameworks/.
#
# Idempotent: a matching extracted xcframework short-circuits the download.
#
# Refs: PLAN-iOS.md §2.3 (binary target), §6.7 (native crash), F14.

set -euo pipefail

PLCR_VERSION="1.12.0"
PLCR_ZIP="PLCrashReporter-Static-${PLCR_VERSION}.xcframework.zip"
PLCR_URL="https://github.com/microsoft/plcrashreporter/releases/download/${PLCR_VERSION}/${PLCR_ZIP}"
PLCR_SHA256="9e7124d63316a5e354fdeec631a3d669b1eaa533d3767a0089a05ab0eedc02b5"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_DIR="${REPO_ROOT}/Frameworks"
FRAMEWORK="${FRAMEWORK_DIR}/CrashReporter.xcframework"
STAMP_FILE="${FRAMEWORK_DIR}/.crashreporter.version"

mkdir -p "${FRAMEWORK_DIR}"

if [[ -d "${FRAMEWORK}" && -f "${STAMP_FILE}" ]]; then
    existing="$(cat "${STAMP_FILE}")"
    if [[ "${existing}" == "${PLCR_VERSION}:${PLCR_SHA256}" ]]; then
        echo "fetch-plcrashreporter: CrashReporter.xcframework already at ${PLCR_VERSION}; skipping."
        exit 0
    fi
    echo "fetch-plcrashreporter: version stamp mismatch (have '${existing}', want '${PLCR_VERSION}'); refetching."
    rm -rf "${FRAMEWORK}"
fi

tmp_dir="$(mktemp -d -t edgerum-plcr.XXXXXX)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "fetch-plcrashreporter: downloading ${PLCR_ZIP}"
curl --fail --silent --show-error --location \
    -o "${tmp_dir}/${PLCR_ZIP}" "${PLCR_URL}"

actual_sha="$(shasum -a 256 "${tmp_dir}/${PLCR_ZIP}" | awk '{print $1}')"
if [[ "${actual_sha}" != "${PLCR_SHA256}" ]]; then
    echo "fetch-plcrashreporter: SHA-256 mismatch" >&2
    echo "    expected: ${PLCR_SHA256}" >&2
    echo "    actual:   ${actual_sha}" >&2
    exit 1
fi

echo "fetch-plcrashreporter: extracting"
unzip -q "${tmp_dir}/${PLCR_ZIP}" -d "${tmp_dir}/unpacked"

# Upstream zip nests the xcframework one directory deep:
#   PLCrashReporter/CrashReporter.xcframework/
src="${tmp_dir}/unpacked/PLCrashReporter/CrashReporter.xcframework"
if [[ ! -d "${src}" ]]; then
    echo "fetch-plcrashreporter: expected ${src} inside release zip" >&2
    exit 1
fi

rm -rf "${FRAMEWORK}"
cp -R "${src}" "${FRAMEWORK}"
echo "${PLCR_VERSION}:${PLCR_SHA256}" > "${STAMP_FILE}"

echo "fetch-plcrashreporter: installed ${FRAMEWORK} (PLCrashReporter ${PLCR_VERSION})"
