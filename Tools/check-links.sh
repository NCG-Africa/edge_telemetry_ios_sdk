#!/usr/bin/env bash
#
# Tools/check-links.sh
#
# Runs `lychee` over every Markdown file in the repository and fails
# on broken links. Internal anchors (`#section-name`) are checked too,
# so a typo in a README anchor link is a CI failure.
#
# Refs: PLAN-iOS.md §12.5 (Doc-quality CI).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${REPO_ROOT}"

# Auto-install lychee on a macOS runner that has Homebrew. Local devs
# get the same install path; non-Homebrew environments need to install
# lychee themselves (`cargo install lychee`).
if ! command -v lychee >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "check-links: installing lychee via Homebrew…"
        brew install lychee
    else
        echo "check-links: lychee not installed and Homebrew not on PATH" >&2
        echo "check-links: install with 'cargo install lychee' or 'brew install lychee'" >&2
        exit 1
    fi
fi

# Markdown corpus — every .md outside `.build/` and the per-sample
# `build/` derived-data directories.
MD_GLOB=(
    "README.md"
    "CHANGELOG.md"
    "docs/**/*.md"
    "Sources/EdgeRum/EdgeRum.docc/**/*.md"
    "Samples/**/*.md"
)

# Build the lychee args list. Excludes:
#   - GitHub Actions badge URLs (rate-limited to a per-installation quota
#     that fails when CI runs back-to-back PRs).
#   - localhost placeholders the README/Sample apps reference for the
#     "replace this with your real endpoint" walkthrough.
LYCHEE_FLAGS=(
    --no-progress
    --include-fragments
    --max-concurrency 4
    --timeout 30
    --max-redirects 5
    --exclude "^https://github\.com/NCG-Africa/edge_telemetry_ios_sdk/actions/"
    --exclude "^https?://localhost(:|/|$)"
    --exclude "^https?://collect\.example\.com"
    --exclude "^https?://api\.example\.com"
    --exclude "^https?://your\.endpoint"
    --exclude "^https?://noisy\.analytics\.example\.com"
    --exclude "^https?://noisy\.example\.com"
)

# Pass globs through `find` — lychee's own glob expansion is shell-
# dependent and we want predictable behaviour across mac/linux.
TARGETS=()
for pattern in "${MD_GLOB[@]}"; do
    while IFS= read -r f; do
        TARGETS+=("${f}")
    done < <(find . -type f -path "./${pattern}" -not -path "./.build/*" -not -path "*/build/*" -not -path "*/DerivedData/*" 2>/dev/null)
done

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    echo "check-links: no Markdown files matched — nothing to check"
    exit 0
fi

echo "check-links: checking ${#TARGETS[@]} Markdown file(s) with lychee…"
lychee "${LYCHEE_FLAGS[@]}" "${TARGETS[@]}"
echo "check-links: all links resolve."
exit 0
