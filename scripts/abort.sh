#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq
pid="${1:-}"
[ -n "$pid" ] || die "usage: abort.sh <pipeline-id>"
wsp="$(find_workspace_root)"
ps_update "$wsp" "$pid" \
  '.stages |= (if (length > 0 and .[-1].status == "running") then
     (.[:-1] + [.[-1] + {status:"idle", interrupted:true, error:"aborted by user"}])
   else . end)'
ps_set_status "$wsp" "$pid" "idle" "aborted by user"
