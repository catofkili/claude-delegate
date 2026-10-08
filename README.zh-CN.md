# claude-delegate

[English](README.md) · [协议](skills/delegate/SKILL.md) · [Agent 接入清单](MODELS.md)

让 Claude 当总监、外部 agent 负责实现、探索或研究的 Claude Code 插件。目标是压低 **Claude 侧的交接成本**。执行者可以是 Codex、Anthropic 兼容端点背后的其他模型，或通过小型命令包装接入的任意 agent。

## 为什么交出去仍可能很贵

总监每轮都要重新读取累积上下文。一个有用的额度估算式是：

> 交接开销 ≈ Claude 额外轮次 × 上下文大小。

缩短 brief 的收益，通常不如减少轮询、读日志和反复审查。[协议中的实测](skills/delegate/SKILL.md#where-claudes-quota-actually-goes-measured)发现：

- 长会话中，交接相关轮次占总成本的 **4%–31%**。
- 随意交接时，总监消耗接近 Claude Haiku 子 agent。遵守协议的玩具任务实测约比该子 agent **便宜 3 倍**，比 Claude 直接执行**便宜 6 倍**。
- 过大的 `CLAUDE.md` 占开局固定上下文的**一半以上**。改成索引和专题文档，可以减少反复注入的负担。
- 压缩本身也消耗摘要、上下文读入和缓存重建成本。协议的会话回放中，这项开销约吃掉**潜在节省的 15%**，仍留下约 **50% 的净节省**。

这些是观察结果，不是价格承诺或模型排名。缓存费率、输出价格和执行者费用不同；`session-cost.py` 测的是上下文读入，不是货币账单。

## 安装

执行器依赖 **Bash、基础命令行工具、Git、Python 3**，以及所选 agent CLI 和它的认证。请先按[各家官方文档](MODELS.md)单独安装、认证 CLI。

GitHub 副本公开后，在 Claude Code 内运行：

```text
/plugin marketplace add catofkili/claude-delegate
/plugin install claude-delegate@claude-delegate
```

技能入口是 `/claude-delegate:delegate`。当前官方文档说明，插件根目录 `bin/` 中的可执行文件会加入 Bash 工具的 `PATH`；本仓库的 `bin/delegate` 已设为可执行。不需要 hook、MCP 服务或自动安装器。[插件可执行文件](https://code.claude.com/docs/en/plugins/components#executables)、[市场安装](https://code.claude.com/docs/en/plugins/create-marketplace)。

本地 checkout 可在仓库根目录运行：

```bash
claude plugin validate .claude-plugin/plugin.json
claude plugin validate .claude-plugin/marketplace.json
claude --plugin-dir .
```

也可以直接用 `./bin/delegate`。普通终端，或不支持插件 `bin/` 的旧版 Claude Code，可从 checkout 创建软链接：

```bash
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/bin/delegate" "$HOME/.local/bin/delegate"
export PATH="$HOME/.local/bin:$PATH"
```

这条软链接命令不会覆盖已有文件。带 `bin/` 的插件面向 **Claude Code**；当前文档明确 claude.ai 和 Cowork 不安装带此顶层目录的插件。[支持范围](https://code.claude.com/docs/en/plugins/components#executables)。

## 三轮协议

完整规则以 [skills/delegate/SKILL.md](skills/delegate/SKILL.md#the-3-turn-protocol) 为准，概要如下：

1. **Brief：**一次写好 `prompt.md`，说明已核实前提、精确可改范围、禁止事项、可机器验收的条件和沙箱限制。要求最终报告**不超过 15 行**：改动文件、验收结果、遗留问题。范围要求不提交时，明确写“do not commit”。
2. **运行并等待：**只启动一次，等完成。十分钟内用前台；较长任务让 Claude 对同一条命令使用 **Bash 工具的 `run_in_background: true`**，等待完成通知。执行器本身没有后台模式。不要轮询或打开 `run.log`。
3. **验收：**根据限长报告、Git 状态和检查结果判断；自己看 `git diff --stat` 和相关改动。失败时发一个聚焦的后续 brief。总监做最终判断，执行者自称“通过”不能替代验收。

小任务合成一份 brief。大量实现和探索适合交接；微小读取和最终架构判断由总监处理。

## 执行任务

```bash
delegate run prompt.md --dir . --check 'bash tests/test_delegate.sh'
delegate run prompt.md --agent codex --dir ./worktree \
  --max-summary 4000 --timeout 600 --check 'python3 -m unittest'
```

| 参数 | 含义 |
| --- | --- |
| `--agent NAME` | `codex`（默认）、`claude-compat` 或 `custom` |
| `--dir DIR` | 已存在的执行目录；默认当前目录 |
| `--check 'CMD'` | agent 结束后，在目标目录执行 Bash 验收命令 |
| `--max-summary N` | 最终报告的前 N **字节**；默认 4000；0 隐藏报告 |
| `--timeout SEC` | 正整数总时限，包含准备、agent 和检查；不设置则不限时 |

每次在目标目录创建 `.delegate/<UTC时间戳>-<唯一后缀>/`，保存 `prompt.md`、`run.log`、`out.md`，按需保留检查和状态文件。在 Git 工作树中，通过 Git 定位仓库的 `info/exclude` 并追加 `.delegate/`，也支持关联 worktree；不会修改 `.gitignore`。非 Git 目录也能运行，Codex 会收到 `--skip-git-repo-check`。

有效调用的 stdout 只包含：

- 限长后的 `out.md` 内容。
- 最多 30 行的 `git status --short`；非 Git 目录为空。
- 检查退出码和末 20 行，或“not run”。
- 总耗时。

agent 的 stdout、stderr 都进入 `run.log`；执行器自己的错误进入 stderr。agent 失败时优先返回其退出码，否则返回检查退出码。超时返回 **124**，中断返回 **130**。最终报告缺失或为空会判失败。agent 出错后仍执行检查；共享时限耗尽时不启动检查，报告 124。agent 同时失败也不会隐藏检查自身的退出码。

限长约束的是总监收到的输出，不限制磁盘日志大小。执行者仍须遵守报告格式。字节截断可能切断 UTF-8 字符或遗漏重要问题，仍需验收和人工审查。`--check` 使用调用者的本地权限，在执行者沙箱外运行。prompt 和日志可能包含敏感资料，Git 排除规则不等于保密或数据传输控制。

## 选择执行后端

### Codex

```bash
export DELEGATE_CODEX_MODEL='your-available-model-id'
export DELEGATE_CODEX_EFFORT='low'
delegate run prompt.md --agent codex --check 'python3 -m unittest'
```

不设置覆盖变量时，沿用已安装 CLI 的模型和 effort 配置；执行器不保证默认模型便宜。使用 `workspace-write`，默认禁止执行者命令联网；任务需要时显式设置 `DELEGATE_CODEX_NETWORK=1`。模型服务本身仍需联网。[Codex 执行模式](https://developers.openai.com/codex/noninteractive)。

`codex` 需要在 `PATH` 里，或者把 `DELEGATE_CODEX_BIN` 设成它的完整路径（例如桌面应用内置的那份）。

#### 多个 Codex 账号

有多个账号时，每个账号在各自的 [`CODEX_HOME`](https://developers.openai.com/codex/config-advanced) 里登录，按优先顺序列出：

```bash
CODEX_HOME="$HOME/.codex-b" codex login     # 每个额外账号做一次；复制 config.toml/AGENTS.md，不要复制 auth.json
export DELEGATE_CODEX_HOMES="$HOME/.codex $HOME/.codex-b"
```

某次运行的日志出现 Codex 额度用完的报错时，执行器从 Codex 写进 `CODEX_HOME/sessions/` 的 `rate_limits` 快照读出该账号的刷新时间并记下，然后换下一个账号重跑同一份 prompt（重跑从头开始，但第一次尝试已改动的文件会保留）。记忆只有一行，存在 `~/.delegate-codex-state`（可用 `DELEGATE_CODEX_STATE` 改位置），每个用完的账号一项 `home=刷新时间戳`。每次运行先按你的顺序试有额度的账号，再按刷新先后试用完的账号，所以总是用最先刷新的那个。依赖这个功能前，请自行确认你的套餐条款是否允许多账号。

### 通过 Claude Code 接入 Anthropic 兼容厂商

以下示例使用 [MODELS.md 中带日期的 DeepSeek 接入](MODELS.md)；换厂商时选取官方端点、模型和匹配的 key：

```bash
read -r -s -p 'Worker API key: ' WORKER_API_TOKEN
printf '\n'
export WORKER_API_TOKEN
export DELEGATE_COMPAT_TOKEN_ENV=WORKER_API_TOKEN
export DELEGATE_COMPAT_BASE_URL=https://api.deepseek.com/anthropic
export DELEGATE_COMPAT_MODEL=deepseek-flash
delegate run prompt.md --agent claude-compat --check 'python3 -m unittest'
```

`DELEGATE_COMPAT_TOKEN_ENV` 只接收环境变量名，执行器**没有明文 token 参数**。先用 `env -u` 清掉继承的 `ANTHROPIC_*` 和 Claude 认证、后端、嵌套会话覆盖变量，再在子 shell 中设置执行者端点、token 和模型；执行器不会把 token 放进命令行参数或打印出来。

这是为了避免嵌套 `claude -p` 继承宿主凭证或 base URL，走错计费账户，出现“Credit balance is too low”或 403。执行器不改写已保存的 Claude Code 配置；若路由仍有偏差，检查项目和用户设置中的供应商配置。受管理的策略仍然适用。

子进程用 `claude -p --output-format json`，执行器提取最终 result 到 `out.md`，错误 result 判失败。`acceptEdits` 模式允许改文件，Bash 命令仍受 Claude Code 权限规则约束；应为任务配置相应规则。这个模式不提供 Codex 的文件系统和联网沙箱。[Claude CLI 参数](https://code.claude.com/docs/en/cli-reference)、[权限模式](https://code.claude.com/docs/en/permission-modes)。

### 用 `custom` 接入其他 CLI

```bash
export DELEGATE_CMD='my-agent-wrapper'
delegate run prompt.md --agent custom --dir ./worktree --check 'python3 -m unittest'
```

包装命令在目标目录执行，从 stdin 接收 prompt，向绝对路径 `$DELEGATE_OUT` **只写最后一条消息**，失败返回非零。两条输出流上的进度信息都被收进 `run.log`。最小契约演示：

```bash
export DELEGATE_CMD='cat >/dev/null; printf "done\n" > "$DELEGATE_OUT"'
```

这是假的执行者，用于展示契约，不是模型连接。[MODELS.md](MODELS.md) 列出 Gemini CLI、Qwen Code、Kimi Code CLI 已经官方核实的非交互参数，以及未核实项。JSON 响应应解析成最终消息，不能把整个过程转录塞进 `DELEGATE_OUT`。

## 给 Claude 自己的上下文瘦身

把 `CLAUDE.md` 保持为索引，目标**不超过 15,000 字符**。将既有详细章节原样移到 `docs/claude/*.md`，在索引里写明确文件路径和任务触发条件，按需读取专题。把所有专题重新 import 到索引里会抵消瘦身效果。

拆分前备份原文，改完再用现有校验脚本：

```bash
cp CLAUDE.md .claude-md-orig.tmp
# 拆分完成后：
python3 tools/verify-split.py
# 使用其他相对路径：
python3 tools/verify-split.py --original original.md \
  --index CLAUDE.md --docs docs/claude
```

校验器保留原逻辑：每个 `## ` 章节必须在索引和专题合集中原样出现且只出现一次，每个专题文件都须被引用。原有硬上限是 **20,000 字符**，比 15,000 字符的目标宽松。只检查该目录第一层 `*.md`，不检查嵌套文档、前言保留、token 数或触发条件是否合理。原文备份不要放进公开发布物。

下列设置名和环境覆盖变量已在 Claude Code **2.1.281 二进制**中核实。它们属于版本相关控制，不承诺稳定的公开配置格式。将合适值合入已有设置，不要覆盖无关配置。这些是限制值示例，不是实测会话数据：

```json
{
  "autoCompactWindow": 200000,
  "bashOutputMaxChars": 8000
}
```

新建终端会话时，对应环境控制可写成：

```bash
CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 BASH_MAX_OUTPUT_LENGTH=8000 claude
```

压缩窗口必须在所选模型真实限制内，并验证已安装版本确实采用这些设置。构建和测试日志也用 `tail`、`grep` 限制；除非要求详细报告，总监回复也应简短，生成的文字仍会留在上下文中。里程碑写进度文件，适时开启新会话。协议要求完成大项目之前完整审读一次项目文档，不要求交接时反复全文读取。

## 测量自己的会话

Claude Code 的转录保存在 `~/.claude/projects/<编码项目目录>/*.jsonl`。替换占位符，选一份真实转录，保持路径带引号：

```bash
SESSION="$HOME/.claude/projects/<encoded-project>/<session>.jsonl"
python3 tools/session-cost.py "$SESSION"
python3 tools/session-cost.py "$SESSION" --handoff-pattern 'codex|delegate|gemini'
python3 tools/session-cost.py --help
```

Python 直接打开文件，编码目录以 `-` 开头也安全。另用 shell 搜索工具时，应在文件参数前加 `--`。

脚本报告按 assistant 消息 ID 去重的轮次、首个有 usage 的上下文作为**开局固定上下文代理值**、峰值上下文、显式压缩边界、按前一轮工具类别估算的上下文净增，以及匹配轮次占全部上下文读入的比例。读入量是 `input_tokens`、`cache_read_input_tokens`、`cache_creation_input_tokens` 之和；重复消息 ID 合并，assistant sidechain 不计入。

默认交接正则 `codex|delegate` 不区分大小写，匹配 assistant 文本和工具名、输入；不会自动把回传日志或后续审查轮次归为交接。混合工具批次保留为混合类别；增量也包含文本、用户输入和其他上下文，因此不是精确工具 token 账目。压缩过渡和其他负向上下文变化不计净增。压缩次数只计显式 `compact_boundary`，旧格式或缺失边界可能漏计。报告缺失 usage，JSON 错误带行号失败，不打印 prompt 或转录正文。

## 验证和局限

```bash
bash tests/test_delegate.sh
bash -n bin/delegate
python3 tools/session-cost.py --help
python3 tools/verify-split.py --help
# 已安装时：
shellcheck bin/delegate
```

本地假 agent 测试只证明执行器行为，不能证明真实厂商可访问、模型质量、GitHub 插件安装或账户计费。端点、会员条款、CLI 参数和上下文窗口变化很快，以 [MODELS.md](MODELS.md) 的 **2026-10-08 核实日期和官方链接**为准，依赖之前再核对。托管 agent 可能把代码传往其他司法辖区，选择后端前请看其中的数据传输部分。

使用 [MIT 协议](LICENSE)，版权人为 claude-delegate contributors。
