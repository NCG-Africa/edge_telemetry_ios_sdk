#!/usr/bin/env bash
#
# Tools/extract-readme-code.sh
#
# Pulls every fenced ```swift block out of README.md and the DocC
# catalog under Sources/EdgeRum/EdgeRum.docc/**/*.md, wraps each
# block in a minimal compilable Swift file, and parses the lot through
# `swiftc -parse` against the package's build products. A broken doc
# block is a CI failure.
#
# Blocks fenced with ```swift-skip (illustrative pseudo-code,
# Package.swift fragments, .target() declarations the consumer pastes
# into THEIR Package.swift) are extracted but NOT parsed — the swift-
# skip marker is the opt-out the doc author flips when the block isn't
# valid stand-alone Swift.
#
# Refs: PLAN-iOS.md §12.5 (Doc-quality CI), CLAUDE.md "Rule 2 — JSON
#       only, always" (the JSON examples are not parsed either).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

BUILD_DIR="${REPO_ROOT}/build/doc-snippets"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
if [[ -z "${SDK}" || ! -d "${SDK}" ]]; then
    SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
if [[ -z "${SDK}" || ! -d "${SDK}" ]]; then
    echo "extract-readme-code: cannot resolve an SDK path via xcrun" >&2
    exit 1
fi

# Banned terms — kept in sync with Tools/firewall-check.sh. A doc block
# that uses any of these would slip past the firewall (which only scans
# README/docs/EdgeRum.docc text and the public symbol graph) IF the
# block were also valid Swift; this catches both cases at once.
BANNED_TOKENS=(
    opentelemetry
    otel
    otlp
    "span"
    "tracer"
    "trace"
    "instrumentation"
    "telemetry"
)

mkdir -p "${BUILD_DIR}"
# Wipe and recreate so a previous run's stale snippets don't poison
# the parse pass.
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

fail_count=0
report() {
    echo "extract-readme-code: $*" >&2
    fail_count=$((fail_count + 1))
}

# Build the package once so swiftc -parse has the modules in
# .build/<triple>/debug/. If the build fails, the test fails — there's
# no point parsing docs against a broken SDK.
if [[ -z "${SKIP_BUILD:-}" ]]; then
    if ! swift build --product EdgeRum 1>/dev/null; then
        echo "extract-readme-code: swift build failed — cannot parse doc snippets" >&2
        exit 1
    fi
fi

MODULE_DIR="$(find "${REPO_ROOT}/.build" -type d -name debug 2>/dev/null | head -n1)"
if [[ -z "${MODULE_DIR}" || ! -d "${MODULE_DIR}" ]]; then
    echo "extract-readme-code: cannot find .build/<triple>/debug/ — has the package been built?" >&2
    exit 1
fi

# Discover the markdown corpus. README.md plus everything under the
# DocC catalog. Sort for stable output ordering.
DOC_FILES=()
[[ -f "${REPO_ROOT}/README.md" ]] && DOC_FILES+=("${REPO_ROOT}/README.md")
while IFS= read -r f; do
    DOC_FILES+=("${f}")
done < <(find "${REPO_ROOT}/Sources/EdgeRum/EdgeRum.docc" -type f -name '*.md' 2>/dev/null | sort)

# Awk script that walks one markdown file and extracts blocks fenced
# with ```swift (NOT ```swift-skip) into separate files under BUILD_DIR.
# `BLOCK_PREFIX` is the per-file basename used for the snippet files.
extract_swift_blocks() {
    local src="$1"
    local prefix="$2"
    awk -v out="${BUILD_DIR}" -v prefix="${prefix}" '
        BEGIN { in_block = 0; n = 0; }
        # Opening fence — only ```swift counts. ```swift-skip and
        # everything else is skipped.
        /^```swift$/ {
            in_block = 1;
            n += 1;
            fname = sprintf("%s/%s_%03d.swift", out, prefix, n);
            next;
        }
        /^```/ {
            if (in_block) {
                in_block = 0;
                close(fname);
                print fname;
                next;
            }
        }
        in_block == 1 {
            print > fname;
        }
    ' "${src}"
}

EXTRACTED=()
# Auto-wrap snippets that contain only statements/expressions. A bare
# `EdgeRum.track(...)` line is a perfectly valid recipe example but
# Swift's top-level parser only accepts declarations (`func`, `struct`,
# `class`, …) outside `main.swift`. We detect declaration-only blocks
# and leave them alone; for everything else we synthesise a wrapper
# function so the recipe parses without the doc author having to bloat
# the example with boilerplate.
needs_wrapper() {
    local file="$1"
    # If the file contains any top-level declaration keyword (after
    # stripping import lines and comments), assume it's structured and
    # parse it as-is. Match lines starting with `func`, `struct`,
    # `class`, `enum`, `protocol`, `extension`, `actor`, `@main`,
    # `final class`, `public ...`, or `internal ...`.
    if grep -Eq '^[[:space:]]*(public|internal|fileprivate|private|final|@main|@objc|@objcMembers|@available)[[:space:]]+(class|struct|enum|protocol|extension|actor|func)\b|^[[:space:]]*(func|struct|class|enum|protocol|extension|actor)[[:space:]]' "${file}"; then
        return 1
    fi
    return 0
}

emit_snippet() {
    local snippet="$1"
    local rel="$2"
    local idx="$3"
    local tmp="${snippet}.tmp"

    # Attribution header.
    {
        printf "// extracted from %s (block %s)\n" "${rel}" "${idx}"
    } > "${tmp}"

    if needs_wrapper "${snippet}"; then
        # Split imports off the top of the file, emit them first, then
        # wrap the remainder in a unique async-throws function so any
        # statement / expression / `try` / `await` is legal.
        awk -v fname="${tmp}" '
            BEGIN { in_imports = 1 }
            /^[[:space:]]*import[[:space:]]/ {
                if (in_imports) {
                    print > fname;
                    next;
                }
            }
            /^[[:space:]]*$/ {
                if (in_imports) {
                    print > fname;
                    next;
                }
            }
            {
                if (in_imports) {
                    in_imports = 0;
                    print "func _doc_snippet_" snippet_id "() async throws {" > fname;
                }
                print > fname;
            }
            END {
                if (!in_imports) {
                    print "}" >> fname;
                }
            }
        ' snippet_id="$(echo "${idx}" | tr -d '_')" "${snippet}"
    else
        cat "${snippet}" >> "${tmp}"
    fi

    mv "${tmp}" "${snippet}"
}

for md in "${DOC_FILES[@]}"; do
    rel="${md#${REPO_ROOT}/}"
    prefix="$(echo "${rel}" | tr '/.' '__')"
    block_idx=0
    while IFS= read -r snippet; do
        [[ -z "${snippet}" ]] && continue
        block_idx=$((block_idx + 1))
        EXTRACTED+=("${snippet}")
        emit_snippet "${snippet}" "${rel}" "${block_idx}"
        # Banned-token sweep — runs against the wrapped output so any
        # token introduced by the wrapper itself (none, but be explicit)
        # would also be caught.
        #
        # `edge_telemetry_ios_sdk` is the repository slug; the wire-
        # contract literals `telemetry_batch` and `/collector/telemetry`
        # appear verbatim in doc snippets that describe the envelope.
        # Strip all three before scanning each snippet line.
        sanitised="${snippet}.sanitised"
        sed -e 's|edge_telemetry_ios_sdk||g' \
            -e 's|telemetry_batch||g' \
            -e 's|/collector/telemetry||g' \
            "${snippet}" > "${sanitised}"
        for token in "${BANNED_TOKENS[@]}"; do
            if grep -iqE "(^|[^A-Za-z])${token}([^A-Za-z]|$)" "${sanitised}"; then
                report "banned term \"${token}\" in ${rel} snippet $(basename "${snippet}")"
            fi
        done
        rm -f "${sanitised}"
    done < <(extract_swift_blocks "${md}" "${prefix}")
done

if [[ "${#EXTRACTED[@]}" -eq 0 ]]; then
    echo "extract-readme-code: no fenced \`\`\`swift blocks found — nothing to check" >&2
    exit 0
fi

echo "extract-readme-code: parsing ${#EXTRACTED[@]} snippet(s) against EdgeRum…"

# One-shot parse pass. -parse instead of -emit-module so we get the
# type checker without paying for codegen; -I "${MODULE_DIR}" lets the
# import find EdgeRum and friends without us re-spelling the swiftpm
# build flags.
PARSE_LOG="$(mktemp -t extract-readme-parse.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f \"${PARSE_LOG}\"" EXIT

if ! swiftc -parse \
        -sdk "${SDK}" \
        -target "$(uname -m)-apple-ios14.0-simulator" \
        -I "${MODULE_DIR}" \
        -F "${MODULE_DIR}" \
        "${EXTRACTED[@]}" \
        > "${PARSE_LOG}" 2>&1; then
    echo "extract-readme-code: swiftc -parse failed on one or more snippets:" >&2
    sed 's/^/  /' "${PARSE_LOG}" >&2
    fail_count=$((fail_count + 1))
fi

if (( fail_count > 0 )); then
    echo "extract-readme-code: ${fail_count} failure(s)." >&2
    exit 1
fi

echo "extract-readme-code: all snippets parse cleanly against EdgeRum."
exit 0
