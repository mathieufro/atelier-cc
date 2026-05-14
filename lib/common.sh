#!/usr/bin/env bash
# Common helpers for atelier-cc bash scripts and hooks.

# Bash version gate. Hooks run automatically and silently swallow failures, so
# a cryptic `declare: -A: invalid option` partway through a hook would be hard
# to diagnose. Fail loudly at source-time instead. macOS ships /bin/bash 3.2;
# users install bash 4+ via Homebrew (`brew install bash`).
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "atelier-cc: bash 4+ required (running ${BASH_VERSION:-unknown}); install via 'brew install bash' on macOS" >&2
  exit 1
fi

die() {
  echo "atelier-cc: $*" >&2
  exit 1
}

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$level" "$*" >&2
}

# Milliseconds since epoch (13 digits). macOS-compatible.
epoch_ms() {
  if date +%s%3N 2>/dev/null | grep -qE '^[0-9]{13}$'; then
    date +%s%3N
  else
    python3 -c 'import time; print(int(time.time()*1000))'
  fi
}

# Cross-process advisory lock via mkdir (atomic on POSIX). Lock path: <path>.lock.
# Stale (>30s) locks are broken automatically. Acquire times out after 5000ms.
ps_lock_acquire() {
  local path="$1"
  local lock="${path}.lock"
  local timeout_ms="${ATELIER_LOCK_TIMEOUT_MS:-5000}"
  local stale_ms="${ATELIER_LOCK_STALE_MS:-30000}"
  local elapsed=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -d "$lock" ]; then
      local mt now age
      mt="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo '')"
      # If stat failed, the lock was just removed (or otherwise inaccessible) —
      # NOT stale. Treating a failed stat as "stale" would incorrectly rmdir
      # a freshly re-acquired lock, breaking serialization. Just retry mkdir.
      if [ -n "$mt" ] && [ "$mt" -gt 0 ]; then
        now="$(date +%s)"
        age=$(((now - mt) * 1000))
        if [ "$age" -gt "$stale_ms" ]; then
          rmdir "$lock" 2>/dev/null || true
          continue
        fi
      fi
    fi
    [ "$elapsed" -ge "$timeout_ms" ] && die "lock timeout: $lock"
    # Sub-second sleep with elapsed accounting that matches real time on each
    # fallback branch — otherwise a `sleep 1` fallback would let elapsed lag
    # real wall time by 20x and effectively ignore $ATELIER_LOCK_TIMEOUT_MS.
    if sleep 0.05 2>/dev/null; then
      elapsed=$((elapsed + 50))
    elif perl -e 'select(undef,undef,undef,0.05)' 2>/dev/null; then
      elapsed=$((elapsed + 50))
    else
      sleep 1
      elapsed=$((elapsed + 1000))
    fi
  done
}

ps_lock_release() { rmdir "${1}.lock" 2>/dev/null || true; }

# Atomic file write: write to tmp, fsync via mv.
atomic_write() {
  local path="$1" content="$2"
  local tmp="${path}.tmp.$$"
  local dir
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$path"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
}

# Extract topic slug from a pipeline id like "2026-05-14-phase-4-2de9" → "phase-4".
# Format: YYYY-MM-DD-<slug>-<4hex-suffix>. Returns the original id if it doesn't
# match (used as the slug fallback). Mirrors extractTopicSlug() in atelier/server.
extract_topic_slug() {
  local pid="$1"
  if [[ "$pid" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)$ ]]; then
    local rest="${BASH_REMATCH[1]}"
    # Strip trailing -<4 alphanumeric chars> suffix.
    if [[ "$rest" =~ ^(.+)-[a-z0-9]{4}$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
    else
      printf '%s' "$rest"
    fi
  else
    printf '%s' "$pid"
  fi
}

# Walk up from CWD to find a directory containing .atelier/ or .git/.
find_workspace_root() {
  local dir="${1:-$PWD}"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.atelier" ] || [ -d "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  printf '%s\n' "$PWD"
}

# Find the (at-most-one) pipeline owned by $session_id with status == running.
# Empty output (exit 0) means "this session has no active pipeline."
# Enforces the one-pipeline-per-session contract: if >1 matches are found,
# emits the most recent (by createdAt) and logs a warning. A hard error would
# break sessions whose state files got duplicated by a buggy script run.
find_owned_pipeline() {
  local wsp="$1" session_id="$2"
  local pdir="$wsp/.atelier/pipelines"
  [ -d "$pdir" ] || return 0
  local matches=() created=()
  for sp in "$pdir"/*/pipeline-state.json; do
    [ -f "$sp" ] || continue
    local owner status
    owner="$(jq -r '.sourceSessionId // empty' "$sp" 2>/dev/null)" || continue
    status="$(jq -r .status "$sp" 2>/dev/null)" || continue
    if [ "$owner" = "$session_id" ] && [ "$status" = "running" ]; then
      matches+=("$(jq -r .id "$sp")")
      created+=("$(jq -r '.createdAt // 0' "$sp")")
    fi
  done
  local n="${#matches[@]}"
  [ "$n" -eq 0 ] && return 0
  if [ "$n" -gt 1 ]; then
    log warn "find_owned_pipeline: session $session_id owns $n running pipelines (expected 1); picking most recent"
    local best_idx=0 i
    for ((i = 1; i < n; i++)); do
      if [ "${created[$i]}" -gt "${created[$best_idx]}" ]; then best_idx=$i; fi
    done
    printf '%s\n' "${matches[$best_idx]}"
  else
    printf '%s\n' "${matches[0]}"
  fi
}
