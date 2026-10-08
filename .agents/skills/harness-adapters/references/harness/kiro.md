# Kiro CLI

Verified on 2026-10-08 with kiro-cli 2.27.1 on macOS arm64, on tmux and a Herdr 0.9.3 lab session.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/kiro.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `kiro-cli` resolved from `PATH` and refused if absent; never `kiro`, which is the Kiro desktop-app launcher. `kiro-cli` execs `kiro-cli-chat`, which runs a Bun engine and a second `kiro-cli-chat` that owns tool subprocesses. |
| Launch | `kiro-cli chat --trust-all-tools [--model <id>] [--effort <level>] "<brief>"` in the worktree; the positional first question submits itself. There is no workspace flag, and `--no-interactive` is never used because it exits after one turn. No workspace-trust dialog renders. |
| Busy state | Pull source `kiro-turn-marker`: Kiro writes `<pid>-<turn-start-ms>.json` into its turn-marker directory for each running turn and deletes it at turn end, including Escape cancellation. A live marker whose Bun process has the task worktree as its working directory is busy; no bound marker plus the empty `›` placeholder on screen is idle; anything else is unknown. Nothing is armed or seeded. `../../../../../bin/fm-busy-lib.sh` owns the binding. |
| Rendered rows | Idle `›  ask a question or describe a task ↵`, startup `›  Initializing · type to queue a message`, running `›  Kiro is working · <n>s · Type to steer · Ctrl+S to queue` plus `Thinking... (esc to cancel)` while reasoning, and a right-aligned `/copy to clipboard` hint row below the composer. |
| Turn end | No hook or notification touch; completion arrives through the worker status protocol and the marker's removal. |
| Exit | `/quit`, through the shared slash-popup settle; prints `Resume with: kiro-cli --resume-id <session-id>` and returns to the shell. |
| Interrupt | Single `Escape`; Ctrl+C also cancels. The turn shows `Cancelled <tool>`, the marker is removed, the composer returns empty with no restored draft, and an idle Escape renders nothing. A cancelled shell tool's child process can outlive the cancel until the session exits. |
| Resume | `kiro-cli chat --resume-id <session-id>` with a new positional question keeps the prior conversation; `--resume` takes the most recent session for the cwd. No pane-resume verb; use deterministic relaunch. |
| Model | `--model <id>`; discover with `kiro-cli chat --list-models --format json`, whose `rate_multiplier` is the credit cost. |
| Effort | `--effort low\|medium\|high\|xhigh\|max`; support is per model, and an unsupported model warns `failed to set effort` and runs at its default. |
| Marker | `KIRO_VERSION` and `KIRO_SESSION_ID` on tool subprocesses; Kiro does not scrub an inherited `CLAUDECODE`, so the marker is tested before it and the launch clears foreign markers. Anchored `kiro-cli`/`kiro-cli-chat` ancestry outranks foreign markers. |
| Provider family | Kiro bills in its own Kiro credits on the Kiro/AWS account, so a dispatch profile names provider `kiro`, never `claude` or `codex`, even when the model id is a Claude or GPT model. quota-axi has no Kiro provider, so its quota is disclosed uncertainty. |
| Imported config | A project `.claude/settings.json` hook never fired; Kiro's own agent configuration under `~/.kiro` still applies. |
| Skill | No verified slash-skill form; use natural language. |

## Host shell integration

The Kiro desktop app's shell integration (`~/.zshrc` and `~/.zprofile` blocks) wraps every interactive zsh in a `zsh (kiro-cli-term)` pty proxy.
A pane whose shell is wrapped shows only that proxy in its foreground process group, so Herdr's process view reports no agent and the worker reads dead.
This affects every harness typed into such a shell, not only Kiro; launch panes from a shell without that integration.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Kiro.
Do not launch a primary or secondmate with this adapter.
Kiro's hooks, ACP `--output-format stream-json` events, and quota-provider integration remain separate follow-ups.
