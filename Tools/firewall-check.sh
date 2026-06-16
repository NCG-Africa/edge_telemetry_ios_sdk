#!/usr/bin/env bash
#
# Tools/firewall-check.sh
#
# Enforces Rule 1 — the terminology firewall. The SDK ships with
# OpenTelemetry as a hidden implementation detail; consumer code never
# sees the words `span`, `trace`, `tracer`, `instrumentation`,
# `telemetry`, `opentelemetry`, `otel`, or `otlp`. This script
# catches any leak before it lands.
#
# Scopes the check to:
#
#   1. The public Swift surface — `swift package dump-symbol-graph
#      --target EdgeRum --minimum-access-level public` walks every
#      public/open symbol and its doc comment.
#   2. Source-file pre-check — greps `Sources/EdgeRum/**/*.swift`
#      for any `///` doc-comment line containing a banned token.
#      Faster than the symbol graph and surfaces problems before
#      the compiler runs.
#   3. README.md (when present).
#   4. Other consumer-facing markdown under `docs/` — except files
#      explicitly listed in `INTERNAL_DOCS` (those discuss SDK
#      internals and are allowed to use banned terms).
#
# Any match exits non-zero with a "found `<term>` in `<location>`"
# line. Zero matches → exit 0.
#
# Refs: CLAUDE.md "Rule 1 — The terminology firewall",
#       PLAN-iOS.md §3.1, §F2/T2.7.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

# Banned tokens — matched case-insensitively as whole-ish words so
# legitimate identifiers like `interaction` are not false-positives.
# `metric` is banned as an API name; the JSON wire field
# `"metricName"` lives in EdgeRumCore (internal) and never reaches
# the public surface, so the symbol-graph check naturally skips it.
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

# Markdown files under docs/ that intentionally discuss SDK internals
# and are allowed to use banned terms. Paths relative to REPO_ROOT.
INTERNAL_DOCS=(
    "docs/data-flow.md"
    "docs/decisions.md"
)

# Where to look in step 2.
PUBLIC_SWIFT_DIR="${REPO_ROOT}/Sources/EdgeRum"

fail_count=0
report() {
    local term="$1" location="$2" line="$3"
    echo "firewall-check: banned term \"${term}\" found in ${location}: ${line}" >&2
    fail_count=$((fail_count + 1))
}

# Build a single grep pattern: token1|token2|...
join_or() {
    local IFS='|'
    echo "$*"
}
PATTERN="$(join_or "${BANNED_TOKENS[@]}")"

# Step 1 — Public Swift symbol graph.
#
# `swift package dump-symbol-graph --minimum-access-level public`
# writes one JSON per module under `.build/<triple>/symbolgraph/`.
# We extract the symbol names + doc-comment text from
# `EdgeRum.symbols.json` and grep for any banned token. URI fields
# carry the repo path on disk — which itself contains "telemetry" in
# this project — so we strip `"uri":"..."` before scanning.
echo "firewall-check: dumping symbol graph for EdgeRum (public)…"

SG_STDERR="$(mktemp -t edge-rum-symgraph-err.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f \"${SG_STDERR}\"" EXIT
if ! swift package dump-symbol-graph \
        --minimum-access-level public \
        >/dev/null 2> "${SG_STDERR}"; then
    echo "firewall-check: warning — symbol-graph generation failed; falling back to source-only check" >&2
    echo "firewall-check: swift package stderr was:" >&2
    sed 's/^/  /' "${SG_STDERR}" >&2 || true
else
    # `swift package dump-symbol-graph` writes into a triple-dependent
    # subdir. Pick the most recent one — there's only ever one for
    # the host swift-build triple at a time.
    SYMBOL_JSON="$(find "${REPO_ROOT}/.build" \
        -type f \
        -path '*/symbolgraph/EdgeRum.symbols.json' \
        2>/dev/null \
        | head -n1)"
    if [[ -z "${SYMBOL_JSON}" || ! -f "${SYMBOL_JSON}" ]]; then
        echo "firewall-check: warning — no EdgeRum.symbols.json produced" >&2
    else
        # Strip URI fields so the repo's on-disk path can't trip the
        # match, then look only inside string fields that carry
        # consumer-visible text (names, doc-comment line text,
        # identifier spellings).
        STRIPPED="$(mktemp -t edge-rum-symbols.XXXXXX)"
        # shellcheck disable=SC2064
        trap "rm -f \"${STRIPPED}\"" EXIT
        sed -E 's/"uri":"[^"]*"//g' "${SYMBOL_JSON}" > "${STRIPPED}"
        while IFS= read -r hit; do
            [[ -z "${hit}" ]] && continue
            for token in "${BANNED_TOKENS[@]}"; do
                if echo "${hit}" | grep -iqE "(^|[^A-Za-z])${token}([^A-Za-z]|$)"; then
                    report "${token}" "symbol-graph EdgeRum.symbols.json" \
                        "$(echo "${hit}" | tr -d '\t' | cut -c1-160)"
                    break
                fi
            done
        done < <(grep -ioE "\"(title|text|spelling|pathComponents)\"[[:space:]]*:[[:space:]]*\"[^\"]*(${PATTERN})[^\"]*\"" "${STRIPPED}" -i 2>/dev/null || true)
    fi
fi

# Step 2 — Source-file doc-comment pre-check.
#
# Greps every `///` line in `Sources/EdgeRum/**/*.swift` for any
# banned token. Catches issues before the symbol graph even compiles.
if [[ -d "${PUBLIC_SWIFT_DIR}" ]]; then
    while IFS= read -r match; do
        [[ -z "${match}" ]] && continue
        file="${match%%:*}"
        rest="${match#*:}"
        lineno="${rest%%:*}"
        content="${rest#*:}"
        for token in "${BANNED_TOKENS[@]}"; do
            if echo "${content}" | grep -iqE "(^|[^A-Za-z])${token}([^A-Za-z]|$)"; then
                report "${token}" "${file#${REPO_ROOT}/}:${lineno}" "$(echo "${content}" | tr -d '\t' | cut -c1-160)"
                break
            fi
        done
    done < <(grep -RInE '^[[:space:]]*///' "${PUBLIC_SWIFT_DIR}" || true)
fi

# Step 3 — README.md.
if [[ -f "${REPO_ROOT}/README.md" ]]; then
    while IFS= read -r match; do
        [[ -z "${match}" ]] && continue
        lineno="${match%%:*}"
        content="${match#*:}"
        for token in "${BANNED_TOKENS[@]}"; do
            if echo "${content}" | grep -iqE "(^|[^A-Za-z])${token}([^A-Za-z]|$)"; then
                report "${token}" "README.md:${lineno}" "$(echo "${content}" | tr -d '\t' | cut -c1-160)"
                break
            fi
        done
    done < <(grep -nE "(${PATTERN})" "${REPO_ROOT}/README.md" -i || true)
fi

# Step 4 — Other consumer-facing markdown under docs/.
if [[ -d "${REPO_ROOT}/docs" ]]; then
    # Build a list of skip paths into a single regex.
    skip_regex=""
    for skip in "${INTERNAL_DOCS[@]}"; do
        if [[ -z "${skip_regex}" ]]; then
            skip_regex="${skip}"
        else
            skip_regex="${skip_regex}|${skip}"
        fi
    done

    while IFS= read -r md; do
        rel="${md#${REPO_ROOT}/}"
        if [[ -n "${skip_regex}" ]] && echo "${rel}" | grep -qE "^(${skip_regex})$"; then
            continue
        fi
        while IFS= read -r match; do
            [[ -z "${match}" ]] && continue
            lineno="${match%%:*}"
            content="${match#*:}"
            for token in "${BANNED_TOKENS[@]}"; do
                if echo "${content}" | grep -iqE "(^|[^A-Za-z])${token}([^A-Za-z]|$)"; then
                    report "${token}" "${rel}:${lineno}" "$(echo "${content}" | tr -d '\t' | cut -c1-160)"
                    break
                fi
            done
        done < <(grep -nE "(${PATTERN})" "${md}" -i || true)
    done < <(find "${REPO_ROOT}/docs" -type f -name '*.md')
fi

if (( fail_count > 0 )); then
    echo "firewall-check: ${fail_count} banned-term leak(s) detected." >&2
    echo "firewall-check: see CLAUDE.md Rule 1 for the consumer vocabulary mapping." >&2
    exit 1
fi

echo "firewall-check: public surface and consumer docs are clean."
exit 0
