#!/usr/bin/env python3
"""按 model／agent 彙總 Claude Code transcript 的 token 用量與牌價估值（LS-353，整理自 LS-350 scratchpad 版）。

用法：python3 scripts/ops/model-usage-report.py [--days N]   （預設 14 天）

掃描範圍：${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<專案 slug>/**/*.jsonl（主 session＋subagent），只看
mtime 在近 N 天內的檔。專案 slug 由 git-common-dir 推導（主 checkout 絕對路徑、非英數字元換成 -），
不寫死使用者名。多帳號各自的 config dir 要分開跑（CLAUDE_CONFIG_DIR=<dir>）。

agent 辨識：主 session 記為 main；subagent 優先讀同名 `agent-*.meta.json` 的 `agentType`，沒有 sidecar 才退回
「首則 user 訊息含 agent 名稱」（原 LS-350 做法）；都認不出記為 subagent:?。
同一 message.id 在 transcript 內會重複出現（串流分段），只計一次。

估值用下方 PRICES（API 牌價，$／百萬 token）；前提假設：用量方案的額度扣減大致依 API 牌價（未經官方確認）。
model 以「最長前綴」對表，避免 claude-opus-5-5 被 claude-opus-5 那列吃掉（LS-350 原版依 dict 順序取第一個
前綴相符者，Opus 5.5 會被算成 Opus 5 的價）。表上沒有的 model 估值記 0 並在輸出列出。

自測：scripts/ops/model-usage-report.test.sh（CI rules job）。
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict

# 牌價表（2026-09-23 查；$／百萬 token：input, output, cache read, cache write 5m＝input×1.25）
PRICES = {
    "claude-fable-5-1": (10, 50, 1.0, 12.5),
    "claude-opus-5": (5, 25, 0.5, 6.25),
    "claude-opus-5-5": (4, 20, 0.2, 5),  # 排在 opus-5 之後：對表靠最長前綴、不靠順序
    "claude-sonnet-5": (2, 10, 0.2, 2.5),
    "claude-haiku-4-5": (1, 5, 0.1, 1.25),
}
KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
KNOWN = r"(ios-dev|merge-reviewer|visual-reviewer|ui-designer|dead-code-sweeper|\bqa\b)"


def project_dir():
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("✗ 不在 git repo 內，無法推導專案 slug")
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.dirname(common))
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(base, "projects", slug)


def price_of(model):
    best = None
    for k, p in PRICES.items():
        if model.startswith(k) and (best is None or len(k) > len(best[0])):
            best = (k, p)
    return best[1] if best else None


def cost(model, u):
    p = price_of(model)
    if p is None:
        return 0.0
    return sum(u[k] * p[i] for i, k in enumerate(KEYS)) / 1e6


def agent_from_meta(path):
    meta = path[:-len(".jsonl")] + ".meta.json"
    try:
        with open(meta, encoding="utf-8") as f:
            return json.load(f).get("agentType")
    except (OSError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser(description="按 model／agent 彙總 transcript token 與牌價估值")
    ap.add_argument("--days", type=int, default=14)
    args = ap.parse_args()

    root = project_dir()
    if not os.path.isdir(root):
        sys.exit("✗ 找不到專案 transcript 目錄：%s" % root)
    cutoff = time.time() - args.days * 86400

    by_model = defaultdict(lambda: defaultdict(int))
    by_agent = defaultdict(lambda: defaultdict(int))
    files = 0
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        if os.path.getmtime(path) < cutoff:
            continue
        files += 1
        is_sub = os.sep + "subagents" + os.sep in path
        agent = "main"
        if is_sub:
            t = agent_from_meta(path)
            agent = ("subagent:" + t) if t else "subagent:?"
        need_prompt = agent == "subagent:?"
        seen = set()
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if need_prompt and o.get("type") == "user":
                    need_prompt = False
                    c = o.get("message", {}).get("content")
                    txt = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
                    m = re.search(KNOWN, txt[:4000])
                    if m:
                        agent = "subagent:" + m.group(1)
                if o.get("type") != "assistant":
                    continue
                msg = o.get("message") or {}
                mid = msg.get("id")
                if mid:
                    if mid in seen:
                        continue
                    seen.add(mid)
                model = msg.get("model", "?")
                u = msg.get("usage") or {}
                for k in KEYS:
                    v = u.get(k, 0) or 0
                    by_model[model][k] += v
                    by_agent[agent][k] += v
                by_model[model]["turns"] += 1
                by_agent[agent]["turns"] += 1
                by_agent[agent]["cost_micro"] += int(cost(model, {k: u.get(k, 0) or 0 for k in KEYS}) * 1e6)

    print("files=%d days=%d root=%s" % (files, args.days, root))
    print("\n== by model（M tokens；est $ 依檔頭牌價表）")
    print("%-28s %7s %7s %7s %8s %8s %8s" % ("model", "turns", "in", "out", "cacheR", "cacheW", "est$"))
    total = 0.0
    unpriced = []
    for m, u in sorted(by_model.items(), key=lambda kv: -cost(kv[0], kv[1])):
        c = cost(m, u)
        total += c
        if price_of(m) is None:
            unpriced.append(m)
        print("%-28s %7d %7.1f %7.1f %8.1f %8.1f %8.2f" % (
            m, u["turns"], u["input_tokens"] / 1e6, u["output_tokens"] / 1e6,
            u["cache_read_input_tokens"] / 1e6, u["cache_creation_input_tokens"] / 1e6, c))
    print("%-28s %7s %7s %7s %8s %8s %8.2f" % ("TOTAL", "", "", "", "", "", total))
    if unpriced:
        print("（牌價表無此 model、估值記 0：%s）" % ", ".join(sorted(unpriced)))

    print("\n== by agent（M tokens；est $ 依各 turn 的 model 計價）")
    print("%-28s %7s %7s %7s %8s %8s %8s" % ("agent", "turns", "in", "out", "cacheR", "cacheW", "est$"))
    for a, u in sorted(by_agent.items(), key=lambda kv: -kv[1]["cost_micro"]):
        print("%-28s %7d %7.1f %7.1f %8.1f %8.1f %8.2f" % (
            a, u["turns"], u["input_tokens"] / 1e6, u["output_tokens"] / 1e6,
            u["cache_read_input_tokens"] / 1e6, u["cache_creation_input_tokens"] / 1e6,
            u["cost_micro"] / 1e6))


if __name__ == "__main__":
    main()
