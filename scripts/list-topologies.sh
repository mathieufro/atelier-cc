#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/topology.sh"
require_jq
wsp="$(find_workspace_root)"
topology_list "$wsp"
