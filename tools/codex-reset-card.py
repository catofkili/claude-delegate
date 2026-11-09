#!/usr/bin/env python3
"""codex-reset-card.py status|use|auto <CODEX_HOME> — 查/用 Codex 重置卡（wham/rate-limit-reset-credits，从桌面版 app.asar 里翻出来的接口）。

use  用最早过期的一张。
auto [--hit] 按用户定的规则（2026-10-14）判断该不该用，该用就用；用了退出码 0，没用退出码 1。
     规则（任一满足）：
     1. 周限额用完，且周窗口自然刷新距现在 >= 24 小时；
     2. 5 小时限额用完、距 5 小时刷新 > 2 小时，且周限额剩余 < 10%。
     --hit = 刚撞了额度墙，把用得最多的窗口当作已用完。
     delegate 撞额度墙时自动调用 auto --hit（bin/delegate 里 LIMIT 那段）。

为什么要自己刷新 token：2026-11-09 查「周额度用完不止一天却没用卡」时发现，
b 号 auth.json 的 access_token 11-08 就过期了（Codex 只在自己跑的时候刷新），
这个接口直接 401，所以就算想用也用不了。401 时按 Codex CLI 的做法用 refresh_token
换新 token 写回 auth.json。只在 401（token 已过期）时刷新：此时不会有正在跑的
Codex 进程拿着同一个 token，刷新轮换 refresh_token 不会踢掉别人。
"""
import datetime, json, sys, time, urllib.error, urllib.request, uuid
from pathlib import Path

U = 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits'
# Codex CLI 自己用的刷新端点和 client_id（auth.json 里 access_token 的 client_id 就是它）。
REFRESH = 'https://auth.openai.com/oauth/token'
CLIENT = 'app_EMoamEEZ73f0CkXaXp7hrann'

def post(url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, headers={**headers, 'Content-Type': 'application/json'}, data=data)
    return json.load(urllib.request.urlopen(req, timeout=30))

def refresh(home):
    path = Path(home, 'auth.json')
    auth = json.loads(path.read_text())
    new = post(REFRESH, {'User-Agent': 'codex_cli_rs'}, {
        'client_id': CLIENT, 'grant_type': 'refresh_token',
        'refresh_token': auth['tokens']['refresh_token'], 'scope': 'openid profile email'})
    for key in ('id_token', 'access_token', 'refresh_token'):
        if new.get(key):
            auth['tokens'][key] = new[key]
    auth['last_refresh'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    path.write_text(json.dumps(auth, indent=2))

def call(home, path='', body=None, retry=True):
    tokens = json.loads(Path(home, 'auth.json').read_text())['tokens']
    headers = {'Authorization': 'Bearer ' + tokens['access_token'],
               'ChatGPT-Account-Id': tokens.get('account_id', ''), 'User-Agent': 'codex_cli_rs'}
    try:
        return post(U + path, headers, body)
    except urllib.error.HTTPError as error:
        if error.code != 401 or not retry:
            raise
    refresh(home)
    return call(home, path, body, retry=False)

def limits(home):
    # 最新一条 rate_limits 快照（primary=5h，secondary=周）。和 bin/delegate 的 reset_epoch 同一来源。
    for day in (0, 86400, 2 * 86400):
        folder = Path(home, 'sessions', time.strftime('%Y/%m/%d', time.localtime(time.time() - day)))
        for rollout in sorted(folder.glob('rollout-*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True):
            for line in reversed(rollout.read_bytes().splitlines()):
                if b'"rate_limits"' in line:
                    try:
                        return json.loads(line)['payload']['rate_limits']
                    except (ValueError, KeyError):
                        continue
    return {}

def should_use(home, hit=False):
    now, rl = time.time(), limits(home)
    week, five = dict(rl.get('secondary') or {}), dict(rl.get('primary') or {})
    if hit:
        # 刚收到 "You've hit your usage limit"：快照常滞后（停在 98% 之类），
        # 按 bin/delegate 的 reset_epoch 同样的判法，used_percent 最高的那个窗口就是用完的那个。
        full = max((w for w in (week, five) if w), key=lambda w: float(w.get('used_percent', 0)), default=None)
        if full is not None:
            full['used_percent'] = 100
    week_left = float(week.get('resets_at', 0)) - now
    five_left = float(five.get('resets_at', 0)) - now
    if week_left > 0 and float(week.get('used_percent', 0)) >= 100 and week_left >= 86400:
        return 'rule 1: weekly used up, resets in %.1fh' % (week_left / 3600)
    if (five_left > 2 * 3600 and float(five.get('used_percent', 0)) >= 100
            and week_left > 0 and float(week.get('used_percent', 0)) > 90):
        return 'rule 2: 5h used up for %.1fh more, weekly %s%% used' % (five_left / 3600, week.get('used_percent'))
    return None

cmd, home = sys.argv[1], str(Path(sys.argv[2]).expanduser())
if cmd == 'auto':
    reason = should_use(home, hit='--hit' in sys.argv)
    if not reason:
        print(home, 'reset card: rules not met, not used')
        sys.exit(1)
d = call(home)
av = sorted((c for c in d['credits'] if c['status'] == 'available'), key=lambda c: c['expires_at'])
if cmd == 'status':
    print(home, 'available', len(av), [c['expires_at'][:10] for c in av])
elif not av:
    print(home, 'reset card: none left')
    sys.exit(1)
else:
    if cmd == 'auto':
        print(home, 'reset card:', reason)
    print(home, call(home, '/consume', {'credit_id': av[0]['id'], 'redeem_request_id': str(uuid.uuid4())}))
