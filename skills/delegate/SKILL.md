---
name: delegate
description: Hand implementation, exploration and research work to a cheaper external agent (Codex/GPT, Gemini, or a Chinese model behind an Anthropic-compatible endpoint) while Claude stays the supervisor, with the fewest Claude turns possible. Use when the user wants to save Claude quota, says "delegate", "hand it to codex/gpt/luna/sol", "let the cheap model do it", or when a task needs lots of code written or many files read.
---

# Delegate: Claude supervises, a cheaper agent does the work

The point is to spend as little Claude quota as possible. Read this before every delegation.

## Where Claude's quota actually goes (measured)

Every Claude turn re-reads the **entire** context (at cache price, but still). So:

> **cost ≈ number of Claude turns × context size**, not "size of the handoff text".

In measured long sessions (400–1100 turns, 400k–600k context per turn):

- Handoff turns (writing the brief, launching, *polling*, reading logs, reviewing) were **4%–31%** of the whole session's cost. Almost all of that came from extra turns, not from the briefs.
- Done sloppily (polling, `cat run.log`, reading screenshots the worker produced), delegating cost about as much Claude quota as just letting a Claude Haiku subagent do the work.
- Done with the discipline below, one delegation cost the supervisor **1 extra turn + ~400 tokens of summary**. On a toy task that was ~3× cheaper than a Haiku subagent and ~6× cheaper than Claude doing it directly.

## When to delegate, and when not to

Delegate when the work is big compared with ~3 turns of handoff:

- Writing or refactoring more than a few dozen lines, plus tests and gates.
- Exploration that needs many files, big logs or big diffs to answer one question. What you read stays in your context and is paid for again **every remaining turn**; the worker's reading costs you nothing.
- Web or doc research.

Don't delegate:

- Reading 1–2 files or a few hundred lines. Read them yourself in one turn.
- Small edits where the brief would be longer than the diff.
- **Judgment**: architecture decisions, final review, "is this done and correct". The worker locates facts and implements; Claude decides and referees. Never let the worker grade its own output.

## The 3-turn protocol

1. **Brief** (one Write). Write `prompt.md` with:
   - the verified facts and premises. The worker executes a wrong premise faithfully, so check your premises *before* sending.
   - exact scope: which directory or files it may touch, "do not commit", what not to touch.
   - **machine-checkable acceptance**, e.g. "≥ 6 `def test_` methods", "`npm test` passes", "`tsc --noEmit` clean", "no new dependency in package.json".
   - known sandbox pitfalls in this repo (no dev server, no network, …).
   - the last line: *"Your final message: ≤ 15 lines — files changed, gate results, open issues."*
2. **Run + wait** (one Bash call). `delegate run prompt.md --check '<acceptance command>'`.
   - Under 10 minutes: run it in the foreground.
   - Longer: run the same command with `run_in_background: true` and wait for the completion notification. **Do not poll** and do not peek at `run.log`.
3. **Verify** (that same call's output, or one more call). `delegate` prints only the capped summary, `git status --short`, and the tail of the check command. Then:
   - check: green → review `git diff --stat`, open only the hunks that look suspicious, commit yourself.
   - check: red → send one follow-up brief with the failing output, or fix it yourself if it's tiny.

Batch: several small tasks go into **one** brief and one run, not several round trips. If two parallel tasks touch the same interface, write the interface (export names, signatures) into both briefs so neither waits on the other.

## Spot-check the referee way

Assume the worker cut corners. In one measured run, a strong model at "high" effort wrote 2 test methods where 6 cases were required; its own summary said everything passed. A one-line `grep -c 'def test'` caught it. Prefer counting and grepping over reading:

- counts (tests, call sites, files changed) against the brief
- `git diff --stat` for unexpected files
- for a claimed fact ("X is defined at a.ts:120"), read those ~20 lines, not the whole file

## Choosing the worker

Configure the agents in `delegate` (see the README). Rule of thumb: the default cheap agent for routine implementation and exploration, the strongest available agent for hard, multi-step problems. Models change monthly; the protocol doesn't.

## Keep your own context small (the other half of the bill)

- Huge `CLAUDE.md` files are paid for on every turn of every session, and re-injected after each compaction. Keep `CLAUDE.md` an index (≤ ~15k chars) that points to topic docs, and read the topic docs only when the index says the task triggers them. See `tools/verify-split.py`.
- Lower the auto-compact window (`autoCompactWindow` in settings) if you use a 1M-context model, so context doesn't sit at 500k+.
- Pipe build/test output through `tail` or `grep` instead of reading it all.
- At the end of each milestone, write progress notes to a file and suggest a fresh session to the user.
- Do one full read of all project docs, once, in a fresh session, right before declaring a big project done. Checking the delivery against every rule is referee work; do it yourself.
- Keep your own replies short. Output tokens cost ~5x input and stay in context for every later turn. Give the conclusion and the next step; write long reports only when the user asks for one.
- Overheads of these measures are real but small: each auto-compaction costs roughly one full context read plus a summary and a cache rebuild. In replays of real sessions, that ate about 15% of the savings, and the net saving was still ~50%.
