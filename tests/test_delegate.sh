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
# A real deadline must terminate the worker and its shell children.
export DELEGATE_CMD='bash "$FAKE_AGENT"; sleep 10'
set +e
"$root/bin/delegate" run "$tmp/prompt.md" --agent custom --dir "$target" --timeout 1 > "$tmp/timed" 2> "$tmp/timed.err"
status=$?
set -e
[[ $status == 124 ]]
# Codex account rotation: home "a" is out of quota, "b" works; the next run starts on "b".
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
# "b" runs out too; then both are out and "a" (resets sooner) is tried first.
echo $((now + 600)) > "$tmp/b/limited"; echo $((now + 300)) > "$tmp/a/limited"; : > "$ORDER"
"$root/bin/delegate" run "$tmp/prompt.md" --dir "$target" > /dev/null 2>&1 || true
"$root/bin/delegate" run "$tmp/prompt.md" --dir "$target" > /dev/null 2>&1 || true
[[ $(tr '\n' ' ' < "$tmp/order") == "b a a b " ]]
printf 'PASS: summary cap, log isolation, check failure/tail, exclude, timeout, codex account rotation\n'
