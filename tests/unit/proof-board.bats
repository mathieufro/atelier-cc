#!/usr/bin/env bats
# The board generator: the owner's note field and buttons must stay usable
# whatever the card text, and a decision board must not read like a proof board.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GEN="$ROOT/scripts/proof-board.py"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

long_label="An option label long enough to fill the whole width of a desktop card on its own, and then some more words"

mkboard() { # <dir> <kinds...>
  local d="$1"; shift
  mkdir -p "$d"
  python3 - "$d" "$long_label" "$@" <<'PY'
import json, sys
d, label, kinds = sys.argv[1], sys.argv[2], sys.argv[3:]
cards = []
for i, k in enumerate(kinds):
    c = {"id": f"c{i}", "kind": k, "group": "G", "title": f"Card {i}", "what": "What it is about."}
    if k == "decision":
        c["options"] = [{"id": x, "label": label, "why": "Because."} for x in "ABC"]
    else:
        c.update(where="here", check="it works", gate="t.py:1")
    cards.append(c)
json.dump(cards, open(f"{d}/catalog.json", "w"))
PY
  python3 "$GEN" "$d" >/dev/null
}

@test "the note field sits on its own row under the buttons" {
  mkboard "$TMP/b" decision check
  grep -q '\.verdict-row{display:grid;grid-template-columns:minmax(0,1fr);' "$TMP/b/site/index.html"
  ! grep -q 'grid-template-columns:auto 1fr auto' "$TMP/b/site/index.html"
}

@test "decision options stack full width so a long label never squeezes the note" {
  mkboard "$TMP/b" decision
  grep -q '\.card\[data-kind="decision"\] \.btns{flex-direction:column' "$TMP/b/site/index.html"
}

@test "a decision board shows no empty proof panel and counts choices" {
  mkboard "$TMP/b" decision decision
  ! grep -q 'No proof attached yet' "$TMP/b/site/index.html"
  grep -q 'of 2 chosen' "$TMP/b/site/index.html"
  ! grep -q 'data-f="my:fail"' "$TMP/b/site/index.html"
}

@test "a proof board keeps its verdict counters and filters" {
  mkboard "$TMP/b" check check
  grep -q 'of 2 judged' "$TMP/b/site/index.html"
  grep -q 'data-f="my:human"' "$TMP/b/site/index.html"
  grep -q 'No proof attached yet' "$TMP/b/site/index.html"
}

@test "rendered: the note field spans the card at desktop and phone width" {
  pw="${ATELIER_PLAYWRIGHT_CORE:-}"
  shell="${ATELIER_HEADLESS_SHELL:-}"
  [ -n "$pw" ] && [ -x "$shell" ] || skip "set ATELIER_PLAYWRIGHT_CORE and ATELIER_HEADLESS_SHELL to render"
  mkboard "$TMP/b" decision check
  run node "$ROOT/scripts/board-layout-check.cjs" "$TMP/b/site/index.html"
  echo "$output"
  [ "$status" -eq 0 ]
}
