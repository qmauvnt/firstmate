#!/usr/bin/env bash
# Credentialed Kiro CLI worker guard. Opt in with FM_KIRO_SIGNALS_LIVE=1.
# FM_KIRO_MODEL chooses a model from `kiro-cli chat --list-models`
# (default claude-haiku-4.5, a low rate multiplier).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. All later steering,
# interrupt and exit operations use the real Firstmate control plane. The pane
# keeps the real HOME because Kiro's login lives in its per-user data store,
# so the turn markers read here are the real host-wide vendor surface.
# The worktree carries a project Claude Code hook that must never fire.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_KIRO_SIGNALS_LIVE kiro-cli tmux jq
KIRO_BIN=$(command -v kiro-cli)
REAL_TMUX=$(command -v tmux)
VERSION=$(kiro-cli --version 2>/dev/null)
MODEL=${FM_KIRO_MODEL:-claude-haiku-4.5}
if ! kiro-cli chat --list-models --format json 2>/dev/null | jq -e --arg m "$MODEL" '.models[] | select(.model_id == $m)' >/dev/null; then
  printf 'skip: live: %s is signed out or does not list model %s; run kiro-cli login\n' "$VERSION" "$MODEL"
  exit 0
fi
LAB=$(mktemp -d "${TMPDIR:-/tmp}/kr.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
# Unix-domain socket paths have a small OS byte limit. Keep the socket name
# relative when the isolated lab is under this checkout's working directory.
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The spawn makes its git strip-hook directory read-only.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=kiro-live
fm_test_spawn_home "$H" kiro
fm_git_worktree "$PROJ" "$WT" kiro-live
mkdir -p "$LAB/bin"
git -C "$WT" config user.name 'Kiro Live Guard'
git -C "$WT" config user.email kiro-live-guard@example.invalid
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: run the shell command 'sleep 8', then compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$KIRO_BIN" "$fakebin/kiro-cli"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness kiro --model "$MODEL" --effort low > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
# Written after the spawn, which refuses a dirty worktree, and before launch.
mkdir -p "$WT/.claude"
jq -n --arg cmd "cat >> '$LAB/claude-hooks.jsonl'" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}], UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}], Stop: [{hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$WT/.claude/settings.json"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 120 -y 40 -c "$WT" \
  "env -u CLAUDECODE /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
screen_text() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "$TARGET"; }
verdict() { fm_busy_classify tmux "$TARGET" kiro "$ID" "$H/state"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}"
}
wait_verdict() {  # <verdict> <what>
  local i
  for i in $(seq 1 240); do
    [ "$(verdict)" = "$1" ] && return 0
    sleep 0.5
  done
  fail "$2 (last verdict: $(verdict))"
}
# The brief's first turn must be observed busy from Kiro's own turn marker,
# with the rendered working row agreeing, before it settles.
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(verdict)" = 'busy kiro-turn-marker' ] && screen_text | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match kiro; then seen_busy=1; break; fi
  sleep 0.25
done
[ "$seen_busy" = 1 ] || fail "the launch brief turn never read busy from its turn marker: $(screen_text | tail -5)"
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = kiro ] || fail "tool ancestry/marker did not identify Kiro: $(cat "$WT/harness.txt")"
wait_verdict 'idle kiro-turn-marker' 'the finished turn did not settle to idle'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real Kiro process not classified alive'
pass "$VERSION: spawn brief, model, autonomy, identity, and turn-marker busy then idle"
git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by|generated with' "$LAB/commit.txt" \
  || fail "worker commit carries AI attribution: $(cat "$LAB/commit.txt")"
[ ! -e "$LAB/claude-hooks.jsonl" ] \
  || fail "the worker ran project Claude Code hooks: $(head -c 300 "$LAB/claude-hooks.jsonl")"
pass "$VERSION: no Claude Code hook ran and the worker commit carries no attribution"
# The full styled screen, not an invented fixture, must be safe to type into.
composer=$(fm_backend_composer_state tmux "$TARGET")
[ "$composer" = empty ] || fail "idle composer was $composer"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_verdict 'idle kiro-turn-marker' 'the steered turn did not settle to idle'
pass "$VERSION: real fm-send doorbell read and acknowledged"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
sleep 1.5
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'idle interrupt stopped the agent'
[ "$(verdict)" = 'idle kiro-turn-marker' ] || fail "idle interrupt disturbed the idle composer: $(verdict)"
pass "$VERSION: idle interrupt is harmless"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(verdict)" = 'busy kiro-turn-marker' ] && screen_text | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match kiro; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'no semantic and rendered busy during interrupt probe'
sleep 3
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
for _ in $(seq 1 30); do
  [ "$(verdict)" = 'idle kiro-turn-marker' ] && break
  sleep 0.5
done
[ "$(verdict)" = 'idle kiro-turn-marker' ] || fail "Escape did not end the turn within 15s: $(verdict)"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'interrupt stopped the agent'
pass "$VERSION: one Escape cancels the turn, clears its marker, and keeps the agent"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'quit did not return to shell'
session=$(screen_text | sed -n 's/.*--resume-id \([0-9a-f-]*\).*/\1/p' | tail -1)
[ -n "$session" ] || fail "exit printed no resume id: $(screen_text | tail -5)"
# Native resume is a vendor fact, not a new fm-control verb.
printf '%s\n' "exec env -u CLAUDECODE '$KIRO_BIN' chat --trust-all-tools --model '$MODEL' --resume-id '$session' 'Runtime resume probe: write the product of 17 and 29 into resumed.txt, then stop.'" > "$LAB/resume.sh"
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" -l "sh '$LAB/resume.sh'"
sleep 0.5
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" Enter
wait_file "$WT/resumed.txt"
[ "$(tr -d '[:space:]' < "$WT/resumed.txt")" = 493 ] || fail 'resume prompt not processed'
wait_verdict 'idle kiro-turn-marker' 'the resumed turn did not settle to idle'
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "resumed exit failed: $(cat "$LAB/exit.log")"
pass "$VERSION: /quit and native --resume-id session resume"
