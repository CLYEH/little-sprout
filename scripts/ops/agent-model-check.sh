#!/bin/bash
# scripts/ops/agent-model-check.sh <agent-name> [--days N] — 查某支 subagent 最近一次實際跑的 model／effort（LS-353）
#
# 背景：LS-353 把 ios-dev／ui-designer／qa 升 opus 並在 frontmatter 明寫 `effort: high`（Opus 5.5 API 預設
# medium；全域 effortLevel 是否傳給 subagent 未證實）。定義檔寫了不等於實際生效——這支從 Claude Code 的
# transcript 抓出最近一次該 agent 的 assistant turn，印 model、effort、時間戳、檔路徑，當首批派工的實證。
#
# 掃描範圍：${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<專案 slug>/**/subagents/*.jsonl，只看 mtime 在
# 近 N 天（預設 14）內的檔。專案 slug 由 git-common-dir 推導（主 checkout 絕對路徑、非英數字元換成 -，
# 同 Claude Code 的命名），不寫死使用者名；從任何 worktree 呼叫都指向同一個專案目錄。
# 多帳號各有自己的 config dir（例如 ~/.claude-2）：要查別的帳號就 CLAUDE_CONFIG_DIR=<dir> 再跑。
#
# agent 辨識：優先讀同名 `agent-*.meta.json` 的 `agentType`（Claude Code 派工時寫的 sidecar）；沒有 sidecar
# 才退回「首則 user 訊息含 agent 名稱」（LS-350 model-usage 腳本的做法，較鬆，輸出標明「來源：prompt」）。
# effort：assistant 行頂層 `effort`／`perTurnEffort`，或 message.output_config.effort；都沒有就印
# 「transcript 無 effort 欄」。
#
# exit：0 找到；1 範圍內找不到該 agent 的 assistant turn（或專案目錄不存在）；2 用法錯誤。
# 自測：scripts/ops/agent-model-check.test.sh（CI rules job）。
set -uo pipefail

usage() { echo "用法：bash scripts/ops/agent-model-check.sh <agent-name> [--days N]" >&2; exit 2; }

agent=""
days=14
while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      [ $# -ge 2 ] || usage
      case "$2" in ''|*[!0-9]*) echo "✗ --days 需要正整數，收到「${2}」" >&2; exit 2 ;; esac
      days="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "✗ 不認得的旗標：${1}" >&2; usage ;;
    *)
      [ -z "$agent" ] || { echo "✗ 只接受一個 agent 名稱（已有「${agent}」，又收到「${1}」）" >&2; exit 2; }
      agent="$1"; shift ;;
  esac
done
[ -n "$agent" ] || usage

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "✗ 不在 git repo 內，無法推導專案 slug" >&2; exit 2; }
main_checkout="$(dirname "$common")"
slug="$(printf '%s' "$main_checkout" | sed 's/[^A-Za-z0-9]/-/g')"
proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/${slug}"
if [ ! -d "$proj" ]; then
  echo "✗ 找不到專案 transcript 目錄：${proj}" >&2
  exit 1
fi

python3 - "$proj" "$agent" "$days" <<'PY'
import glob, json, os, re, sys, time

proj, agent, days = sys.argv[1], sys.argv[2], int(sys.argv[3])
cutoff = time.time() - days * 86400
KNOWN = r"(ios-dev|merge-reviewer|visual-reviewer|ui-designer|dead-code-sweeper|\bqa\b)"

def agent_of(path):
    meta = path[:-len(".jsonl")] + ".meta.json"
    if os.path.exists(meta):
        try:
            with open(meta, encoding="utf-8") as f:
                t = json.load(f).get("agentType")
            if t:
                return t, "meta.json"
        except (OSError, ValueError):
            pass
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("type") != "user":
                    continue
                c = o.get("message", {}).get("content")
                txt = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
                m = re.search(KNOWN, txt[:4000])
                return (m.group(1) if m else None), "prompt"
    except OSError:
        pass
    return None, None

def effort_of(o):
    parts = []
    if o.get("effort") is not None:
        parts.append("effort=%s" % o["effort"])
    if o.get("perTurnEffort") is not None:
        parts.append("perTurnEffort=%s" % o["perTurnEffort"])
    oc = (o.get("message") or {}).get("output_config")
    if isinstance(oc, dict) and oc.get("effort") is not None:
        parts.append("output_config.effort=%s" % oc["effort"])
    return "  ".join(parts) if parts else "transcript 無 effort 欄"

best = None  # (timestamp, path, model, effort, source)
scanned = 0
for path in glob.glob(os.path.join(proj, "**", "subagents", "*.jsonl"), recursive=True):
    if os.path.getmtime(path) < cutoff:
        continue
    scanned += 1
    name, source = agent_of(path)
    if name != agent:
        continue
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") != "assistant":
                continue
            ts = o.get("timestamp") or ""
            if best is None or ts >= best[0]:
                best = (ts, path, (o.get("message") or {}).get("model", "?"), effort_of(o), source)

if best is None:
    print("✗ 近 %d 天內（掃 %d 支 subagent transcript）找不到 agent「%s」的 assistant turn：%s"
          % (days, scanned, agent, proj), file=sys.stderr)
    sys.exit(1)
ts, path, model, effort, source = best
print("agent：%s（來源：%s）" % (agent, source))
print("model：%s" % model)
print("effort：%s" % effort)
print("時間：%s" % ts)
print("檔案：%s" % path)
PY
