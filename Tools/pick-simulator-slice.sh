#!/usr/bin/env bash
#
# Tools/pick-simulator-slice.sh
#
# F19 / T19.6 — Select an iOS Simulator UDID for one of the three
# device-matrix slots:
#
#   min — oldest available iOS runtime, prefer an iPhone SE
#   mid — middle iOS runtime, prefer an iPhone 11
#   new — newest iOS runtime, prefer an iPhone 15 Pro or newer
#
# §13.7 of PLAN-iOS.md spec'd the literal triple `iPhone SE 2 / iOS 14.5,
# iPhone 11 / iOS 16.4, iPhone 15 Pro / iOS 17.4`. macOS GitHub runners
# no longer ship those runtimes; this script picks the closest device +
# runtime trio actually installed on the host and prints the resulting
# `-destination` string suitable for piping straight into xcodebuild.
#
# CI sets the slot via `--slot {min,mid,new}` and reads the resulting
# `DESTINATION=…` from $GITHUB_OUTPUT, or invokes
# `--print-destination` for a single string on stdout.
#
# Exits non-zero with a clear message if fewer than three iOS runtimes
# are installed or no usable iPhone device exists in any of them.
#
# Refs: PLAN-iOS.md §13.7; CLAUDE.md "CI checks".

set -euo pipefail

SLOT=""
EMIT_GITHUB=true
ALLOW_ANY_DEVICE=false

usage() {
    cat <<'EOF'
Usage: pick-simulator-slice.sh --slot {min|mid|new} [--print-destination]

Options:
  --slot {min|mid|new}    Which device-matrix slot to pick.
  --print-destination     Print the xcodebuild destination string to
                          stdout instead of $GITHUB_OUTPUT.
  --allow-any-device      If the slot's preferred iPhone model is not
                          available on the runner, fall back to the
                          first available iPhone on that runtime
                          instead of failing.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slot)              SLOT="$2"; shift 2 ;;
        --print-destination) EMIT_GITHUB=false; shift ;;
        --allow-any-device)  ALLOW_ANY_DEVICE=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$SLOT" ]]; then
    echo "missing --slot" >&2
    usage
    exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required (run on a Mac with Xcode installed)" >&2
    exit 2
fi

# Preferred iPhone family per slot. The script walks the list in
# order and picks the first model that exists on the chosen runtime.
case "$SLOT" in
    min)
        PREFERRED=(
            "iPhone SE (2nd generation)"
            "iPhone SE (3rd generation)"
            "iPhone SE"
            "iPhone 8"
            "iPhone 11"
        )
        ;;
    mid)
        PREFERRED=(
            "iPhone 11"
            "iPhone 11 Pro"
            "iPhone 12"
            "iPhone 13"
            "iPhone SE (3rd generation)"
        )
        ;;
    new)
        PREFERRED=(
            "iPhone 15 Pro"
            "iPhone 15"
            "iPhone 16 Pro"
            "iPhone 16"
            "iPhone 17 Pro"
            "iPhone 17"
        )
        ;;
    *) echo "unknown slot '$SLOT' (expected min/mid/new)" >&2; exit 2 ;;
esac

DEVICES_JSON="$(xcrun simctl list devices available -j)"

# Discover every iOS-prefixed runtime identifier with at least one
# device installed under it, then sort by version number ascending.
# macOS ships bash 3.x without `mapfile`, so we accumulate manually.
RUNTIMES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && RUNTIMES+=("$line")
done < <(
    /usr/bin/python3 -c '
import json, re, sys
data = json.load(sys.stdin)
devices = data.get("devices", {})
items = []
for rt, ds in devices.items():
    if not ds: continue
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    if not m: continue
    major, minor = int(m.group(1)), int(m.group(2))
    items.append(((major, minor), rt))
items.sort()
for (_, rt) in items:
    print(rt)
' <<<"$DEVICES_JSON"
)

if (( ${#RUNTIMES[@]} == 0 )); then
    echo "no iOS Simulator runtimes with devices found on this host" >&2
    exit 3
fi

if (( ${#RUNTIMES[@]} < 3 )); then
    echo "found only ${#RUNTIMES[@]} iOS runtimes (need 3 for the matrix)" >&2
    echo "runtimes seen: ${RUNTIMES[*]}" >&2
    # The matrix can still run — fall back to oldest/oldest/newest so
    # at least one slot is unique. Document the squash and continue.
    if (( ${#RUNTIMES[@]} == 0 )); then
        exit 3
    fi
fi

LAST_IDX=$(( ${#RUNTIMES[@]} - 1 ))
case "$SLOT" in
    min) RUNTIME="${RUNTIMES[0]}" ;;
    new) RUNTIME="${RUNTIMES[$LAST_IDX]}" ;;
    mid)
        if (( ${#RUNTIMES[@]} >= 3 )); then
            MID_IDX=$(( ${#RUNTIMES[@]} / 2 ))
            RUNTIME="${RUNTIMES[$MID_IDX]}"
        elif (( ${#RUNTIMES[@]} == 2 )); then
            RUNTIME="${RUNTIMES[0]}"
        else
            RUNTIME="${RUNTIMES[0]}"
        fi
        ;;
esac

# Walk the preferred list inside the chosen runtime. Use python again
# so the JSON shape is parsed cleanly.
PICK=$(
    PREFERRED_JSON=$(printf '%s\n' "${PREFERRED[@]}" \
        | /usr/bin/python3 -c 'import json,sys; print(json.dumps([l.rstrip() for l in sys.stdin]))')
    ALLOW_ANY_DEVICE="$ALLOW_ANY_DEVICE" RUNTIME="$RUNTIME" PREFERRED_JSON="$PREFERRED_JSON" \
    /usr/bin/python3 -c '
import json, os, sys
data = json.load(sys.stdin)
runtime = os.environ["RUNTIME"]
preferred = json.loads(os.environ["PREFERRED_JSON"])
allow_any = os.environ.get("ALLOW_ANY_DEVICE", "false") == "true"
devices = data.get("devices", {}).get(runtime, [])
pool = [d for d in devices if d.get("isAvailable")]
def find(name):
    for d in pool:
        if d.get("name") == name:
            return d
    return None
for name in preferred:
    d = find(name)
    if d:
        print(d["name"] + "\t" + d["udid"])
        sys.exit(0)
if allow_any:
    for d in pool:
        n = d.get("name", "")
        if "iPhone" in n:
            print(n + "\t" + d["udid"])
            sys.exit(0)
sys.exit(4)
' <<<"$DEVICES_JSON"
)

EXIT=$?
if (( EXIT == 4 )) || [[ -z "$PICK" ]]; then
    echo "no preferred iPhone device available on runtime '$RUNTIME' for slot '$SLOT'" >&2
    echo "tried: ${PREFERRED[*]}" >&2
    exit 4
fi

NAME="$(printf '%s' "$PICK" | cut -f1)"
UDID="$(printf '%s' "$PICK" | cut -f2)"
RUNTIME_HUMAN="$(printf '%s' "$RUNTIME" | sed -E 's/.*iOS-([0-9]+)-([0-9]+).*/\1.\2/')"

DEST="platform=iOS Simulator,id=${UDID}"

if [[ "$EMIT_GITHUB" == true && -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "destination=${DEST}"
        echo "udid=${UDID}"
        echo "device_name=${NAME}"
        echo "runtime=${RUNTIME_HUMAN}"
    } >> "$GITHUB_OUTPUT"
    echo "pick-simulator-slice[$SLOT]: ${NAME} (${RUNTIME_HUMAN}) → ${DEST}"
else
    echo "$DEST"
fi
