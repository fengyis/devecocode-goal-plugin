English | [简体中文](README.zh-CN.md)

# devecocode-goal-plugin

A session-scoped `/goal` workflow for DevEco Code. Set a goal, and the plugin
keeps the agent going by itself: it hooks `session.idle` and auto-continues the work until an
**evidence-gated** completion check passes — no need to keep saying "continue". Completion isn't decided
by the model claiming it's done; it's decided by verifiable signals (tool-call records, turn count,
elapsed time, token spend) that the plugin tracks itself.

## What is this

- `/goal <objective>` in a DevEco Code session sets a goal for that session. The plugin listens for
  `session.idle` and automatically injects a continuation turn, up to configurable turn/time/token
  budgets, until the objective is met or a budget is exhausted.
- Completion is claimed by the model calling the `update_goal` tool with `status: "complete"` and
  `evidence`, not by the model simply saying "done" in text.
- State lives on disk per project (`.deveco/goals/state.json`), so `/goal status` and `/goal history`
  reflect the real lifecycle even across restarts.

## Requirements

- DevEco Code 0.1.1 or later (the adaptations in this repo were verified against 0.1.1; behavior on
  other versions is not guaranteed).
- Node.js ≥ 18 to run the test suite (`node --test`).
- `scripts/smoke.sh` additionally requires Python 3 (used to parse JSON responses from `curl`).
- **Never set `DEVECO_SERVER_PASSWORD`** in the shell you run `deveco serve` from. Setting it turns on
  basic auth on the server, and the plugin's internal client does not send credentials — every call it
  makes back to the server will 401.
- Windows: run `goal.sh` and `scripts/smoke.sh` from Git Bash — both are POSIX shell scripts.

## Install

```bash
./goal.sh init <project-dir>
```

This:

1. Copies the plugin entry (`.deveco/plugin/devecocode-goal-plugin.ts`) and the vendored source files
   (`goal-plugin.js`, `opencode-session-api.js`, `native-agent-config.js`, `completion-claim.js`,
   `goal-tool-result.js`, `persistence-lease.js`, `index.d.ts`, `LICENSE`) into
   `<project-dir>/.deveco/plugin/devecocode-goal-plugin/`.
2. Merges a `/goal` command definition into `<project-dir>/deveco.json` (creating the file if it doesn't
   exist). Existing fields are never overwritten — if `command.goal` is already defined, it's left alone;
   if `deveco.json` didn't exist before, a default `model` is added, but an existing `deveco.json`'s
   `model` is never touched.
3. By default, re-running `init` on a project that already has the plugin files **leaves your local edits
   alone** (it just prints a note). Pass `--update` to force-overwrite the installed plugin files with the
   template versions (this discards any local changes you made to them).

```bash
./goal.sh init <project-dir> --update   # force-overwrite installed plugin files
```

## Usage

```bash
cd <project-dir> && deveco    # start an interactive session
```

Inside the session:

```
/goal <objective>     # set a goal for this session; auto-continue starts
/goal status           # show the current goal's state and budget usage
/goal history          # show lifecycle history and the last checkpoint
```

The plugin also registers agent-callable tools: `get_goal`, `get_goal_history`, `set_goal`, and
`update_goal` — the model uses these itself to read and mutate goal state as it works. A smoke run
confirmed the model can name `set_goal` correctly when no goal is active, which is direct evidence the
tools are actually registered with the host.

There are a few more `/goal` subcommands for managing multiple goals in one session (`resume`, `edit`,
`list`, `focus`, `add`, `sequence`) — see `template/.deveco/plugin/devecocode-goal-plugin/goal-plugin.js`
for the full command dispatch if you need them.

Outside a session:

```bash
./goal.sh status <project-dir>    # print .deveco/goals/state.json directly, no session needed
```

## Configuration

Optional file: `<project-dir>/.deveco/goal-plugin.json`. Its contents are passed straight through as the
upstream plugin's `pluginOptions` — if the file is absent, upstream defaults apply. Commonly used keys:

| Key | Default | Meaning |
|---|---|---|
| `maxTurns` | `10` | Max number of auto-continue turns |
| `maxDurationMs` | `900000` (15 min) | Wall-clock budget for auto-continue |
| `maxTokens` | `200000` | Token budget for auto-continue |
| `commandName` | `"goal"` | Command name; changing it moves the slash command to `/<name>` |

Environment variable `DEVECO_GOAL_STATE_PATH` overrides the state file location and takes precedence over
the upstream `OPENCODE_GOAL_STATE_PATH` (which is still honored as a fallback, so existing upstream
integrations keep working). By default state is written to `.deveco/goals/state.json` inside the project.

## Troubleshooting

**First check `.deveco/goals/plugin.log`.** If there's no load record in that file, the plugin was never
discovered by DevEco Code — usually a wrong install path, or checking too early.

That "too early" case is worth calling out explicitly: **the plugin loads when the first session is
created, not when `deveco serve` starts.** A freshly started server has no plugin log yet; the log only
appears once a session exists. If you're scripting a check, create a session first, then grep the log.

## Testing

```bash
node --test test/*.test.js
```

278 tests: 263 carried over unmodified from upstream (the regression baseline), plus 15 added for this
port — DevEco-specific adaptations, `goal.sh` behavior, and smoke-test scenarios.

```bash
scripts/smoke.sh
```

Starts a real `deveco serve`, confirms the plugin gets discovered and loaded, and drives the `/goal`
command-interception path end to end via the HTTP API.

## Credits & License

Ported from [willytop8/OpenCode-goal-plugin](https://github.com/willytop8/OpenCode-goal-plugin) v0.6.5,
pinned at commit `2d3e97edeb6e1ecfbe21b193616987df335f047f` (see [`upstream.lock`](upstream.lock)).
Licensed under the [MIT License](LICENSE), same as upstream.

This project started as Lesson 3 of [deveco-lessons](https://github.com/fengyis/deveco-lessons) — the
full teaching write-up, porting methodology, and raw probe notes (how the DevEco 0.1.1 behaviors above
were actually verified) live there.
