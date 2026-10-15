#!/usr/bin/env bash
# Run four hooks of a plugin tree over the fixture corpus and write one
# normalised output file per (hook, state) pair.
#
#   run-hooks.sh <plugin-root> <out-dir>
#
# Used twice: once against a detached worktree of the commit named in SOURCE to
# produce the committed goldens (out/), and by host-contract.bats against the
# current tree to compare with them. Every ATELIER_* name is unset first: this
# is the "no host env" baseline. Paths are normalised so the files are the same
# on any machine: the workspace temp dir becomes @ROOT@, the plugin root
# becomes @PLUGIN@. Each file ends with the hook's exit status.
set -uo pipefail
unset ATELIER_AUTONOMY ATELIER_HOST ATELIER_HOST_DONE_TOOL ATELIER_HOST_NEEDS_YOU_TOOL ATELIER_HOST_FINISH
export HEARTBEAT_EVERY=1

plugin="$(cd "$1" && pwd)"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out"

states=(no-pipeline)
for f in "$here"/states/*.json; do states+=("$(basename "$f" .json)"); done

for hook in ask-guard stop post-tool-use session-start; do
  for st in "${states[@]}"; do
    ws="$(mktemp -d)"
    ws_real="$(cd "$ws" && pwd -P)"
    if [ "$st" = no-pipeline ]; then
      mkdir -p "$ws/.git"
    else
      mkdir -p "$ws/.atelier/pipelines/p1"
      cp "$here/states/$st.json" "$ws/.atelier/pipelines/p1/state.json"
    fi
    input="{\"session_id\":\"sess-A\",\"cwd\":\"$ws\",\"source\":\"compact\",\"tool_name\":\"AskUserQuestion\"}"
    res="$(printf '%s' "$input" | bash "$plugin/hooks/$hook.sh" 2>&1; printf '\nexit=%s' "$?")"
    res="${res//"$ws_real"/@ROOT@}"
    res="${res//"$ws"/@ROOT@}"
    res="${res//"$plugin"/@PLUGIN@}"
    printf '%s\n' "$res" > "$out/$hook.$st.out"
    rm -rf "$ws"
  done
done
