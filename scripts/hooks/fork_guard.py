#!/usr/bin/env python3
# fork_guard.py — LS-254：擋 worker agent（非主 session）派 `subagent_type: fork`（PreToolUse hook
# 的判定引擎）。由 scripts/hooks/fork-guard.sh 呼叫（stdin 餵完整 hook JSON），本檔案不直接註冊進
# settings.json。
#
# 為什麼擋（一行）：fork 繼承派工單全文並把整項任務當成自己的平行執行——同一 .pen／branch 雙寫
# （LS-234 R7）、越權改他票檔案（LS-188／LS-192），三起皆為 worker agent 自己派的 fork、皆在派工
# prompt 明說禁止之後發生；研究改派 `Explore`（唯讀）或 `general-purpose` 並在 prompt 明寫唯讀。
#
# 規則（唯一一條）：hook JSON 頂層 `agent_id` 存在且為非空字串（＝subagent；身分判準照抄
# large_file_read_guard.py：CLI 2.1.270 hook schema 明載「Use this field (not agent_type)」，`--agent`
# 啟動的主 session 有 `agent_type` 無 `agent_id`）且 `tool_input.subagent_type == "fork"` → deny
# （stdout 一行理由、exit 2）。其餘一律 exit 0：主 session（`agent_id` 缺席）的 fork 照舊放行
# （orchestrator 自己的 fork 不受影響）；非 fork 類型（Explore／general-purpose／具名 agent）放行；
# `tool_name` 不是 Agent 放行（matcher 只掛 Agent，這裡是雙保險）。
#
# fail-open（票文明示；與 pretool.sh／large-file-read-guard.sh 的 fail-closed 極性相反）：stdin 空、
# JSON 壞、`agent_id` 存在但無法採信（型別不對／空字串）→ exit 0 並 stderr 註明。理由：本 gate 掛在
# Agent 工具上，fail-closed 會讓任一次解析失敗變成整條產線派不出任何 agent（含 orchestrator）；
# fail-open 的風險方向只是「漏放一次 fork」，agent 定義規則（agent-tools-check.sh 釘「禁派 fork」）
# ＋merge-reviewer scope 維度兜底。
#
# 已知盲區：只認 `subagent_type` 欄位字面 `fork`——worker 派 `general-purpose`／具名 agent 並在 prompt
# 要它寫檔，本 gate 不擋（那是 agent 定義「任何子 agent 不得寫檔／commit／改 PR／貼 Linear」的規約層，
# 機械層只擋「繼承全脈絡」這個最危險的形狀）；`agent_id` 欄位若未來改名，所有呼叫都會被判成主 session，
# 風險方向是「整支不擋」（與 large_file_read_guard.py 極性相反——那支擋主 session，全判主 session 是誤擋
# 整批；本支擋 subagent，全判主 session 是全放）。
import json
import sys

COLL_REF = "docs/COLLABORATION.md §7"
_MISSING = object()

DENY_REASON = (
    "LS-254：worker agent 禁派 fork（會繼承整份派工單並平行執行）；"
    "研究改派 `Explore`（唯讀）或 `general-purpose` 並在 prompt 明寫唯讀"
)


def _identity(d):
    """回傳 ("main"|"subagent"|"unknown", note)。判準是 `agent_id`（不是 `agent_type`）。
    欄位整個缺席 → main（不論 `agent_type` 是否存在）；存在且為非空字串 → subagent；存在但無法採信
    （型別不對／空字串）→ unknown（fail-open：寧可漏擋一次 fork，也不要擋掉身分不明的合法呼叫）。"""
    raw = d.get("agent_id", _MISSING)
    if raw is _MISSING:
        return "main", None
    if isinstance(raw, str) and raw.strip():
        return "subagent", None
    return (
        "unknown",
        f"agent_id 欄位存在但無法採信（值={raw!r}），身分不明，fail-open 放行（見 {COLL_REF}）",
    )


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        sys.stderr.write(f"fork-guard：stdin 是空的，無法判斷 tool_input，fail-open 放行（見 {COLL_REF}）\n")
        sys.exit(0)
    try:
        d = json.loads(raw)
        if not isinstance(d, dict):
            raise ValueError("top-level not object")
    except Exception:
        sys.stderr.write(f"fork-guard：hook JSON 無法解析，fail-open 放行（見 {COLL_REF}）\n")
        sys.exit(0)

    if d.get("tool_name") != "Agent":
        sys.exit(0)

    identity, note = _identity(d)
    if note:
        sys.stderr.write(f"fork-guard：{note}\n")
    if identity != "subagent":
        sys.exit(0)

    ti = d.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}
    if ti.get("subagent_type") == "fork":
        sys.stdout.write(DENY_REASON)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
