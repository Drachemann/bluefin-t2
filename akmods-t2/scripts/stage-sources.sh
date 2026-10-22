#!/bin/bash
# stage-sources.sh — copy the pinned KAIT2EN module sources into a build tree, and
# prove the copy is byte-identical to the pinned commit.
#
# Usage: stage-sources.sh [--target DIR] [--clone DIR]
#
# The clone under research/ is read-only reference material and is never written to.
# This script copies out of it; it does not patch anything. A patch that seems needed
# is a finding, not a step (record/SOURCES.md).
#
# Two checks, and the second is the authoritative one:
#   1. the clone's HEAD equals the pinned commit — a moved submodule is a deliberate
#      act, not a silent input;
#   2. `diff -r` of every copied directory against its source is empty.
# The recorded per-directory tree_sha256 values from record/SOURCES.md are checked as a
# third, historical cross-check when a collation that reproduces them is available; the
# 2026-10-20 values were produced under a UTF-8 collation, and C/C.UTF-8 sorts those
# paths differently. A missing locale skips only that third check, never check 2.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

CLONE="${KAIT2EN_CLONE:-$ROOT/research/KaiT2en-Fedora}"
TARGET="${TARGET:-$ROOT/.build/src}"

# Pinned by record/SOURCES.md. Moving it is a deliberate commit-level act: update the
# pin and the tree hashes together, after re-reading what changed upstream.
PINNED=ba9d2d830ae5b4ccacf7f82ccc305270496397ff

while (( $# )); do
    case "$1" in
        --clone)  CLONE="${2:?--clone needs a directory}"; shift 2 ;;
        --target) TARGET="${2:?--target needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

SPECS=(
    t2bce_stack t2touchbar hid_t2magicmouse t2bdrm t2smc t2sbs t2mfi_fastcharge
    t2gmux t2thunderbolt t2smp t2_precision_trackpad t2_trackpad_actuator
)
COMPONENTS=( t2bce_dma t2bce_core t2bce_vhci t2bce_audio )

fail() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "  $*"; }

[[ -d "$CLONE" ]] || fail "pinned clone not found at $CLONE (set KAIT2EN_CLONE)"

# --- 1. the clone is at the pinned commit -------------------------------------------
head=""
if command -v git >/dev/null 2>&1; then
    head="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -z "$head" && -f "$CLONE/.git/refs/heads/main" ]]; then
    head="$(cat "$CLONE/.git/refs/heads/main")"
fi
[[ -n "$head" ]] || fail "cannot determine the clone's HEAD at $CLONE"
if [[ "$head" != "$PINNED" ]]; then
    fail "clone is at $head, pinned is $PINNED.
       The pin lives in this script and in record/SOURCES.md. Re-read the upstream
       change and move the pin deliberately; do not stage an unpinned tree."
fi
info "clone HEAD matches the pin: $head"

# --- 2. copy, then diff every directory against its source --------------------------
rm -rf "$TARGET"
mkdir -p "$TARGET"
for s in "${SPECS[@]}"; do
    [[ -d "$CLONE/modules/$s" ]] || fail "missing upstream directory modules/$s"
    mkdir -p "$TARGET/$s"
    cp -a "$CLONE/modules/$s/." "$TARGET/$s/"
done
for c in "${COMPONENTS[@]}"; do
    [[ -d "$CLONE/modules/$c" ]] || fail "missing upstream directory modules/$c"
    mkdir -p "$TARGET/components/$c"
    cp -a "$CLONE/modules/$c/." "$TARGET/components/$c/"
done
# t2bce_ave is not a 13th spec: it is a build input of t2bce_stack, staged from
# t2-services/t2-ave/kernel/ exactly as scripts/fedora/install-dkms-modules.sh does.
[[ -d "$CLONE/t2-services/t2-ave/kernel/t2bce_ave" ]] || fail "missing upstream t2-services/t2-ave/kernel/t2bce_ave"
mkdir -p "$TARGET/t2bce_ave"
cp -a "$CLONE/t2-services/t2-ave/kernel/t2bce_ave/." "$TARGET/t2bce_ave/"

pairs=()
for s in "${SPECS[@]}"; do pairs+=("$TARGET/$s|$CLONE/modules/$s"); done
for c in "${COMPONENTS[@]}"; do pairs+=("$TARGET/components/$c|$CLONE/modules/$c"); done
pairs+=("$TARGET/t2bce_ave|$CLONE/t2-services/t2-ave/kernel/t2bce_ave")

# Do not assume the host's `diff` is GNU diff: this machine's PATH carries a uutils
# build without `-r`. git's no-index comparison is recursive, symlink-aware and
# independent of which diffutils is installed.
dirs_identical() {
    if command -v git >/dev/null 2>&1; then
        git diff --no-index --quiet -- "$1" "$2"
    elif [[ -x /usr/bin/diff ]]; then
        /usr/bin/diff -r "$1" "$2" >/dev/null 2>&1
    else
        echo "FATAL: no directory comparator available (need git or /usr/bin/diff)" >&2
        return 2
    fi
}

for pair in "${pairs[@]}"; do
    dst="${pair%%|*}"; src="${pair##*|}"
    if ! dirs_identical "$src" "$dst"; then
        echo "--- differing files in $dst (vs $src) ---" >&2
        if command -v git >/dev/null 2>&1; then
            git diff --no-index --name-status -- "$src" "$dst" 2>/dev/null | head -20 >&2 || true
        fi
        fail "$dst is not byte-identical to $src"
    fi
done
info "diff -r: ${#pairs[@]}/${#pairs[@]} directories byte-identical to the pinned commit"

# --- 3. the recorded tree hashes, as a historical cross-check ----------------------
# dir|files|bytes|tree_sha256  (from record/SOURCES.md, 2026-10-20)
TREE_HASHES='
t2bce_stack|3|1629|02a6dd3268aff32efc15fe7afebb7982c0fe4c971f678991140b409c7af2c45c
t2touchbar|8|130710|262325d23ea42bce2f3c19478a92948728a7d71ac0c3f1d12d9dce0fd90e82e4
hid_t2magicmouse|4|117804|932027b98b735fca7ef37bcd8906915f5a6b8c91a5cb1c3b51b326c253029b2d
t2bdrm|4|30534|83469b9aaa94edc77e4b3e2f41ae7a79ee60d5b9aeb6ffd275f58660c425705f
t2smc|5|109566|b68855113a7aa76f8a4bde7ea22e1ded31c4a4e276b88bd3290f76f57cf16c76
t2sbs|5|24425|5f9d6df0020ae1531f5605c901539c37af669ee5ae0884a886c99db381458c48
t2mfi_fastcharge|4|7142|d3e02114a6bbea6892261eddf84d706b279467bb39677f022fde71ff97c500d1
t2gmux|4|49939|2d606721a291ac4f2f97077294c6dfa5a84beb2172b30a66715ade192c2ea272
t2thunderbolt|5|11716|5b77122da11f6c26f79d45eb9e5c8168a5f7fa10a830dc5e00b15aff8c5ff733
t2smp|3|4477|75af43f4d7487532e08596c1373bc48ebcb0151f4274e453cd188e76536160dc
t2_precision_trackpad|6|45237|ab6e6fb1322903ff7c747219450733fa2ee050da7cd4a4f5743a2b6352bb42ab
t2_trackpad_actuator|7|16332|f35a52989997e46ccdeba72df43af69c8eb89bafd94e33cd14599e003b6a44db
t2bce_ave|9|99595|0ca7b51afdc35ea8a1df90cb4e0e4819ef2cef6b07375f0a0e3247be0c22fdfc
components/t2bce_dma|4|36156|c90d041398d780e57614e9b9c79c3b1e471267e6f32716dc825d460069468cd0
components/t2bce_core|9|66244|4c70e514abd25737717012f0e0ca869577432786595a37f0e3e0661319035802
components/t2bce_vhci|8|119170|bc6acc2a25d47e3ff1e8e8da8f18e5f870f6713c73e316211d19cb47a0505db3
components/t2bce_audio|13|104897|006f1d9bc2d13b4cc5c6fd667d577457eb22732261e7518bb9f4d725fb304176
'

tree_hash() {
    # sha256 of the sorted `sha256sum` output, paths relative to the directory.
    ( cd "$1" && find . -type f | LC_ALL="$HASH_LOCALE" sort | xargs -d '\n' sha256sum | sha256sum | cut -d' ' -f1 )
}

pick_hash_locale() {
    # The recorded hashes were produced under a UTF-8 collation. Select the first
    # available locale that reproduces the first recorded value; C/C.UTF-8 sorts some
    # paths differently, so it is deliberately not a candidate.
    local cand h want
    want="$(printf '%s\n' "$TREE_HASHES" | awk -F'|' 'NF>3 {print $4; exit}')"
    for cand in en_US.UTF-8 en_US.utf8 en_AU.UTF-8 en_AU.utf8; do
        if locale -a 2>/dev/null | grep -qix "$(echo "$cand" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"; then
            HASH_LOCALE="$cand"
            h="$(tree_hash "$TARGET/t2bce_stack")"
            [[ "$h" == "$want" ]] && return 0
        fi
    done
    return 1
}

if pick_hash_locale; then
    hash_bad=0
    while IFS='|' read -r dir files bytes want; do
        [[ -n "$dir" ]] || continue
        got="$(tree_hash "$TARGET/$dir")"
        n="$(find "$TARGET/$dir" -type f | wc -l)"
        b="$(du -sb --apparent-size "$TARGET/$dir" | cut -f1)"
        if [[ "$got" != "$want" ]]; then
            echo "  MISMATCH $dir: tree_sha256 $got != recorded $want" >&2; hash_bad=1
        elif [[ "$n" != "$files" || "$b" != "$bytes" ]]; then
            echo "  MISMATCH $dir: $n files / $b bytes != recorded $files / $bytes" >&2; hash_bad=1
        fi
    done <<< "$TREE_HASHES"
    (( hash_bad == 0 )) || fail "recorded tree hashes do not match the staged copy"
    info "recorded tree_sha256 verified for all 17 directories (collation: $HASH_LOCALE)"
else
    echo "  WARNING: no UTF-8 collation on this host reproduces the recorded tree hashes;" >&2
    echo "           byte-identity is proven by diff -r above, which is the stronger check." >&2
fi

files_total="$(find "$TARGET" -type f | wc -l)"
echo "staged $files_total files in ${#pairs[@]} directories from $CLONE @ $PINNED"
echo "target: $TARGET"
