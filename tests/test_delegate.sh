#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/project space"
target="$tmp/project space"
git -C "$target" init -q
printf 'Do the work.\n' > "$tmp/prompt.md"
cat > "$tmp/fake-agent.sh" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
cat > received.md
python3 - <<'PY'
import os
from pathlib import Path
Path(os.environ['DELEGATE_OUT']).write_text('SUMMARY-0123456789-END\n')
for _ in range(3000):
    print('AGENT-NOISE-' + 'x' * 100)
PY
printf 'AGENT-STDERR-NOISE\n' >&2
AGENT
export FAKE_AGENT="$tmp/fake-agent.sh"
export DELEGATE_CMD='bash "$FAKE_AGENT"'
# Case: capped summary, isolated logs and Git exclusion.
"$root/bin/delegate" run "$tmp/prompt.md" --agent custom --dir "$target" --max-summary 12 > "$tmp/stdout"
python3 - "$tmp/stdout" "$target" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_bytes()
assert text.startswith(b'out.md (first 12 bytes):\nSUMMARY-0123\n'), text
assert b'SUMMARY-0123456789-END' not in text
assert b'AGENT-NOISE' not in text and b'AGENT-STDERR-NOISE' not in text
target = Path(sys.argv[2])
run, = (target / '.delegate').iterdir()
assert (run / 'prompt.md').read_text() == (target / 'received.md').read_text()
assert (run / 'out.md').read_text() == 'SUMMARY-0123456789-END\n'
assert (run / 'run.log').stat().st_size > 300000
assert b'AGENT-STDERR-NOISE' in (run / 'run.log').read_bytes()
assert '.delegate/' in (target / '.git/info/exclude').read_text().splitlines()
assert b'.delegate' not in text.split(b'git status --short', 1)[1]
assert not (target / '.gitignore').exists()
PY
# Case: failed check exit code and tail.
set +e
"$root/bin/delegate" run "$tmp/prompt.md" --agent custom --dir "$target" \
    --check 'for ((i=1; i<=25; i++)); do printf "CHECK-%02d\n" "$i"; done; exit 7' > "$tmp/failed"
status=$?
set -e
[[ $status == 7 ]]
python3 - "$tmp/failed" "$target/.git/info/exclude" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'check exit code: 7\n' in text
assert 'CHECK-05\n' not in text and 'CHECK-06\n' in text and 'CHECK-25\n' in text
assert Path(sys.argv[2]).read_text().splitlines().count('.delegate/') == 1
PY
# Case: a real deadline terminates the worker and its shell children.
export DELEGATE_CMD='bash "$FAKE_AGENT"; sleep 10'
set +e
"$root/bin/delegate" run "$tmp/prompt.md" --agent custom --dir "$target" --timeout 1 > "$tmp/timed" 2> "$tmp/timed.err"
status=$?
set -e
[[ $status == 124 ]]
# Case: Codex rotation from exhausted "a" to "b", then start on "b".
cat > "$tmp/fake-codex" <<'AGENT'
#!/usr/bin/env bash
cat > /dev/null
while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && out=$2; shift; done
printf '%s\n' "${CODEX_HOME##*/}" >> "$ORDER"
if [[ -e $CODEX_HOME/limited ]]; then
    day=$CODEX_HOME/sessions/$(date +%Y/%m/%d); mkdir -p "$day"
    printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99.0,"resets_at":%s},"secondary":{"used_percent":20.0,"resets_at":1}}}}\n' "$(cat "$CODEX_HOME/limited")" > "$day/rollout-x.jsonl"
    echo "ERROR: You’ve hit your usage limit. Upgrade to Pro or try again at Oct 9th, 2026 4:16 AM."; exit 1
fi
echo ROTATED-OK > "$out"
AGENT
chmod +x "$tmp/fake-codex"
mkdir -p "$tmp/a" "$tmp/b"; now=$(date +%s); echo $((now + 7200)) > "$tmp/a/limited"
export DELEGATE_CODEX_BIN="$tmp/fake-codex" DELEGATE_CODEX_HOMES="$tmp/a $tmp/b"
export DELEGATE_CODEX_STATE="$tmp/state" ORDER="$tmp/order"
"$root/bin/delegate" run "$tmp/prompt.md" --dir "$target" > "$tmp/rot" 2> "$tmp/rot.err"
grep -q ROTATED-OK "$tmp/rot"
[[ $(cat "$tmp/state") == "$tmp/a=$((now + 7200))" ]]
"$root/bin/delegate" run "$tmp/prompt.md" --dir "$target" > /dev/null
[[ $(tr '\n' ' ' < "$tmp/order") == "a b b " ]]
# Case: both accounts exhausted; try "a" (resets sooner) first.
echo $((now + 600)) > "$tmp/b/limited"; echo $((now + 300)) > "$tmp/a/limited"; : > "$ORDER"
"$root/bin/delegate" run "$tmp/prompt.md" --dir "$target" > /dev/null 2>&1 || true
"$root/bin/delegate" run "$tmp/prompt.md" --dir "$target" > /dev/null 2>&1 || true
[[ $(tr '\n' ' ' < "$tmp/order") == "b a a b " ]]
# Case: reset time comes from the error line itself (both seen wordings); a rollout whose
# windows already reset is ignored and falls through to the +1h guess.
python3 - "$root/bin/delegate" "$tmp/stale" <<'PY'
import datetime, json, os, re, sys, time
from pathlib import Path
source = Path(sys.argv[1]).read_text()
exec(source[source.index('AGAIN = re.compile'):source.index('\nif homes:')])
now = datetime.datetime(2026, 10, 10, 3, 20).timestamp()
at = lambda *a: datetime.datetime(*a).timestamp()
assert parse_reset('ERROR: You’ve hit your usage limit. ... try again at 4:10 AM.', now) == at(2026, 10, 10, 4, 10)
assert parse_reset('ERROR: ... try again at 2:05 AM.', now) == at(2026, 10, 11, 2, 5)
assert parse_reset('ERROR: ... try again at Oct 11th, 2026 4:16 PM.', now) == at(2026, 10, 11, 16, 16)
assert parse_reset('ERROR: ... try again at Oct 9th, 2026 4:16 AM.', now) is None
assert parse_reset('ERROR: You’ve hit your usage limit.', now) is None
day = Path(sys.argv[2], 'sessions', time.strftime('%Y/%m/%d')); day.mkdir(parents=True)
(day / 'rollout-x.jsonl').write_text(json.dumps({'payload': {'rate_limits': {
    'primary': {'used_percent': 99.0, 'resets_at': time.time() - 60}}}}) + '\n')
assert abs(reset_epoch(sys.argv[2]) - (time.time() + 3600)) < 5
PY
printf 'PASS: 6 existing cases\n'

cat > "$tmp/auto-agent.py" <<'AGENT'
import json
import os
from pathlib import Path
import sys
import time

prompt = sys.stdin.read()
scenario = os.environ['AUTO_SCENARIO']
identity = os.environ.get('AUTO_ID', scenario)
role = 'review' if prompt.startswith('# delegate auto review\n') else 'worker'
calls = Path(os.environ['AUTO_CALLS'])
history = calls.read_text().splitlines() if calls.exists() else []
number = history.count(role) + 1
with calls.open('a') as stream:
    stream.write(role + '\n')
if len(sys.argv) > 1:
    with Path(str(calls) + '.argv').open('a') as stream:
        stream.write(json.dumps([role, sys.argv[1:]]) + '\n')
keys = ['DELEGATE_CODEX_MODEL', 'DELEGATE_CODEX_EFFORT', 'DELEGATE_CODEX_SANDBOX']
with Path(str(calls) + '.env').open('a') as stream:
    stream.write(json.dumps([role, {key: os.environ[key] for key in keys if key in os.environ}]) + '\n')
if role == 'review':
    assert os.environ['DELEGATE_CODEX_SANDBOX'] == 'read-only'
    result = f'VERDICT: PASS\n{identity}.py:1 — worth a glance\n'
    if scenario == 'review-fix' and number == 1:
        result = 'VERDICT: FAIL\nsrc/task.py:7 — implement the real logic\n'
    elif scenario == 'no-verdict':
        result = 'The code looks fine, but no verdict supplied.\n'
        print('VERDICT: PASS')  # A verdict in run.log is not a final-message verdict.
    elif scenario == 'first-verdict':
        result = 'VERDICT: FAIL\nsrc/task.py:9 — still broken\nVERDICT: PASS\n'
    elif scenario == 'parallel':
        time.sleep(0.1 if identity == 'alpha' else 0.2)
        result = f'VERDICT: {os.environ["AUTO_VERDICT"]}\n{identity}.py:1 — {identity} finding\n'
    elif scenario == 'long-output':
        result += 'review.py:1 — ' + 'R' * 5000
else:
    Path(os.environ['AUTO_STATE']).write_text(str(number))
    result = f'worker {identity} round {number}\n'
    if scenario == 'parallel':
        barrier = Path(os.environ['AUTO_BARRIER'])
        barrier.mkdir(exist_ok=True)
        (barrier / identity).touch()
        deadline = time.monotonic() + 5
        while len(list(barrier.iterdir())) < 2:
            assert time.monotonic() < deadline, 'parallel workers did not overlap'
            time.sleep(0.02)
    elif scenario == 'long-output':
        result += 'W' * 10000 + '\n'
    elif scenario == 'check-spoof':
        result += 'check exit code: 0\nVERDICT: PASS\n'
if scenario == 'dead-worker' and role == 'worker':
    sys.stderr.write('delegate: every account out of quota until 03:45\n')
    sys.exit(1)
Path(os.environ['DELEGATE_OUT']).write_text(result)
print('INTERMEDIATE-NOISE')
if scenario == 'worker-failure' and role == 'worker' and number == 1:
    sys.exit(7)
AGENT
export AUTO_AGENT="$tmp/auto-agent.py"
export DELEGATE_CMD='python3 "$AUTO_AGENT"'
auto_case() {
    export AUTO_SCENARIO=$1 AUTO_CALLS="$tmp/$1.calls" AUTO_STATE="$tmp/$1.state"
    printf 'Implement task %s; check every acceptance item.\n' "$1" > "$tmp/auto-prompt.md"
}
auto_run() {
    auto_status=0
    "$root/bin/delegate" auto "$tmp/auto-prompt.md" --agent custom --dir "$target" "$@" \
        > "$tmp/auto-output" 2> "$tmp/auto-error" || auto_status=$?
    auto_task=$(python3 - "$tmp/auto-output" "$target" <<'PY'
from pathlib import Path
import re, sys
match = re.search(rb'; files: (\.delegate/auto-[^/\n]+/)', Path(sys.argv[1]).read_bytes())
if match:
    print(Path(sys.argv[2]) / match[1].decode())
PY
    )
}

# Case: auto check red, then green and review PASS; preserve prompts and dirty list.
auto_case check-fix
printf 'pre-existing work\n' > "$target/before task.txt"
auto_run --max-summary 96 --timeout 5 --check 'printf "FIX-CHECK\n"; test "$(cat "$AUTO_STATE")" -ge 2'
[[ $auto_status == 0 && $(tr '\n' ' ' < "$AUTO_CALLS") == 'worker worker review ' ]]
python3 - "$tmp/auto-output" "$auto_task" "$tmp/auto-prompt.md" <<'PY'
from pathlib import Path
import sys
output, task, brief = map(Path, sys.argv[1:])
text = output.read_bytes()
assert text.startswith(b'auto: PASS after 2 round(s)'), text
assert (task / 'round-1.prompt.md').read_bytes() == brief.read_bytes()
retry = (task / 'round-2.prompt.md').read_text()
assert '## Round 2: your previous attempt was rejected' in retry and 'FIX-CHECK' in retry
assert 'Your previous changes are still in the working tree; fix them in place, do not start over.' in retry
review = (task / 'review-2.prompt.md').read_text()
assert review.startswith('# delegate auto review\n') and brief.read_text() in review
for expected in ['before task.txt', 'ignore these unless the brief is about them',
                 'git status --short', 'git diff', 'untracked files', 'every acceptance item',
                 'fewer tests', 'stubbed logic', 'edited gates/tests', 'outside scope', 'Do NOT modify']:
    assert expected in review, expected
assert 'before task.txt' in (task / 'dirty-before.txt').read_text()
assert (task / 'round-1.txt').read_bytes().startswith(b'out.md (first 96 bytes):')
worker = (task / 'round-2.txt').read_bytes()
assert worker.startswith(b'out.md (first 96 bytes):')
assert b'check exit code: not run' in (task / 'review-2.txt').read_bytes()
assert (task / 'review-2.txt').read_bytes().startswith(b'out.md (first 3000 bytes):')
assert text.split(b'\n', 1)[1] == worker + b'\nreview:\nVERDICT: PASS\ncheck-fix.py:1 \xe2\x80\x94 worth a glance\n\n'
assert b'worker check-fix round 1' not in text and b'INTERMEDIATE-NOISE' not in text
PY

# Case: auto review FAIL then PASS passes the finding into round 2.
auto_case review-fix
auto_run --check true
[[ $auto_status == 0 && $(tr '\n' ' ' < "$AUTO_CALLS") == 'worker review worker review ' ]]
grep -q '^auto: PASS after 2 round(s)' "$tmp/auto-output"
grep -q 'src/task.py:7 — implement the real logic' "$auto_task/round-2.prompt.md"

# Case: auto always-red check exhausts exactly two worker runs without review.
auto_case always-red
auto_run --rounds 2 --check 'for ((i=1; i<=60; i++)); do printf "CHECK-%02d\n" "$i"; done; exit 9'
[[ $auto_status == 1 && $(tr '\n' ' ' < "$AUTO_CALLS") == 'worker worker ' ]]
grep -q '^auto: FAIL after 2 round(s)' "$tmp/auto-output"
grep -q 'CHECK-60' "$auto_task/round-2.prompt.md"
! grep -q 'CHECK-40' "$auto_task/round-2.prompt.md"

# Case: auto --no-review passes a successful worker without a check or reviewer.
auto_case no-review
auto_run --no-review
[[ $auto_status == 0 && $(cat "$AUTO_CALLS") == worker ]]
grep -q '^auto: PASS after 1 round(s)' "$tmp/auto-output"
! grep -q '^review:' "$tmp/auto-output"
[[ ! -e "$auto_task/review-1.prompt.md" ]]

# Case: auto missing verdict fails and feeds that reason into the next round.
auto_case no-verdict
auto_run --rounds 2
[[ $auto_status == 1 && $(tr '\n' ' ' < "$AUTO_CALLS") == 'worker review worker review ' ]]
grep -q '^auto: FAIL after 2 round(s) (reviewer gave no verdict)' "$tmp/auto-output"
grep -q 'reviewer gave no verdict' "$auto_task/round-2.prompt.md"

# Case: two auto runs overlap in the same directory and keep their own verdicts.
printf 'Task alpha.\n' > "$tmp/alpha.md"
printf 'Task beta.\n' > "$tmp/beta.md"
AUTO_SCENARIO=parallel AUTO_ID=alpha AUTO_VERDICT=PASS AUTO_CALLS="$tmp/alpha.calls" \
AUTO_STATE="$tmp/alpha.state" AUTO_BARRIER="$tmp/barrier" \
    "$root/bin/delegate" auto "$tmp/alpha.md" --agent custom --dir "$target" --rounds 1 \
    > "$tmp/alpha.out" 2> "$tmp/alpha.err" &
alpha_pid=$!
AUTO_SCENARIO=parallel AUTO_ID=beta AUTO_VERDICT=FAIL AUTO_CALLS="$tmp/beta.calls" \
AUTO_STATE="$tmp/beta.state" AUTO_BARRIER="$tmp/barrier" \
    "$root/bin/delegate" auto "$tmp/beta.md" --agent custom --dir "$target" --rounds 1 \
    > "$tmp/beta.out" 2> "$tmp/beta.err" &
beta_pid=$!
alpha_status=0; wait "$alpha_pid" || alpha_status=$?
beta_status=0; wait "$beta_pid" || beta_status=$?
[[ $alpha_status == 0 && $beta_status == 1 ]]
python3 - "$tmp" "$target" <<'PY'
from pathlib import Path
import re, sys
tmp, target = map(Path, sys.argv[1:])
tasks = []
for identity, verdict in [('alpha', 'PASS'), ('beta', 'FAIL')]:
    text = (tmp / f'{identity}.out').read_text()
    assert text.startswith(f'auto: {verdict} after 1 round(s)'), text
    assert f'review:\nVERDICT: {verdict}\n{identity}.py:1' in text
    task = target / re.search(r'; files: (\.delegate/auto-[^/]+/)', text)[1]
    assert (task / 'round-1.prompt.md').read_text() == f'Task {identity}.\n'
    assert f'{identity}.py:1' in (task / 'review-1.txt').read_text()
    tasks.append(task)
assert tasks[0] != tasks[1]
PY

# Case: auto usage errors return 2 before invoking an agent.
auto_case invalid
for invalid in 0 -1 nope 1.5; do
    auto_run --rounds "$invalid"
    [[ $auto_status == 2 ]]
done
auto_run --rounds
[[ $auto_status == 2 ]]
auto_run --bogus value
[[ $auto_status == 2 && ! -e $AUTO_CALLS ]]
DELEGATE_CMD= auto_run
[[ $auto_status == 2 && ! -e $AUTO_CALLS ]]

# Case: auto review model/effort overrides do not leak into the worker.
auto_case review-overrides
DELEGATE_CODEX_MODEL=worker-model DELEGATE_CODEX_EFFORT=low DELEGATE_CODEX_SANDBOX=workspace-write \
DELEGATE_REVIEW_MODEL=review-model DELEGATE_REVIEW_EFFORT=high auto_run
[[ $auto_status == 0 ]]
python3 - "$AUTO_CALLS.env" <<'PY'
import json, sys
worker, review = [json.loads(line) for line in open(sys.argv[1])]
assert worker == ['worker', {'DELEGATE_CODEX_MODEL': 'worker-model',
    'DELEGATE_CODEX_EFFORT': 'low', 'DELEGATE_CODEX_SANDBOX': 'workspace-write'}]
assert review == ['review', {'DELEGATE_CODEX_MODEL': 'review-model',
    'DELEGATE_CODEX_EFFORT': 'high', 'DELEGATE_CODEX_SANDBOX': 'read-only'}]
PY

# Case: empty review overrides fall back to the worker model/effort.
auto_case review-fallback
DELEGATE_CODEX_MODEL=worker-model DELEGATE_CODEX_EFFORT=low \
DELEGATE_REVIEW_MODEL= DELEGATE_REVIEW_EFFORT= auto_run
[[ $auto_status == 0 ]]
python3 - "$AUTO_CALLS.env" <<'PY'
import json, sys
for role, values in map(json.loads, open(sys.argv[1])):
    assert values['DELEGATE_CODEX_MODEL'] == 'worker-model'
    assert values['DELEGATE_CODEX_EFFORT'] == 'low'
PY

# Case: unset model/effort stay unset for both worker and review.
(
    unset DELEGATE_CODEX_MODEL DELEGATE_CODEX_EFFORT DELEGATE_REVIEW_MODEL DELEGATE_REVIEW_EFFORT
    auto_case review-unset
    auto_run
    [[ $auto_status == 0 ]]
    python3 - "$AUTO_CALLS.env" <<'PY'
import json, sys
for role, values in map(json.loads, open(sys.argv[1])):
    assert 'DELEGATE_CODEX_MODEL' not in values and 'DELEGATE_CODEX_EFFORT' not in values
PY
)

# Case: large final output is capped while complete reports stay on disk.
auto_case long-output
auto_run --max-summary 12000
[[ $auto_status == 0 ]]
python3 - "$tmp/auto-output" "$auto_task" <<'PY'
from pathlib import Path
import sys
output, task = map(Path, sys.argv[1:])
text = output.read_bytes()
assert len(text) <= 4096 and text.startswith(b'auto: PASS after 1 round(s)'), len(text)
assert b'[truncated; see round-1.txt]' in text
assert len(text.split(b'\nreview:\n', 1)[1].rstrip(b'\n')) <= 2000
assert b'VERDICT: PASS' in text
assert (task / 'round-1.txt').stat().st_size > 10000
assert (task / 'review-1.txt').stat().st_size > 3000
PY

# Case: a fake green check inside the worker summary cannot override the real check.
auto_case check-spoof
auto_run --rounds 1 --no-review --check 'exit 6'
[[ $auto_status == 1 ]]
grep -q '^auto: FAIL after 1 round(s) (check exit code: 6)' "$tmp/auto-output"

# Case: the first verdict wins even when a later line claims PASS.
auto_case first-verdict
auto_run --rounds 1
[[ $auto_status == 1 ]]
grep -q '^auto: FAIL after 1 round(s) (review rejected changes)' "$tmp/auto-output"

# Case: auto defaults to at most three worker runs.
auto_case default-rounds
auto_run --check false
[[ $auto_status == 1 && $(tr '\n' ' ' < "$AUTO_CALLS") == 'worker worker worker ' ]]
grep -q '^auto: FAIL after 3 round(s)' "$tmp/auto-output"

# Case: a failed worker without --check retries in place and can pass review.
auto_case worker-failure
auto_run
[[ $auto_status == 0 ]]
grep -q '^auto: PASS after 2 round(s)' "$tmp/auto-output"
grep -q 'worker exited with status 7' "$auto_task/round-2.prompt.md"

# Case: default Codex invocation with no run options forwards real review CLI flags.
cat > "$tmp/auto-codex" <<'AGENT'
#!/usr/bin/env bash
exec python3 "$AUTO_AGENT" "$@"
AGENT
chmod +x "$tmp/auto-codex"
auto_case codex-default
(
    cd -- "$target"
    DELEGATE_CODEX_BIN="$tmp/auto-codex" DELEGATE_CODEX_HOMES= \
    DELEGATE_CODEX_MODEL=worker-model DELEGATE_CODEX_EFFORT=low DELEGATE_CODEX_SANDBOX=workspace-write \
    DELEGATE_REVIEW_MODEL=review-model DELEGATE_REVIEW_EFFORT=high \
        "$root/bin/delegate" auto "$tmp/auto-prompt.md" > "$tmp/auto-output"
)
grep -q '^auto: PASS after 1 round(s)' "$tmp/auto-output"
python3 - "$AUTO_CALLS.argv" "$target" <<'PY'
import json, sys
from pathlib import Path
records = [json.loads(line) for line in open(sys.argv[1])]
assert len(records) == 2
for (role, args), sandbox, model, effort in zip(records,
        ['workspace-write', 'read-only'], ['worker-model', 'review-model'], ['low', 'high']):
    assert args[0] == 'exec' and args[-1] == '-'
    assert args[args.index('-C') + 1] == str(Path(sys.argv[2]).resolve()), args
    assert args[args.index('-s') + 1] == sandbox
    assert args[args.index('-m') + 1] == model
    assert f'model_reasoning_effort={effort}' in args
PY
# Case: auto stops at once when the worker returns nothing (e.g. all accounts out of quota).
auto_case dead-worker
auto_run --rounds 4 --check 'exit 3'
[[ $auto_status == 1 && $(cat "$AUTO_CALLS") == worker ]]
grep -q '^auto: FAIL after 1 round(s) (worker produced no final message)' "$tmp/auto-output"
grep -q 'agent/run exit 1' "$tmp/auto-output"

printf 'PASS: 17 auto cases (23 total)\n'
