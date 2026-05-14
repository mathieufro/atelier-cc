#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_SESSION_ID="sess-t"
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'lock')"
  ps_update "$TMP" "$PID" '.type = "feature"'
}
teardown() { rm -rf "$TMP"; }

@test "ps_lock_acquire creates lockdir; ps_lock_release removes it" {
  local sp; sp="$(ps_path "$TMP" "$PID")"
  ps_lock_acquire "$sp"
  [ -d "$sp.lock" ]
  ps_lock_release "$sp"
  [ ! -d "$sp.lock" ]
}

@test "ps_lock_acquire blocks while held, then proceeds when released" {
  local sp; sp="$(ps_path "$TMP" "$PID")"
  ps_lock_acquire "$sp"
  ( ps_lock_acquire "$sp" && echo done > "$TMP/marker" && ps_lock_release "$sp" ) &
  local bg=$!
  sleep 0.2
  [ ! -f "$TMP/marker" ]
  ps_lock_release "$sp"
  wait "$bg"
  [ "$(cat "$TMP/marker")" = "done" ]
}

@test "concurrent ps_update from N writers: no lost writes" {
  for i in $(seq 1 20); do
    ( ps_update "$TMP" "$PID" '.stepCounter = ((.stepCounter // 0) + 1)' ) &
  done
  wait
  [ "$(jq -r .stepCounter "$(ps_path "$TMP" "$PID")")" = "20" ]
}

@test "stale lockdir (>30s old) is broken on acquire" {
  local sp; sp="$(ps_path "$TMP" "$PID")"
  mkdir "$sp.lock"
  touch -t 200001010000.00 "$sp.lock"
  ps_lock_acquire "$sp"
  ps_lock_release "$sp"
}

@test "fresh lock under contention times out with diagnostic" {
  local sp; sp="$(ps_path "$TMP" "$PID")"
  mkdir "$sp.lock"
  ATELIER_LOCK_TIMEOUT_MS=300 run ps_lock_acquire "$sp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock timeout"* ]]
  rmdir "$sp.lock"
}
