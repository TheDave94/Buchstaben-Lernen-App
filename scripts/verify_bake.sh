#!/usr/bin/env bash
# verify_bake.sh — codify the two release-blocking properties of the
# stroke bake (see docs/APP_DOCUMENTATION.md §13.6):
#
#   1. Determinism: 3 successive bakes produce byte-identical output.
#   2. Byte-identity: a fresh bake matches HEAD's checked-in
#      PrimaeNative/Resources/Letters/Regular/<X>/strokes.json for every
#      letter. The lowercase-b firewall (a803d9d) is just a special
#      case of (2).
#
# Exits non-zero on any drift. Intended for: pre-commit, CI, or a quick
# manual run after editing generate_strokes_auto.py.
#
# Usage:
#   ./scripts/verify_bake.sh                # all letters in LETTERS dict
#   ./scripts/verify_bake.sh M N V W b      # subset
#
# Only Regular is verified here; Light is tracked separately when its
# tuning sweep lands.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

LETTERS=("$@")
TMP=$(mktemp -d -t primae-verify-bake-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

run_bake() {
    local out_dir="$1"
    mkdir -p "$out_dir"
    python3 scripts/generate_strokes_auto.py "${LETTERS[@]}" \
        --weight regular --out "$out_dir" >/dev/null 2>"$TMP/bake.err" || {
        echo "FAIL — bake errored:" >&2
        cat "$TMP/bake.err" >&2
        exit 1
    }
}

hashes_for() {
    # Hash every strokes.json under the given root, normalised by
    # letter-folder name so the three bakes can be compared.
    find "$1" -name strokes.json -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sed "s|$1/||" \
        | sort
}

echo "Bake 1/3 → $TMP/bake1"
run_bake "$TMP/bake1"
echo "Bake 2/3 → $TMP/bake2"
run_bake "$TMP/bake2"
echo "Bake 3/3 → $TMP/bake3"
run_bake "$TMP/bake3"

H1=$(hashes_for "$TMP/bake1")
H2=$(hashes_for "$TMP/bake2")
H3=$(hashes_for "$TMP/bake3")

if [[ "$H1" != "$H2" ]] || [[ "$H1" != "$H3" ]]; then
    echo "FAIL — determinism check: 3 successive bakes diverged" >&2
    diff <(echo "$H1") <(echo "$H2") | head -20 >&2 || true
    exit 1
fi
echo "PASS — determinism: 3 bakes byte-identical"

# Restrict HEAD comparison to the folders the bake actually produced.
# Bake output paths are Regular/<letter>/strokes.json.
BAKED_FOLDERS=$(find "$TMP/bake1" -name strokes.json -printf '%h\n' \
    | sed "s|$TMP/bake1/||" | sort -u)
HEAD_HASHES=$(hashes_for "PrimaeNative/Resources/Letters")
HEAD_HASHES=$(echo "$HEAD_HASHES" | awk -v folders="$BAKED_FOLDERS" '
    BEGIN { split(folders, a, "\n"); for (i in a) keep[a[i]] = 1 }
    {
        folder = $2
        sub(/\/strokes\.json$/, "", folder)
        if (folder in keep) print
    }
')

if ! diff -q <(echo "$HEAD_HASHES") <(echo "$H1") >/dev/null; then
    echo "FAIL — byte-identity vs HEAD: bake diverged from checked-in strokes.json" >&2
    echo "Divergent letters:" >&2
    diff <(echo "$HEAD_HASHES") <(echo "$H1") | head -40 >&2 || true
    exit 1
fi
echo "PASS — byte-identity: bake matches HEAD for every letter"

# Lowercase-b firewall: explicitly assert b_l/strokes.json is unchanged.
# Redundant with byte-identity above, but called out separately so a
# failure log names the firewall directly.
B_HEAD_PATH="PrimaeNative/Resources/Letters/Regular/b_l/strokes.json"
B_BAKE_PATH="$TMP/bake1/Regular/b_l/strokes.json"
B_HEAD=$(sha256sum "$B_HEAD_PATH" | awk '{print $1}')
B_BAKE=$(sha256sum "$B_BAKE_PATH" 2>/dev/null | awk '{print $1}' || echo "(no b in bake)")
if [[ "$B_HEAD" != "$B_BAKE" ]] && [[ "$B_BAKE" != "(no b in bake)" ]]; then
    echo "FAIL — b firewall: b_l/strokes.json diverged from commit a803d9d" >&2
    exit 1
fi
echo "PASS — b firewall: b_l/strokes.json is unchanged"

echo ""
echo "All checks passed."
