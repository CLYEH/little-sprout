#!/usr/bin/env python3
# large_file_read_guard.py — LS-239 範圍 2：擋 orchestrator（主 session）直接把大檔讀進
# context（PreToolUse hook 的判定引擎）。由 scripts/hooks/large-file-read-guard.sh 呼叫
# （stdin 餵完整 hook JSON），本檔案不直接註冊進 settings.json。
#
# 來源：使用者 2026-09-13 裁決——orchestrator 一天約 55 次巡檢，每次把 patrol.sh 全文＋派工
# prompt 讀進 context，粗估日耗 50 萬 token 以上；「orchestrator 不直接讀大檔——agent handoff
# 檔、`tasks/<id>.output`、Linear comment 串、COLLABORATION.md 章節、任何超過約 4 KB 的檔案
# ——一律派 Explore subagent 讀完回結論」寫進 §1／§4-b 規則句後，依 §0「新增重要規則＝同時
# 新增 gate」在此補機械攔截；只攔得住 Read／Bash 兩種工具（見下方「已知盲區」）。
#
# 身分信號：同 scripts/hooks/background_bash_guard.py 檔頭記載的驗證結果（PreToolUse hook 的
# stdin JSON 對 subagent 發出的工具呼叫頂層帶 `agent_type`，主 session 直接發出的呼叫兩者皆
# 缺席）。與 background_bash_guard.py 的極性相反——這裡刻意只在「確定是主 session」（欄位整個
# 缺席）時才動作，欄位存在但無法採信（型別不對／空字串）一律視為「非主 session」放行（fail-open
# 方向不變，但套用對象是反過來的：background_bash_guard 是「查不到身分就不擋」，這裡是「查不到
# 『是不是主 session』就不擋」，兩者都是同一個「不確定就不擋」的原則，只是規則的預設值極性不同）。
#
# 規則（任一命中即 deny：stdout 印一行 reason、exit 2；否則 exit 0）：
#   H-LF(a)（Read／Bash）：目標路徑符合 `tasks/<id>.output` 樣式（任一路徑分段為 `tasks`、
#       檔名以 `.output` 結尾）——Agent 工具背景任務輸出檔的慣用路徑，不論實際大小一律算「大
#       檔」類別（不必等真的超過門檻）。Bash 側只認得「讀取動詞（cat／less／head／tail／
#       more／bat／nl／sed／awk／cut／grep／rg／jq／perl／open）＋同一管線段落內出現
#       `tasks/*.output` 字面」這一種形狀（窄範圍比對，不做完整命令位置解析——見下方盲區）。
#   H-LF(b)（Read only）：`tool_input.file_path` 存在且可 stat 到大小 > 4096 bytes（約 4 KB，
#       票文原話），且 `offset`／`limit` 兩者皆缺席（帶任一個視為「已限縮讀取範圍」，放行）。
#       檔案不存在／無法 stat（權限、路徑錯）不擋——交給 Read 工具自己報錯。
#
# 已知盲區（記入 docs/COLLABORATION.md §7）：
#   - Bash 側不做「任意大檔＋讀取動詞」的一般化偵測（只認 tasks/*.output 這個窄樣式）——判斷
#     「這個 Bash 命令會讀哪個檔案、那個檔案多大」需要完整命令位置解析＋逐一 stat 每個候選路
#     徑，成本與誤判面（管線、變數展開、動態路徑）都遠高於 Read 工具（Read 工具的 file_path 是
#     結構化欄位，不必猜）；`cat some/other/large-file.md` 這類不會被這支 gate 攔到。
#   - 直譯器 `-c`／heredoc payload（`python3 -c "open('tasks/x.output').read()"`）不遞迴解析。
#   - `agent_type` 欄位若未來改名或 schema 有差異，本規則的「缺席＝主 session」判準會整支失
#     效（風險方向是「整支不擋」，不是「誤擋 subagent」，與 background_bash_guard.py 同一個
#     容錯方向）。
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pretool_engine as E  # noqa: E402 — 只借用 strip_heredocs（heredoc／comment 剝除）

COLL_REF = "docs/COLLABORATION.md §7"
SIZE_LIMIT_BYTES = 4096  # 約 4 KB，票文原話

TASKS_OUTPUT_RE = re.compile(r"(?:^|/)tasks/[^/\s]*\.output$")
READ_VERB_TASKS_OUTPUT_RE = re.compile(
    r"\b(?:cat|less|head|tail|more|bat|nl|sed|awk|cut|grep|rg|jq|perl|open)\b[^\n;&|]*"
    r"(?:^|[^A-Za-z0-9_])tasks/[^\s'\"]*\.output\b"
)

_MISSING = object()


def _is_main_session(d):
    """回傳 (is_main_session, note)。`agent_type` 欄位整個缺席 → (True, None)（主 session）；
    欄位存在且為非空字串 → (False, None)（subagent，不在本規則範圍）；欄位存在但無法採信
    （型別不對／空字串）→ (False, note)（身分不明，fail-open——刻意跟『缺席』分開判定，不能
    把『查不到』與『確定是主 session』混成同一種結果）。"""
    raw = d.get("agent_type", _MISSING)
    if raw is _MISSING:
        return True, None
    if isinstance(raw, str) and raw.strip():
        return False, None
    return (
        False,
        f"agent_type 欄位存在但無法採信（值={raw!r}），視為非主 session，fail-open（見 {COLL_REF}）",
    )


def _is_tasks_output(path):
    if not path:
        return False
    return bool(TASKS_OUTPUT_RE.search(str(path).replace(os.sep, "/")))


def _large_without_window(file_path, offset, limit):
    if not file_path:
        return False
    if offset is not None or limit is not None:
        return False
    try:
        size = os.path.getsize(file_path)
    except OSError:
        return False  # 讀不到大小（檔案不存在／權限）——交給 Read 工具自己報錯，這裡不擋
    return size > SIZE_LIMIT_BYTES


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        sys.stdout.write(f"H-LF0：stdin 是空的，無法判斷 tool_input（fail-closed），見 {COLL_REF}")
        sys.exit(2)
    try:
        d = json.loads(raw)
        if not isinstance(d, dict):
            raise ValueError("top-level not object")
    except Exception:
        sys.stdout.write(f"H-LF0：hook JSON 無法解析（fail-closed），見 {COLL_REF}")
        sys.exit(2)

    tool_name = d.get("tool_name")
    if tool_name not in ("Read", "Bash"):
        sys.exit(0)

    is_main, note = _is_main_session(d)
    if note:
        sys.stderr.write(f"large-file-read-guard：{note}\n")
    if not is_main:
        sys.exit(0)

    ti = d.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}

    if tool_name == "Read":
        file_path = ti.get("file_path")
        if _is_tasks_output(file_path):
            sys.stdout.write(
                "H-LF(a)：orchestrator 不得直接 Read tasks/*.output（agent 背景任務輸出）——"
                f"派 Explore subagent 讀完回結論，見 {COLL_REF}"
            )
            sys.exit(2)
        if _large_without_window(file_path, ti.get("offset"), ti.get("limit")):
            sys.stdout.write(
                "H-LF(b)：orchestrator 不得直接 Read 超過約 4 KB 的檔案又不帶 offset／limit——"
                f"派 Explore subagent 讀完回結論（附檔案:行號引據），見 {COLL_REF}"
            )
            sys.exit(2)
        sys.exit(0)

    # tool_name == "Bash"
    command = str(ti.get("command") or "")
    stripped, _bad = E.strip_heredocs(command)
    if READ_VERB_TASKS_OUTPUT_RE.search(stripped):
        sys.stdout.write(
            "H-LF(a)：orchestrator 不得直接用 Bash 讀取 tasks/*.output（agent 背景任務輸出）——"
            f"派 Explore subagent 讀完回結論，見 {COLL_REF}"
        )
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
