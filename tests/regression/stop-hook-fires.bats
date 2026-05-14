#!/usr/bin/env bats

@test "stop.sh accepts the canonical Claude Code Stop hook input shape" {
  input='{"session_id":"abc","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","stop_hook_active":false,"last_assistant_message":"done."}'
  printf '%s' "$input" | "$BATS_TEST_DIRNAME/../../hooks/stop.sh"
}

@test "stop.sh respects stop_hook_active to prevent infinite Stop loops" {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/pid/"
  echo pid > "$TMP/.atelier/active-pipeline"
  echo '{"id":"pid","status":"running","prompt":"x","type":"plan","stages":[]}' > "$TMP/.atelier/pipelines/pid/pipeline-state.json"
  out="$(printf '{"stop_hook_active":true,"cwd":"%s"}' "$TMP" | "$BATS_TEST_DIRNAME/../../hooks/stop.sh")"
  [ -z "$out" ]
  rm -rf "$TMP"
}
