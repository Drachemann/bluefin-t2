#!/bin/bash
# fetch-kernel-rpms.sh — fetch and hash-pin the kernel packages for the proof container.
#
# Usage: fetch-kernel-rpms.sh [--check] [--dir DIR]
#
# The four RPMs in container/kernel-rpms.sha256 are the kernel release the pinned
# Bluefin digest ships (7.2.5-200.fc44.x86_64). That release has aged out of the Fedora
# 44 repositories, so the files come from Fedora's build system. They carry no Fedora
# GPG signature — `rpm -K` verifies payload digests only — so the pinned sha256 in this
# repository IS the provenance check. Never edit a hash to make a download pass, and
# never disable the check: a pinned hash is the alternative to trusting a floating URL,
# not a weaker form of a signature check (research/findings/module-pipeline.md §1).
#
# --check verifies the files already on disk and downloads nothing.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AKMODS=$(cd "$HERE/.." && pwd)
LIST="$AKMODS/container/kernel-rpms.sha256"
DIR="$AKMODS/container/rpms"
CHECK=0

while (( $# )); do
    case "$1" in
        --check) CHECK=1; shift ;;
        --dir) DIR="${2:?--dir needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -f "$LIST" ]] || { echo "FATAL: pin list missing at $LIST" >&2; exit 1; }
mkdir -p "$DIR"

bad=0
while read -r want name url; do
    [[ -n "$want" && "$want" != \#* ]] || continue
    target="$DIR/$name"
    if [[ -f "$target" ]]; then
        got="$(sha256sum "$target" | cut -d' ' -f1)"
        if [[ "$got" == "$want" ]]; then
            echo "  ok: $name (pinned sha256)"
            continue
        fi
        echo "  MISMATCH: $name on disk is $got, pinned $want" >&2
        bad=1
        (( CHECK )) && continue
        echo "  removing the mismatched file and refetching once" >&2
        rm -f "$target"
    elif (( CHECK )); then
        echo "  MISSING: $name (run without --check to fetch)" >&2
        bad=1
        continue
    fi

    echo "  fetch: $name"
    tmp="$target.part"
    curl -fsSL --retry 2 --output "$tmp" "$url" \
        || { echo "  FAILED to download $url" >&2; rm -f "$tmp"; bad=1; continue; }
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
        echo "  FAILED hash: $name downloaded as $got, pinned $want" >&2
        rm -f "$tmp"
        bad=1
        continue
    fi
    mv "$tmp" "$target"
    echo "  ok: $name (downloaded, sha256 pinned)"
done < "$LIST"

(( bad == 0 )) || { echo "FATAL: one or more kernel RPMs are missing or do not match the pin" >&2; exit 1; }
echo "kernel RPMs verified in $DIR"
echo "note: provenance is HTTPS to koji + the pinned sha256; these files carry no Fedora GPG signature."
