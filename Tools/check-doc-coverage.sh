#!/usr/bin/env bash
#
# Tools/check-doc-coverage.sh
#
# Fails when any public symbol in the EdgeRum target lacks a doc
# comment. Wraps `swift package dump-symbol-graph
# --minimum-access-level public` and scans the produced
# EdgeRum.symbols.json for symbols where the `docComment` block is
# missing or empty.
#
# DocC's own `--warnings-as-errors` build is the second layer; this
# script catches the same gap pre-DocC, which is faster locally and
# surfaces "you added a public symbol with no `///`" before the
# DocC compiler runs.
#
# Refs: PLAN-iOS.md §12.5; CLAUDE.md "Swift conventions" (every public
#       symbol carries a `///` doc comment).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

echo "check-doc-coverage: dumping public symbol graph for EdgeRum…"
SG_STDERR="$(mktemp -t edge-rum-doc-symgraph-err.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f \"${SG_STDERR}\"" EXIT

if ! swift package dump-symbol-graph \
        --minimum-access-level public \
        >/dev/null 2> "${SG_STDERR}"; then
    echo "check-doc-coverage: symbol-graph generation failed:" >&2
    sed 's/^/  /' "${SG_STDERR}" >&2
    exit 1
fi

SYMBOL_JSON="$(find "${REPO_ROOT}/.build" \
    -type f \
    -path '*/symbolgraph/EdgeRum.symbols.json' \
    2>/dev/null | head -n1)"

if [[ -z "${SYMBOL_JSON}" || ! -f "${SYMBOL_JSON}" ]]; then
    echo "check-doc-coverage: no EdgeRum.symbols.json produced" >&2
    exit 1
fi

# We need a JSON parser. Prefer `jq` (Homebrew default on macos-15)
# and fall back to a Python one-liner so the script still works on
# developer machines without jq.
parse_with_jq() {
    # String interpolation keeps each subexpression scoped to the
    # original symbol object — the previous version chained `| join(.)`
    # which silently rebound `.` to a string for the rest of the
    # pipeline and crashed on the next `.kind` access.
    jq -r '
        .symbols[]
        | select(.identifier.precise != null)
        | select((.docComment // {}) | (.lines // []) | length == 0)
        | "\((.pathComponents // []) | join("."))  [\(.kind.identifier // "unknown")]  (\(.identifier.precise // ""))"
    ' "${SYMBOL_JSON}"
}

parse_with_python() {
    python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
for sym in data.get("symbols", []):
    if sym.get("identifier", {}).get("precise") is None:
        continue
    doc = sym.get("docComment") or {}
    lines = doc.get("lines") or []
    if not lines:
        path = ".".join(sym.get("pathComponents") or [])
        kind = sym.get("kind", {}).get("identifier") or "unknown"
        precise = sym.get("identifier", {}).get("precise") or ""
        print(f"{path}  [{kind}]  ({precise})")
PY
}

if command -v jq >/dev/null 2>&1; then
    UNDOC="$(parse_with_jq || true)"
elif command -v python3 >/dev/null 2>&1; then
    UNDOC="$(parse_with_python "${SYMBOL_JSON}" || true)"
else
    echo "check-doc-coverage: need either 'jq' or 'python3' to scan symbol graph" >&2
    exit 1
fi

# Some symbol kinds are not host-app-facing API: protocol witness tables,
# synthesised Hashable / Equatable members, default associated-type
# alias bindings, etc. Filter them out so a missing doc comment on
# synthesised members doesn't blow up CI.
#
# The `::SYNTHESIZED::` marker in the precise identifier catches every
# Hashable / Equatable / RawRepresentable witness — they cannot carry
# a /// comment because they're not source-declared. `swift.deinit` is
# similar. AttributeValue itself is a typealias re-export from
# EdgeRumCore; the cases live in the internal module.
FILTER_OUT='\[swift\.deinit\]|::SYNTHESIZED::|\[swift\.synthesized\.|^Swift\.|\.\(extension in EdgeRum\)|^EdgeRum\.AttributeValue\b|^EdgeRum\.AttributeValue\.'

UNDOC_FILTERED="$(printf "%s\n" "${UNDOC}" | grep -vE "${FILTER_OUT}" || true)"
UNDOC_FILTERED="$(printf "%s\n" "${UNDOC_FILTERED}" | sed '/^$/d')"

if [[ -z "${UNDOC_FILTERED}" ]]; then
    echo "check-doc-coverage: every public EdgeRum symbol carries a doc comment."
    exit 0
fi

echo "check-doc-coverage: the following public symbols are missing /// doc comments:" >&2
printf "%s\n" "${UNDOC_FILTERED}" | sed 's/^/  /' >&2
exit 1
