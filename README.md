# claude-delegate

[中文](README.zh-CN.md) · [Protocol](skills/delegate/SKILL.md) · [Agent compatibility](MODELS.md)

A Claude Code plugin that lets Claude supervise while an external agent implements, explores or researches. It keeps the **Claude-side handoff cost** small. The worker can be Codex, or another model behind an Anthropic-compatible endpoint, or any agent with a small command wrapper.

## Why delegation can still be expensive

Every supervisor turn reads its accumulated context again. A useful quota proxy is:

> Handoff overhead ≈ extra Claude turns × context size.

Shrinking a brief helps less than removing polling, log reads and repeated reviews. The supplied [protocol's measurements](skills/delegate/SKILL.md#where-claudes-quota-actually-goes-measured) found:

- Handoff turns accounted for **4%–31%** of long-session cost.
- Careless delegation cost about as much supervisor quota as a Claude Haiku subagent. Disciplined delegation on a toy task was about **3× cheaper than that subagent and 6× cheaper than direct Claude execution**.
- An oversized `CLAUDE.md` contributed **more than half** of the opening fixed context. An index plus topic documents removes that repeated burden.
- Compaction has its own summary/context/cache-rebuild cost. The protocol's session replays attributed about **15% of the potential savings** to that overhead, with about **50% net savings** remaining.

These are observations, not price promises or a model ranking. Cache rates, output prices and worker charges differ; `session-cost.py` measures context reads, not a currency bill.

## Install

The runner needs **Bash, core utilities, Git and Python 3**, plus your chosen agent CLI and its authentication. Install and authenticate that CLI separately using [its official documentation](MODELS.md).

For a published GitHub copy, run inside Claude Code:

```text
/plugin marketplace add catofkili/claude-delegate
/plugin install claude-delegate@claude-delegate
```

The plugin exposes the skill as `/claude-delegate:delegate`. Current official docs say executable files in a plugin's root `bin/` are added to the Bash tool's `PATH`; this repository's `bin/delegate` is executable. There is no hook, MCP server or automatic installer. [Plugin executables](https://code.claude.com/docs/en/plugins/components#executables), [Marketplace installation](https://code.claude.com/docs/en/plugins/create-marketplace).

For a local checkout, from its root:

```bash
claude plugin validate .claude-plugin/plugin.json
claude plugin validate .claude-plugin/marketplace.json
claude --plugin-dir .
```

You can also run `./bin/delegate` directly. For an ordinary terminal, or an older Claude Code version without plugin `bin/` support, create a symlink from the checkout:

```bash
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/bin/delegate" "$HOME/.local/bin/delegate"
export PATH="$HOME/.local/bin:$PATH"
```

The symlink command deliberately does not overwrite an existing file. `bin/` plugins target **Claude Code**; current docs say claude.ai and Cowork do not install plugins with that top-level directory. [Supported surfaces](https://code.claude.com/docs/en/plugins/components#executables).

## The three-turn protocol

The complete rules live in [skills/delegate/SKILL.md](skills/delegate/SKILL.md#the-3-turn-protocol). In brief:

1. **Brief:** write one `prompt.md` with verified premises, exact permitted scope, prohibited changes, machine-checkable acceptance and known sandbox limits. Ask for a final report of **at most 15 lines**: changed files, gate results, open issues. Say “do not commit” when that is the scope.
2. **Run and wait:** launch once, then wait for completion. Under ten minutes, use the foreground. For longer work, ask Claude to use its **Bash tool's `run_in_background: true`** with the same command; wait for its notification. The runner itself has no background mode. Do not poll or open `run.log`.
3. **Verify:** use the capped report, Git status and check result. Inspect `git diff --stat` and relevant hunks yourself. On failure, send one focused follow-up brief. The supervisor makes the final judgment; a worker's “passed” claim is not the gate.

Batch small tasks into one brief. Large implementation and exploration are useful candidates; tiny reads and final architectural judgment stay with the supervisor.

## Run a task

```bash
delegate run prompt.md --dir . --check 'bash tests/test_delegate.sh'
delegate run prompt.md --agent codex --dir ./worktree \
  --max-summary 4000 --timeout 600 --check 'python3 -m unittest'
```

| Option | Meaning |
| --- | --- |
| `--agent NAME` | `codex` (default), `claude-compat`, or `custom` |
| `--dir DIR` | Existing worker directory; defaults to the current directory |
| `--check 'CMD'` | Run a Bash acceptance command in that directory after the agent finishes |
| `--max-summary N` | First N **bytes** of the final report; default 4000; 0 hides the report |
| `--timeout SEC` | Positive integer wall-clock deadline for setup, agent and check; omitted means no deadline |

Each run creates `.delegate/<UTC-timestamp>-<unique-suffix>/` in the target directory with `prompt.md`, `run.log` and `out.md`. Check/status files are retained when applicable. In Git working trees, the runner appends `.delegate/` to the repository's `info/exclude`, resolved through Git so linked worktrees also work. It never edits `.gitignore`. Non-Git directories still run; Codex receives `--skip-git-repo-check`.

Successful invocation stdout contains only:

- The capped `out.md` content.
- `git status --short`, at most 30 lines; empty for a non-Git directory.
- The check's exit code and last 20 output lines, or “not run”.
- Total elapsed time.

Agent stdout and stderr go to `run.log`. Errors from the runner go to stderr. Agent failure wins as the exit status; otherwise the check's status is returned. Timeout returns **124**, interruption **130**. An empty/missing final report fails the run. The check still runs after an agent error; if the shared deadline is exhausted, it reports 124 without starting. The check's printed status remains visible even when the agent also failed.

Caps bound supervisor output, not disk usage. The worker must still obey the report format. A byte cap may cut a UTF-8 character or omit a relevant issue; acceptance checks and human review remain necessary. `--check` runs locally with the caller's permissions, outside the worker's sandbox. Prompts and logs may contain sensitive material: Git exclusion is not a secrecy or data-transfer control.

## Choose a backend

### Codex

```bash
export DELEGATE_CODEX_MODEL='your-available-model-id'
export DELEGATE_CODEX_EFFORT='low'
delegate run prompt.md --agent codex --check 'python3 -m unittest'
```

Without these overrides, the installed CLI's configured model and effort apply; the runner does not assume that model is cheap. It uses `workspace-write` and disables networking for worker commands. If the task needs network access, explicitly set `DELEGATE_CODEX_NETWORK=1`. The model service itself still requires a network connection. [Codex execution](https://developers.openai.com/codex/noninteractive).

`codex` must be on `PATH`, or set `DELEGATE_CODEX_BIN` to its full path (for example the copy bundled inside a desktop app).

#### Several Codex accounts

If you have more than one account, log each one in under its own [`CODEX_HOME`](https://developers.openai.com/codex/config-advanced) and list them in order of preference:

```bash
CODEX_HOME="$HOME/.codex-b" codex login     # once per extra account; copy config.toml/AGENTS.md over, not auth.json
export DELEGATE_CODEX_HOMES="$HOME/.codex $HOME/.codex-b"
```

When a run's log shows Codex's usage-limit error, the runner reads that account's reset time from the `rate_limits` snapshot Codex writes into `CODEX_HOME/sessions/`, records it, and reruns the same prompt on the next account (the rerun starts fresh on whatever the first attempt already changed). The memory is a single line in `~/.delegate-codex-state` (override with `DELEGATE_CODEX_STATE`), `home=reset_epoch` per exhausted account. Each run tries ready accounts first in your order, then exhausted ones by soonest reset, so the account that refreshes first is the one in use. Check your plan's terms on multiple accounts before relying on this.

### Anthropic-compatible provider through Claude Code

This example uses the [dated DeepSeek integration](MODELS.md); choose a documented endpoint, model and matching key for your provider:

```bash
read -r -s -p 'Worker API key: ' WORKER_API_TOKEN
printf '\n'
export WORKER_API_TOKEN
export DELEGATE_COMPAT_TOKEN_ENV=WORKER_API_TOKEN
export DELEGATE_COMPAT_BASE_URL=https://api.deepseek.com/anthropic
export DELEGATE_COMPAT_MODEL=deepseek-flash
delegate run prompt.md --agent claude-compat --check 'python3 -m unittest'
```

`DELEGATE_COMPAT_TOKEN_ENV` names an environment variable; the runner has **no plaintext token argument**. It first removes inherited `ANTHROPIC_*` variables and Claude authentication/backend/nested-session overrides with `env -u`, then sets the worker's endpoint, token and model inside the child shell. Tokens are not inserted into command-line arguments or printed by the runner.

This prevents a common nested `claude -p` failure: inherited host credentials or base URLs route requests to the wrong account, producing “Credit balance is too low” or 403. It does not rewrite stored Claude Code configuration: check your project/user provider settings if routing still differs. Managed policy still applies.

The child uses `claude -p --output-format json`; the runner extracts the final result into `out.md` and treats an error result as failure. Its `acceptEdits` mode permits file edits; Bash commands still require the appropriate Claude Code permission rules. Configure those rules for the intended task. This mode does not supply Codex's filesystem/network sandbox. [Claude CLI flags](https://code.claude.com/docs/en/cli-reference), [Permission modes](https://code.claude.com/docs/en/permission-modes).

### Another CLI with `custom`

```bash
export DELEGATE_CMD='my-agent-wrapper'
delegate run prompt.md --agent custom --dir ./worktree --check 'python3 -m unittest'
```

Your wrapper runs in the target directory, receives the prompt on stdin, writes **only its final message** to the absolute `$DELEGATE_OUT` path, and returns a nonzero exit code on failure. Progress on either output stream is captured in `run.log`. A minimal contract demonstration is:

```bash
export DELEGATE_CMD='cat >/dev/null; printf "done\n" > "$DELEGATE_OUT"'
```

This demonstration is a fake worker, not a model connection. [MODELS.md](MODELS.md) lists officially verified noninteractive parameters for Gemini CLI, Qwen Code and Kimi Code CLI, and identifies unverified flags. A JSON response must be parsed into a final message; do not dump its entire transcript into `DELEGATE_OUT`.

## Keep Claude's own context small

Keep `CLAUDE.md` as an index with a target of **at most 15,000 characters**. Move detailed existing sections verbatim to `docs/claude/*.md`; put literal topic paths and task triggers in the index. Read topic documents on demand. Importing all of them back into the index defeats this goal.

Before splitting, save the original, then run the supplied verifier after the edit:

```bash
cp CLAUDE.md .claude-md-orig.tmp
# Split the content, then:
python3 tools/verify-split.py
# Alternate relative paths:
python3 tools/verify-split.py --original original.md \
  --index CLAUDE.md --docs docs/claude
```

The verifier preserves its original rules: each `## ` section must appear verbatim exactly once in the combined index/documents; every topic file must be referenced. Its existing hard ceiling is **20,000 characters**, looser than the 15,000-character target. It checks top-level `*.md` files, not nested documents, preamble preservation, token counts or whether a topic trigger is sensible. Keep the backup outside any public release.

The following setting names and environment overrides were confirmed in the Claude Code **2.1.281 executable**. They are version-specific controls, not a promise of a stable public settings schema. Merge suitable values into your existing settings rather than replacing unrelated configuration. These are example limits, not measured session data:

```json
{
  "autoCompactWindow": 200000,
  "bashOutputMaxChars": 8000
}
```

For a new terminal session, the corresponding environment controls are:

```bash
CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 BASH_MAX_OUTPUT_LENGTH=8000 claude
```

Choose a compaction window within the selected model's actual limits; verify that your installed version honors the controls. Truncate build/test logs with `tail` or `grep` as well, and keep supervisor replies short unless a detailed report is requested: generated text also remains in context. At milestones, write progress notes and start a fresh session when useful. The protocol calls for one full project-document review before final completion, not repeated full reads during handoff.

## Measure your own session

Claude Code stores transcripts under `~/.claude/projects/<encoded-project>/*.jsonl`. Replace the placeholders with one actual transcript and keep the path quoted:

```bash
SESSION="$HOME/.claude/projects/<encoded-project>/<session>.jsonl"
python3 tools/session-cost.py "$SESSION"
python3 tools/session-cost.py "$SESSION" --handoff-pattern 'codex|delegate|gemini'
python3 tools/session-cost.py --help
```

Python opens the filename directly, so an encoded directory beginning with `-` is safe. If using a separate shell search command, put `--` before filename arguments.

The tool reports unique assistant-message turns, the first measured context as an **opening fixed-context proxy**, peak context, explicit compaction boundaries, approximate context net growth by the preceding tool category, and matched turns' share of total context reads. Context reads sum `input_tokens`, `cache_read_input_tokens` and `cache_creation_input_tokens`; repeated message IDs are merged, and assistant sidechains are excluded.

The default case-insensitive handoff pattern is `codex|delegate`, matched against assistant text and tool names/inputs. It does not attribute returned logs or later review turns automatically. Mixed tool batches stay mixed; a delta also includes text, user input and other context, so it is an approximation rather than per-tool token accounting. Compaction transitions and other negative context drops are excluded from growth. Only explicit `compact_boundary` records count as compactions; older/missing boundaries can undercount them. Missing usage is reported and invalid JSON fails with a line number. No prompts or transcript bodies are printed.

## Validation and limits

```bash
bash tests/test_delegate.sh
bash -n bin/delegate
python3 tools/session-cost.py --help
python3 tools/verify-split.py --help
# If installed:
shellcheck bin/delegate
```

Local fake-agent tests prove runner behavior, not live provider access, model quality, plugin installation from GitHub or account billing. Model endpoints, membership terms, CLI flags and context windows change quickly: use the **2026-10-08 verification dates and official links in [MODELS.md](MODELS.md)**, then recheck before depending on them. Hosted agents may send code to other jurisdictions; review the data-transfer section there before choosing a backend.

Licensed under [MIT](LICENSE), copyright claude-delegate contributors.
