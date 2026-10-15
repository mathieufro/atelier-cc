#!/usr/bin/env bats
# Host contract (S37, S39): an embedding host (e.g. Liaison) sets ATELIER_*
# env names to run Atelier unattended. With ATELIER_AUTONOMY=autonomous the
# ask-guard denies every AskUserQuestion; without the env every hook prints
# exactly what it printed at the commit named in fixtures/golden/SOURCE.

setup() {
  unset ATELIER_AUTONOMY ATELIER_HOST ATELIER_HOST_DONE_TOOL ATELIER_HOST_NEEDS_YOU_TOOL ATELIER_HOST_FINISH
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/ask-guard.sh"
  GOLDEN="$BATS_TEST_DIRNAME/fixtures/golden"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status> <awaiting-json>
  printf '{"id":"p1","rung":2,"sourceSessionId":"%s","status":"%s","awaiting":%s,"phase":"brainstorm"}\n' "$1" "$2" "$3" > "$SP"
}
input() { printf '{"session_id":"sess-A","cwd":"%s","tool_name":"AskUserQuestion"}' "$TMP"; }

@test "S37: autonomous denies AskUserQuestion with awaiting:user" {
  mkstate sess-A running '"user"'
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
  [[ "$output" == *"Atelier host contract"* ]]
  [[ "$output" == *"brief.md"* ]]
}

@test "S37: autonomous denies with no pipeline at all" {
  rm -rf "$TMP/.atelier"
  mkdir -p "$TMP/.git"
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
  # also before any session id is known
  run bash -c 'printf "{}" | ATELIER_AUTONOMY=autonomous bash "$1"' _ "$HOOK"
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
}

@test "S37: the deny reason names ATELIER_HOST_NEEDS_YOU_TOOL when set, and omits a malformed value" {
  mkstate sess-A running '"user"'
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL=mcp__liaison__sessions_needs_you bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"call mcp__liaison__sessions_needs_you with the reason"* ]]

  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL="rm -rf /; x" bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
  [[ "$reason" != *"rm -rf"* ]]
  [[ "$reason" == *'set awaiting:"user" with the reason in failure.reason'* ]]
  [[ "$reason" != *"call "* ]]

  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" != *"call "* ]]
  [[ "$reason" == *'set awaiting:"user" with the reason in failure.reason'* ]]
}

@test "S37: ATELIER_AUTONOMY=guided or any other value changes nothing" {
  mkstate sess-A running '"user"'
  for v in guided Autonomous autonomous-x "" " autonomous"; do
    run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY="$3" bash "$2"' _ "$(input)" "$HOOK" "$v"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  mkstate sess-A running null
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=guided bash "$2"' _ "$(input)" "$HOOK"
  [[ "$output" == *"full-autonomy contract"* ]]
  [[ "$output" != *"host contract"* ]]
}

@test "S39: without the env, ask-guard, stop, post-tool-use and session-start print exactly the golden output for each fixture state and source" {
  [ -f "$GOLDEN/SOURCE" ]
  [ "$(ls "$GOLDEN/out" | wc -l | tr -d ' ')" -eq 48 ]
  # The corpus covers a legitimate complete and session-start startup/resume (F7).
  [ -f "$GOLDEN/out/stop.complete-handoff.out" ]
  [ -f "$GOLDEN/out/session-start@startup.running-null.out" ]
  [ -f "$GOLDEN/out/session-start@resume.running-null.out" ]
  bash "$GOLDEN/run-hooks.sh" "$ROOT" "$TMP/out"
  run diff -r "$GOLDEN/out" "$TMP/out"
  [ "$status" -eq 0 ]
}

# --- The command file (AC-3). Hooks never run below Open in a host, so the
# contract is carried by commands/atelier.md prose. Without the env the prose
# must read exactly as at the commit in fixtures/golden/SOURCE: every host-mode
# addition is either §0b or a paragraph naming an ATELIER_* variable, plus the
# five fields appended to Frame's echo.

CMD_ECHO_FIELDS='|${ATELIER_AUTONOMY:-}|${ATELIER_HOST:-}|${ATELIER_HOST_DONE_TOOL:-}|${ATELIER_HOST_NEEDS_YOU_TOOL:-}|${ATELIER_HOST_FINISH:-}'

# Print <file> with the host-mode prose removed: the five echo fields, the
# "## 0b." section, and every blank-line-delimited paragraph naming a host
# variable (ATELIER_AUTONOMY or ATELIER_HOST*; other ATELIER_ names such as
# ATELIER_PLAYWRIGHT_CORE predate the host contract and stay).
strip_host() {
  awk -v fields="$CMD_ECHO_FIELDS" '
    function flush() {
      if (n == 0) return
      if (para ~ /^## /) skip = (para ~ /^## 0b\./)
      if (!skip && para !~ /ATELIER_(AUTONOMY|HOST)/) printf "%s", buf
      n = 0; para = ""; buf = ""
    }
    {
      i = index($0, fields)
      if (i) $0 = substr($0, 1, i - 1) substr($0, i + length(fields))
      buf = buf $0 "\n"
      if ($0 == "") { flush(); next }
      para = (n ? para "\n" : "") $0; n++
    }
    END { flush() }
  ' "$1"
}
# The §0b section of atelier.md.
host_section() { awk '/^## 0b\./{on=1; print; next} on && /^## /{exit} on' "$ROOT/commands/atelier.md"; }
# The §4 paragraph that finishes for the host.
host_finish() {
  awk 'BEGIN{RS=""} /^## 4\./{s4=1} s4 && /ATELIER_HOST_FINISH/ && /ATELIER_HOST_DONE_TOOL/{print; exit}' "$ROOT/commands/atelier.md"
}

@test "S37: Frame's echo line names all five ATELIER_* variables" {
  line="$(grep -E '^1\. `Bash`: `echo "\$CLAUDE_CODE_SESSION_ID\|' "$ROOT/commands/atelier.md")"
  [ -n "$line" ]
  for v in ATELIER_AUTONOMY ATELIER_HOST ATELIER_HOST_DONE_TOOL ATELIER_HOST_NEEDS_YOU_TOOL ATELIER_HOST_FINISH; do
    [[ "$line" == *"|\${$v:-}"* ]]
  done
  [[ "$line" == *"\$(openssl rand -hex 2)${CMD_ECHO_FIELDS}\""* ]]
}

@test "S37: atelier.md documents boards[] with title and url" {
  sec="$(host_section)"
  [[ "$sec" == *'boards: [{title, url}]'* ]]
  [[ "$sec" == *'https:'* ]]
}

@test "S37: §0b states the autonomous Brainstorm, the blocker path and the Liaison fan-out limits" {
  sec="$(host_section)"
  [[ "$sec" == *'Applies only when'* ]]
  [[ "$sec" == *'`ATELIER_AUTONOMY=autonomous`'* ]]
  [[ "$sec" == *'Assumptions:'* ]]
  [[ "$sec" == *'brief.md'* ]]
  [[ "$sec" == *'`awaiting` never becomes `"user"`'* ]]
  [[ "$sec" == *'`ATELIER_HOST_NEEDS_YOU_TOOL` is set, call that tool with the reason'* ]]
  [[ "$sec" == *'set `awaiting:"user"` with the reason in `failure.reason`'* ]]
  [[ "$sec" == *'`ATELIER_HOST=liaison`'* ]]
  for t in Workflow Monitor SendMessage TaskStop; do [[ "$sec" == *"\`$t\`"* ]]; done
  [[ "$sec" == *'at most 4 at once'* ]]
  # Brainstorm (§3) and the brainstorming skill point at §0b.
  grep -q 'ATELIER_AUTONOMY=autonomous.*§0b' "$ROOT/commands/atelier.md"
  grep -q 'ATELIER_AUTONOMY=autonomous.*§0b' "$ROOT/skills/brainstorming/SKILL.md"
}

@test "S39: with every ATELIER_* name removed from atelier.md's host-mode section, the remaining text equals the 8c4d96a file plus the one Frame field addition" {
  grep -q '^## 0b\. Host mode' "$ROOT/commands/atelier.md"
  [ "$(strip_host "$ROOT/commands/atelier.md" | grep -c . )" -lt "$(grep -c . "$ROOT/commands/atelier.md")" ]
  run diff <(strip_host "$ROOT/commands/atelier.md") "$GOLDEN/atelier.md@8c4d96a"
  [ "$status" -eq 0 ]
}

@test "S39: the brainstorming skill without its host pointer equals 8c4d96a, and no other command or skill names a host variable" {
  grep -q 'ATELIER_' "$ROOT/skills/brainstorming/SKILL.md"
  run diff <(strip_host "$ROOT/skills/brainstorming/SKILL.md") "$GOLDEN/brainstorming-SKILL.md@8c4d96a"
  [ "$status" -eq 0 ]
  run bash -c 'grep -rlE "ATELIER_(AUTONOMY|HOST)" "$@" | sort' _ "$ROOT/commands" "$ROOT/skills" "$ROOT/docs"
  [ "$output" = "$(printf '%s\n%s\n%s' "$ROOT/commands/atelier.md" "$ROOT/skills/boards/SKILL.md" "$ROOT/skills/brainstorming/SKILL.md")" ]
}

@test "S57: §4-host stages with the ':!.atelier' exclusion and never passes handoff.md as the PR body" {
  fin="$(host_finish)"
  [ -n "$fin" ]
  [[ "$fin" == *"git add -A -- . ':!.atelier'"* ]]
  [[ "$fin" == *'--body-file <a new file outside .atelier>'* ]]
  [[ "$fin" == *'never `handoff.md` itself'* ]]
  [[ "$fin" != *'--body-file handoff.md'* ]]
  [[ "$fin" != *'--body-file .atelier'* ]]
  # A40: never a commit on the default or a protected branch.
  [[ "$fin" == *'`git switch -c atelier/<id>` (no start point, no other flag)'* ]]
  [[ "$fin" == *'git worktree add .atelier/worktrees/<id> -b atelier/<id> "$C"`'* ]]
  for b in main master trunk develop production; do [[ "$fin" == *"\`$b\`"* ]]; done
  # D32: a failed push or PR is never complete; the done tool carries summary and prUrl.
  [[ "$fin" == *'If the push or the PR fails, call the tool named by `ATELIER_HOST_NEEDS_YOU_TOOL` with the error'* ]]
  [[ "$fin" == *'never set `status:"complete"` without the PR'* ]]
  [[ "$fin" == *'`summary` = the handoff'"'"'s first line and `prUrl` = the PR'"'"'s URL'* ]]
  for m in '`ATELIER_HOST_FINISH=pr`' '`ATELIER_HOST_FINISH=commit`' '`none`'; do [[ "$fin" == *"$m"* ]]; done
}

@test "S57: §4-host states the title/body publication rule" {
  fin="$(host_finish)"
  [[ "$fin" == *'The title and body follow the same rules as the code: no absolute or home-relative local paths, no session ids, no names the repository'"'"'s checks forbid'* ]]
  [[ "$fin" == *'the handoff'"'"'s summary written for the PR'* ]]
}

@test "F1: every needs-you path sets awaiting:user and writes state.json before ending the turn, and the Stop hook allows that state" {
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    before="${line%%end the turn*}"
    [[ "$before" == *'set `awaiting:"user"`'* ]]
    [[ "$before" == *'write `state.json`'* ]]
  done < <(grep 'ATELIER_HOST_NEEDS_YOU_TOOL' "$ROOT/commands/atelier.md" | grep 'end the turn')
  [ "$n" -eq 2 ]
  # The state that prose prescribes: running, awaiting "user", reason in failure.
  printf '{"id":"p1","rung":2,"sourceSessionId":"sess-A","status":"running","awaiting":"user","phase":"execute","failure":{"reason":"needs a credential"}}\n' > "$SP"
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL=mcp__liaison_session__needs_you bash "$2"' _ "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}" "$ROOT/hooks/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Calling the tool alone leaves running/null, which the Stop hook blocks.
  mkstate sess-A running null
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}" "$ROOT/hooks/stop.sh"
  [[ "$output" == *'"block"'* ]]
  # The ask-guard's deny reason prescribes the same write after the tool call.
  mkstate sess-A running null
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL=mcp__liaison_session__needs_you bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *'call mcp__liaison_session__needs_you with the reason, then set awaiting:"user" with the reason in failure.reason, write state.json and end the turn'* ]]
}

@test "F2: the protected-branch fallback carries the uncommitted change onto atelier/<id> and leaves the checkout untouched" {
  cmd="$(host_finish | sed -n 's/.*if the host refuses that, [^`]*`\([^`]*\)`.*/\1/p')"
  [ -n "$cmd" ]
  [[ "$cmd" != *stash* && "$cmd" != *reset* && "$cmd" != *checkout* ]]
  cmd="${cmd//<id>/p9}"; cmd="${cmd//<title>/Fallback}"
  R="$TMP/repo"; mkdir -p "$R"; cd "$R"
  git init -q -b main .
  git config user.email t@example.com; git config user.name T
  printf 'a\n' > kept; printf 'b\n' > gone; git add -A; git commit -qm base
  base="$(git rev-parse HEAD)"
  printf 'a2\n' > kept; rm gone; printf 'new\n' > added
  mkdir -p .atelier/pipelines/p9; printf '{}' > .atelier/pipelines/p9/state.json
  before="$(git status --porcelain)"
  run bash -c "$cmd"
  [ "$status" -eq 0 ]
  # The current branch and checkout are as they were.
  [ "$(git rev-parse HEAD)" = "$base" ]
  [ "$(git symbolic-ref --short HEAD)" = main ]
  [ "$(git status --porcelain -- . ':!.atelier')" = "$(printf '%s\n' "$before" | grep -v '\.atelier')" ]
  # The new branch holds the whole change, and nothing from .atelier.
  W=".atelier/worktrees/p9"
  [ "$(git -C "$W" symbolic-ref --short HEAD)" = atelier/p9 ]
  [ "$(git rev-parse atelier/p9~1)" = "$base" ]
  [ "$(cat "$W/kept")" = a2 ]
  [ "$(cat "$W/added")" = new ]
  [ ! -e "$W/gone" ]
  [ -z "$(git ls-tree -r --name-only atelier/p9 -- .atelier)" ]
  [ -z "$(git -C "$W" status --porcelain)" ]
}

@test "F3: host mode triggers on recognised values only; ATELIER_HOST=0.0.0.0 changes nothing" {
  sec="$(host_section)"
  [[ "$sec" != *'non-empty host field'* ]]
  [[ "$sec" == *'shows a recognised host value, never on a value merely being present'* ]]
  [[ "$sec" == *'`ATELIER_HOST=liaison`, `ATELIER_HOST_FINISH` one of `pr`, `commit`, `none`'* ]]
  [[ "$sec" == *'Any other value counts as unset: `ATELIER_HOST=0.0.0.0`'* ]]
  [[ "$(host_finish)" == *'holds a value §0b recognises'* ]]
  # The hooks: every golden is unchanged with ATELIER_HOST=0.0.0.0 exported.
  bash "$GOLDEN/run-hooks.sh" "$ROOT" "$TMP/out" ATELIER_HOST=0.0.0.0
  run diff -r "$GOLDEN/out" "$TMP/out"
  [ "$status" -eq 0 ]
}

@test "F4: under autonomy a gate file is written for the owner with VERDICT/SIGNED blank, and the boards skill points at §0b" {
  sec="$(host_section)"
  [[ "$sec" == *'a gate is still written as a gate file for the owner (`boards` skill), with `VERDICT:` and `SIGNED:` left blank, since an autonomous run never writes them'* ]]
  [[ "$sec" == *'proceeds on the gate'"'"'s recommended option and records that choice in the brief'"'"'s `Assumptions:`'* ]]
  [[ "$sec" == *'Under autonomy a gate is never a genuine blocker.'* ]]
  [[ "$sec" != *'a gate takes its recommended default, recorded in the gate file'* ]]
  grep -q 'ATELIER_AUTONOMY=autonomous.*§0b.*VERDICT and SIGNED blank.*never writes them' "$ROOT/skills/boards/SKILL.md"
  # Without its pointer, the boards skill reads exactly as at 8c4d96a.
  run diff <(strip_host "$ROOT/skills/boards/SKILL.md") "$GOLDEN/boards-SKILL.md@8c4d96a"
  [ "$status" -eq 0 ]
}

@test "F5: the pushed branch is checked against the default branch and protected names case-folded, and never force-pushed" {
  fin="$(host_finish)"
  for b in staging 'release/*'; do [[ "$fin" == *"\`$b\`"* ]]; done
  [[ "$fin" == *'never the default branch (`git symbolic-ref --short refs/remotes/origin/HEAD`, without its `origin/`) nor a protected name, both compared case-folded (`Main` is `main`), whichever way it was obtained'* ]]
  [[ "$fin" == *'the only push is `git push origin <branch>` of that branch, never forced'* ]]
  [[ "$fin" != *'--force'* && "$fin" != *'push -f'* ]]
}

@test "F6: both tool names are used only when they match the mcp__ pattern, and a field containing | voids the host fields" {
  sec="$(host_section)"
  [[ "$sec" == *'`ATELIER_HOST_DONE_TOOL` or `ATELIER_HOST_NEEDS_YOU_TOOL` that matches `^mcp__[A-Za-z0-9_]+__[A-Za-z0-9_]+$` (a tool name that does not is never called)'* ]]
  [[ "$sec" == *'The echo has eight `|`-separated fields; if it shows more, a value contains `|`, and every host field counts as unset.'* ]]
  # The prose pattern is the one the ask-guard enforces.
  grep -qF '^mcp__[A-Za-z0-9_]+__[A-Za-z0-9_]+$' "$ROOT/hooks/ask-guard.sh"
  # And the echo really has eight fields.
  line="$(grep -E '^1\. `Bash`: `echo "\$CLAUDE_CODE_SESSION_ID\|' "$ROOT/commands/atelier.md")"
  body="${line#*echo \"}"; body="${body%%\"*}"
  [ "$(printf '%s' "$body" | awk -F'|' '{print NF}')" -eq 8 ]
}

@test "F7: with all five host variables set, stop, post-tool-use and session-start still print exactly the goldens" {
  bash "$GOLDEN/run-hooks.sh" "$ROOT" "$TMP/out" ATELIER_AUTONOMY=autonomous ATELIER_HOST=liaison \
    ATELIER_HOST_DONE_TOOL=mcp__liaison_session__mark_done ATELIER_HOST_NEEDS_YOU_TOOL=mcp__liaison_session__needs_you ATELIER_HOST_FINISH=pr
  [ "$(ls "$TMP/out" | grep -vc '^ask-guard\.')" -eq 40 ]
  run diff -r -x 'ask-guard.*' "$GOLDEN/out" "$TMP/out"
  [ "$status" -eq 0 ]
}

@test "F8: every command, skill, doc, script, hook and lib file the host contract does not touch is byte-identical to 8c4d96a" {
  manifest="$GOLDEN/unchanged@8c4d96a"
  [ "$(wc -l < "$manifest" | tr -d ' ')" -ge 13 ]
  while read -r blob path; do
    [ "$(git hash-object "$ROOT/$path")" = "$blob" ] || { echo "changed since 8c4d96a: $path"; return 1; }
  done < "$manifest"
  # No file was added either: each one is pinned or one of the five the contract edits.
  allowed="$(printf '%s\n' commands/atelier.md hooks/ask-guard.sh lib/common.sh skills/boards/SKILL.md skills/brainstorming/SKILL.md; awk '{print $2}' "$manifest")"
  run bash -c 'cd "$1" && find commands skills docs scripts hooks lib -type f | sort' _ "$ROOT"
  [ "$output" = "$(printf '%s\n' "$allowed" | sort)" ]
}

@test "F10: with no owned pipeline the autonomous deny reason names neither brief.md nor state.json" {
  for setup_case in none foreign; do
    rm -rf "$TMP/.atelier" "$TMP/.git"
    if [ "$setup_case" = none ]; then mkdir -p "$TMP/.git"; else mkdir -p "$TMP/.atelier/pipelines/p1"; mkstate sess-B running null; fi
    run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
    reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
    [[ "$reason" == *'Decide with a sensible default and say so in your reply'* ]]
    [[ "$reason" == *'say what blocks you in your reply and end the turn'* ]]
    [[ "$reason" != *brief.md* && "$reason" != *state.json* && "$reason" != *awaiting* ]]
    run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL=mcp__liaison_session__needs_you bash "$2"' _ "$(input)" "$HOOK"
    reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
    [[ "$reason" == *'call mcp__liaison_session__needs_you with the reason.'* ]]
    [[ "$reason" != *brief.md* && "$reason" != *awaiting* ]]
  done
  # With empty input (no session id) the hook still denies, with the short reason.
  run bash -c 'printf "{}" | ATELIER_AUTONOMY=autonomous bash "$1"' _ "$HOOK"
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')" != *brief.md* ]]
}
