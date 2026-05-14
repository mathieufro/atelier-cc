#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/topology.sh"
require_jq
type="${1:-}"
[ -n "$type" ] || die "usage: list-stages.sh <topology>"
wsp="$(find_workspace_root)"
topo="$(topology_load "$wsp" "$type")" || die "topology not found: $type"
printf '%s' "$topo" | jq -r '.stages[] | "\(.name)\t\(.skill // "")\t\(.mode // "")"'
