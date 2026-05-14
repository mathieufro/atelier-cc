#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ATELIER_SKILLS_SRC:-$ROOT/../atelier/skills}"
DST="$ROOT/skills"
[ -d "$SRC" ] || { echo "atelier-cc: source skills not found: $SRC (expected sibling atelier/ submodule)" >&2; exit 1; }
mkdir -p "$DST"
# Skills from upstream atelier/ that don't apply to atelier-cc.
EXCLUDE=("benchmarking" "ralph-loop-help" "responding")
is_excluded() {
  local name="$1"
  for e in "${EXCLUDE[@]}"; do
    [ "$name" = "$e" ] && return 0
  done
  return 1
}
# Remove skill dirs in DST that no longer exist in SRC or are excluded.
for d in "$DST"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  if ! [ -d "$SRC/$name" ] || is_excluded "$name"; then
    rm -rf "$d"
  fi
done
# Copy SKILL.md from each skill dir in SRC into DST (overwrites), skipping excluded.
for d in "$SRC"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  is_excluded "$name" && continue
  if [ -f "$d/SKILL.md" ]; then
    mkdir -p "$DST/$name"
    cp "$d/SKILL.md" "$DST/$name/SKILL.md"
  fi
done
