#!/usr/bin/bash
# fetch.sh — materialise the read-only reference clones at the pins in PINS.md.
#
# They are not committed (see PINS.md). The build consumes research/KaiT2en-Fedora, so this
# has to run after a fresh clone and before `./build.sh`.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fetch() {
    local name=$1 url=$2 commit=$3 dir
    dir="$here/$name"
    if [[ -d $dir/.git ]]; then
        git -C "$dir" fetch --depth 1 origin "$commit" >/dev/null 2>&1 || true
        git -C "$dir" checkout --detach "$commit"
    else
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
        git -C "$dir" fetch --depth 1 origin "$commit"
        git -C "$dir" checkout --detach FETCH_HEAD
    fi
    printf 'ok   %-28s %s\n' "$name" "$(git -C "$dir" rev-parse --short HEAD)"
}

fetch KaiT2en-Fedora https://github.com/kaiT2en/KaiT2en-Fedora.git ba9d2d830ae5b4ccacf7f82ccc305270496397ff
fetch bluefin        https://github.com/ublue-os/bluefin.git        13efd26e908c1dc956a731baf365966a8d5e57a3
fetch akmods         https://github.com/ublue-os/akmods.git         d3958bd6c1a8301d74d46e3b1ed6d9164a434d2d
fetch t2-atomic      https://github.com/kansei-os/t2-atomic.git    d8b3ee7d54664b018ba4416708e04f314acf0bb9

echo "read-only: never edit these trees, and never write to kaiT2en/KaiT2en-Fedora."
