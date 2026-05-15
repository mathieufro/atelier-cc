#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ATELIER_SKILLS_SRC:-$ROOT/../atelier/skills}"
DST="$ROOT/skills"
[ -d "$SRC" ] || { echo "atelier-cc: source skills not found: $SRC (expected sibling atelier/ submodule)" >&2; exit 1; }
mkdir -p "$DST"
# Skills from upstream atelier/ that don't apply to atelier-cc.
EXCLUDE=("benchmarking" "ralph-loop-help" "responding")
# Skills native to atelier-cc — preserved in DST even when absent from SRC.
NATIVE=("create-pipeline")
is_excluded() {
  local name="$1"
  for e in "${EXCLUDE[@]}"; do
    [ "$name" = "$e" ] && return 0
  done
  return 1
}
is_native() {
  local name="$1"
  for e in "${NATIVE[@]}"; do
    [ "$name" = "$e" ] && return 0
  done
  return 1
}
# Remove skill dirs in DST that no longer exist in SRC or are excluded,
# unless they are atelier-cc-native skills.
for d in "$DST"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  is_native "$name" && continue
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
