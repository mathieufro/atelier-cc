#!/usr/bin/env bash
# Topology loader: project-local overrides shadow plugin defaults by name.

_topology_plugin_root() {
  if [ -n "${ATELIER_CC_ROOT:-}" ]; then
    printf '%s\n' "$ATELIER_CC_ROOT"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
  else
    local self; self="${BASH_SOURCE[0]}"
    printf '%s\n' "$(cd "$(dirname "$self")/.." && pwd)"
  fi
}

topology_load() {
  local wsp="$1" name="$2"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid topology name: $name"
  local project="$wsp/.atelier/topologies/$name.json"
  local plugin; plugin="$(_topology_plugin_root)/topologies/$name.json"
  local path=""
  if [ -f "$project" ]; then path="$project"
  elif [ -f "$plugin" ]; then path="$plugin"
  else die "topology not found: $name"
  fi
  jq -e . "$path" >/dev/null 2>&1 || die "topology JSON invalid: $path"
  local valid
  valid="$(jq -r '
    if (.stages | type) != "array" then "stages_not_array"
    elif (.stages | length) == 0 then "stages_empty"
    elif any(.stages[]; (.name // "") == "" or (.mode // "") == "" or (.skill // "") == "") then "stage_missing_required_field"
    elif any(.stages[]; .mode != "interactive" and .mode != "autonomous") then "stage_bad_mode"
    else
      ((.stages | map(.name)) as $names
       | (.stages | map(select(.name | startswith("review_")) | .name | sub("^review_"; "fix_"))) as $synthesized
       | if any($synthesized[]; . as $f | ($names | index($f))) then "fix_name_collision" else "ok" end)
    end' "$path")"
  case "$valid" in
    ok) ;;
    stages_not_array) die "topology $path: .stages must be an array" ;;
    stages_empty) die "topology $path: .stages must be non-empty" ;;
    stage_missing_required_field) die "topology $path: every stage requires name, mode, skill" ;;
    stage_bad_mode) die "topology $path: stage mode must be 'interactive' or 'autonomous'" ;;
    fix_name_collision) die "topology $path: name collision — explicit fix_* stage collides with the synthesized fix_<review_*> name; rename to avoid conflict" ;;
    *) die "topology $path: unknown validation error ($valid)" ;;
  esac
  cat "$path"
}

topology_list() {
  local wsp="$1"
  local plugin_dir; plugin_dir="$(_topology_plugin_root)/topologies"
  local project_dir="$wsp/.atelier/topologies"
  {
    if [ -d "$project_dir" ]; then
      for f in "$project_dir"/*.json; do
        [ -f "$f" ] || continue
        jq -r '"\(.name)\t\(.description)"' "$f" 2>/dev/null
      done
    fi
    if [ -d "$plugin_dir" ]; then
      for f in "$plugin_dir"/*.json; do
        [ -f "$f" ] || continue
        jq -r '"\(.name)\t\(.description)"' "$f" 2>/dev/null
      done
    fi
  } | awk -F'\t' '!seen[$1]++ { print }'
}

topology_stage() {
  local topo="$1" name="$2"
  printf '%s' "$topo" | jq -e --arg n "$name" '.stages[] | select(.name == $n)'
}

topology_first_stage() {
  printf '%s' "$1" | jq -e '.stages[0]'
}

topology_next_after() {
  local topo="$1" current="$2"
  printf '%s' "$topo" | jq -c --arg c "$current" '
    (.stages | map(.name) | index($c)) as $i
    | if ($i != null and ($i + 1) < (.stages|length))
      then .stages[$i + 1]
      else empty
      end'
}
