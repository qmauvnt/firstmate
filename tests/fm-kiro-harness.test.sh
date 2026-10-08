#!/usr/bin/env bash
# Portable Kiro CLI worker adapter regression. Vendor facts are refreshed by
# fm-kiro-signals-live-e2e.test.sh; this suite needs no Kiro install or credits.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-kiro-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI KIRO_VERSION KIRO_SESSION_ID

mkdir -p "$TMP_ROOT/names"
for name in kiro-cli kiro-cli-chat kiro kiro-cli-term; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
# The marker is tested before an inherited CLAUDECODE, which kiro does not scrub.
# A fake ps blinds ancestry, so only the marker layer can answer.
mkdir -p "$TMP_ROOT/blind"
cat > "$TMP_ROOT/blind/ps" <<'SH'
#!/bin/sh
case "$*" in
  *ppid=*) printf '1\n' ;;
  *comm=*) printf '/bin/bash\n' ;;
  *) printf 'bash\n' ;;
esac
SH
chmod +x "$TMP_ROOT/blind/ps"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
blind() { env PATH="$TMP_ROOT/blind:$BASE_PATH" "$@" "$HARNESS"; }
out=$(blind KIRO_VERSION=2.27.1 CLAUDECODE=1)
[ "$out" = kiro ] || fail "KIRO_VERSION must beat an inherited CLAUDECODE: $out"
out=$(blind CLAUDECODE=1)
[ "$out" = claude ] || fail "blinded ancestry is not marker-only; the marker case is vacuous: $out"
for name in kiro-cli kiro-cli-chat; do
  # shellcheck disable=SC2016
  out=$("$TMP_ROOT/names/$name" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
  [ "$out" = 'comm kiro' ] || fail "$name ancestry not read as kiro: $out"
  # shellcheck disable=SC2016
  out=$(CLAUDECODE=1 "$TMP_ROOT/names/$name" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = kiro ] || fail "$name ancestry must beat foreign CLAUDECODE: $out"
done
for name in kiro kiro-cli-term; do
  # shellcheck disable=SC2016
  out=$("$TMP_ROOT/names/$name" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
  [ "$out" != 'comm kiro' ] || fail "unrelated $name claimed the adapter"
done
[ "$(fm_agent_process_classify_name /Users/x/.local/bin/kiro-cli)" = agent ] || fail "liveness lost kiro-cli"
[ "$(fm_agent_process_classify_name kiro-cli-chat)" = agent ] || fail "liveness lost kiro-cli-chat"
[ "$(fm_agent_process_classify_name kiro)" = other ] || fail "liveness claims the Kiro desktop app"
[ "$(fm_agent_process_classify_name bun)" = other ] || fail "liveness claims an unrelated Bun process"
pass "Kiro marker and anchored ancestry beat CLAUDECODE; unrelated names stay unclaimed"

[ "$(fm_control_interrupt_key kiro)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat kiro)" = 1 ] || fail 'Kiro interrupts on one press'
[ -z "$(fm_control_interrupt_clear_key kiro)" ] || fail 'Kiro restores no draft to clear'
[ "$(fm_control_exit_command kiro)" = /quit ] || fail 'wrong exit command'
[ "$(fm_control_harness_family kiro)" = kiro ] || fail 'family not exact'
! fm_control_harness_family kiro-desktop >/dev/null || fail 'family claimed a kiro-prefixed command'
fm_control_harness_supports_kind kiro ship || fail 'ship refused'
fm_control_harness_supports_kind kiro scout || fail 'scout refused'
! fm_control_harness_supports_kind kiro secondmate || fail 'secondmate accepted'
pass "worker-only lifecycle capabilities"

# Kiro's composer is a bare `›` row and its status text is gray truecolor that
# survives ghost stripping, so these must read empty on a styled read and an
# unstyled one alike, while typed text stays pending.
for row in '›  ask a question or describe a task ↵' '›  Initializing · type to queue a message' \
  '›  Kiro is working · 12s · Type to steer · Ctrl+S to queue' '›  Kiro is working · 1m 5s · Type to steer · Ctrl+S to queue'; do
  for styled in 1 0; do
    [ "$(fm_composer_classify_content 0 "$row" "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive "$row" 0 "$styled")" = empty ] \
      || fail "rendered-only composer text read as a draft (styled=$styled): $row"
  done
done
[ "$(fm_composer_classify_content 0 '› hello draft' "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive '› hello draft' 0 1)" = pending ] || fail 'typed draft not preserved'
[ "$(fm_composer_classify_content 0 '› ask a question or describe a task' "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive '› ask a question or describe a task' 0 1)" = pending ] \
  || fail 'typed text without the rendered furniture read as the placeholder'
# Cursorless backends (Herdr, Zellij) read the whole screen: Kiro's
# right-aligned `/copy to clipboard` hint row must bound the bare composer
# rather than read as wrapped input.
kiro_screen() {  # <composer-row>
  printf '%s\n' '• OK.' '────────────────' ' Trust All Tools active, confirmations are off · /quit to exit' \
    '────────────────' 'kiro_default · claude-haiku-4.5 · ◔ 9%' '' "$1" '                                   /copy to clipboard' '' ''
}
cursorless=$(printf 'styled=0\ncursor=0\nidentity=1')
[ "$(fm_composer_classify_screen "$cursorless" "$(kiro_screen '›  ask a question or describe a task ↵')")" = empty ] \
  || fail 'hint row folded into the idle composer on a cursorless read'
[ "$(fm_composer_classify_screen "$cursorless" "$(kiro_screen '› hello draft')")" != empty ] \
  || fail 'a typed draft above the hint row read empty'
for signal in '›  Kiro is working · 4s · Type to steer · Ctrl+S to queue' 'ᗢ Thinking... (esc to cancel)'; do
  printf '%s\n' "$signal" | fm_busy_lines_match kiro || fail "independent delivery signal lost: $signal"
done
! printf '› hello draft\n' | fm_busy_lines_match kiro || fail 'draft read busy'
! printf ' esc to cancel · ↵ to select\n' | fm_busy_lines_match kiro || fail 'idle slash popup read busy'
printf '›  Kiro is working · 4s · Type to steer\n' | fm_busy_lines_match || fail 'harness-less union lost kiro'
pass "composer placeholders, draft safety, and independent delivery signals"

# Busy source: real processes stand in for Kiro's Bun engine. A marker file is
# bound to the task only through its live process's working directory.
state="$TMP_ROOT/state"
wt="$TMP_ROOT/work tree"
other="$TMP_ROOT/elsewhere"
markers="$TMP_ROOT/turn-markers"
mkdir -p "$state" "$wt" "$other" "$markers"
printf 'harness=kiro\nworktree=%s\n' "$wt" > "$state/worker.meta"
idle_screen=$(printf '%s\n' '  earlier prompt' '›  Kiro is working · 3s · Type to steer' '• OK.' '›  ask a question or describe a task ↵' '' '' '')
start_screen=$(printf '%s\n' '›  Initializing · type to queue a message' '')
working_screen=$(printf '%s\n' '›  ask a question or describe a task ↵' '  next prompt' '›  Kiro is working · 1s · Type to steer')
classify() { FM_KIRO_TURN_MARKER_DIR=$markers fm_busy_classify tmux fake:w kiro worker "$state" "$1"; }
# Bounded, and killed explicitly below, so the library's own EXIT cleanup
# trap stays in place.
(cd "$wt" && exec sleep 60) &
bound=$!
(cd "$other" && exec sleep 60) &
foreign=$!
sleep 0.3
[ "$(fm_busy_pid_cwd "$bound")" != "$(fm_busy_pid_cwd "$foreign")" ] || fail 'fixture processes share a cwd; the binding case is vacuous'

[ "$(classify "$idle_screen")" = 'idle kiro-turn-marker' ] || fail "no marker plus idle placeholder must be idle: $(classify "$idle_screen")"
[ "$(classify "$start_screen")" = 'unknown kiro-turn-marker' ] || fail 'startup without a marker must not read idle'
[ "$(classify "$working_screen")" = 'unknown kiro-turn-marker' ] || fail 'scrollback placeholder above a working row read idle'
[ "$(classify '')" = 'unknown kiro-turn-marker' ] || fail 'unreadable screen read idle'
printf '{"pid":%s}\n' "$foreign" > "$markers/$foreign-1.json"
[ "$(classify "$idle_screen")" = 'idle kiro-turn-marker' ] || fail "another session's marker bound to this task"
printf '{"pid":%s}\n' "$bound" > "$markers/$bound-2.json"
# The rendered signal says idle while the structural one says busy: busy must
# survive losing the rendered signal.
[ "$(classify "$idle_screen")" = 'busy kiro-turn-marker' ] || fail "bound marker not busy: $(classify "$idle_screen")"
[ "$(classify '')" = 'busy kiro-turn-marker' ] || fail 'busy depended on a readable screen'
kill "$bound" 2>/dev/null; wait "$bound" 2>/dev/null
[ "$(classify "$idle_screen")" = 'idle kiro-turn-marker' ] || fail "a dead process's stale marker kept the task busy"
rm -f "$markers"/*.json
[ "$(FM_KIRO_TURN_MARKER_DIR="$TMP_ROOT/absent" fm_busy_classify tmux fake:w kiro worker "$state" "$idle_screen")" = 'unknown kiro-turn-marker' ] \
  || fail 'an absent marker directory read idle'
[ "$(FM_KIRO_TURN_MARKER_DIR=$markers fm_busy_classify tmux fake:w kiro nometa "$state" "$idle_screen")" = 'unknown kiro-turn-marker' ] \
  || fail 'a task with no recorded worktree read idle'
[ -z "$(fm_busy_sources_for_harness kiro)" ] || fail 'kiro must trust no stored record'
kill "$foreign" 2>/dev/null; wait "$foreign" 2>/dev/null
pass "turn markers bind by process cwd; idle needs both signals; stale and foreign markers ignored"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" kiro-cli
home="$case_dir/home"
proj="$case_dir/project"
swt="$case_dir/wt"
fm_test_spawn_home "$home" kiro
fm_git_worktree "$proj" "$swt" kiro-test
fm_test_spawn_brief "$home" kiro-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$swt" "$fakebin" kiro-worker "$proj" --scout --harness kiro --model claude-haiku-4.5 --effort xhigh 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" "$fakebin/kiro-cli' chat --trust-all-tools" 'resolved kiro-cli chat with trust-all-tools missing'
assert_contains "$launch" "--model 'claude-haiku-4.5'" 'model lost'
assert_contains "$launch" "--effort 'xhigh'" 'native effort lost'
assert_contains "$launch" 'encode launch-brief' 'positional launch brief lost'
assert_contains "$launch" '-u CLAUDECODE' 'foreign primary marker not cleared'
case "$launch" in *--no-interactive*) fail 'scout launched non-interactive' ;; esac
assert_grep 'harness=kiro' "$home/state/kiro-worker.meta" 'harness not recorded'
assert_absent "$home/state/kiro-worker.busy-gen" 'kiro has no writer, so nothing may be armed'
if out=$(fm_test_run_spawn "$home" "$swt" "$fakebin" kiro-sm "$proj" --secondmate --harness kiro 2>&1)
then fail 'Kiro secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "scout launch carries kiro-cli chat, autonomy, model, native effort, and brief; secondmate refused"
