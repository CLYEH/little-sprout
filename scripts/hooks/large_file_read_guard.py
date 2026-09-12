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
# 身分信號（R2／merge-review R1 M2 修正）：判準是 `agent_id`，**不是** `agent_type`——本機安裝的
# CLI 2.1.270 執行檔內建的 hook 輸入 schema 字面明載：`agent_id` 「Present only when the hook
# fires from within a subagent … Absent for the main thread, even in --agent sessions. Use
# this field (not agent_type) to distinguish subagent calls from main-thread calls.」；
# `agent_type` 則「Present when the hook fires from within a subagent (alongside agent_id),
# or on the main thread of a session started with --agent (without agent_id)」——換句話說，
# 以 `--agent` 啟動的主 session 也會帶 `agent_type`（但不會有 `agent_id`），R1 版本拿
# `agent_type` 判斷會把這種主 session 誤判成 subagent、整支放行（假陰）。`agent_id` 欄位整個
# 缺席 → 主 session（不論 `agent_type` 是否存在）；欄位存在且為非空字串 → subagent；欄位存在
# 但無法採信（型別不對／空字串）→ 身分不明，fail-open（視為非主 session，放行）——**風險方向
# 是「誤擋整批 agent 呼叫」，不是「整支不擋」**：若未來 `agent_id` 改名或 schema 有差異，
# `d.get("agent_id", _MISSING)` 對所有呼叫（含真正的 subagent）都會找不到該欄位，結果是
# 「每一通呼叫都被判成主 session」而不是「每一通都判成非主 session」——這與 R1 版本用
# `agent_type` 時寫反的說法相反，也與 `background_bash_guard.py`（LS-215，那支的判準欄位
# `agent_type` 目前仍有效、風險方向是「查不到就不擋」）不同極性，不能沿用同一句容錯敘述。
#
# 規則（任一命中即 deny：stdout 印一行 reason、exit 2；否則 exit 0）：
#   H-LF(a)（Read／Bash）：目標路徑符合 `tasks/<id>.output` 樣式（任一路徑分段為 `tasks`、
#       檔名以 `.output` 結尾）——Agent 工具背景任務輸出檔的慣用路徑（現行 CLI 寫在
#       `/private/tmp/.../tasks/<id>.output`，`agent-liveness-signal.md` 判活性即讀這裡）。
#       R2（merge-review R1 B1 修正）：**有界讀取放行、無界讀取擋**，不再整批攔死——
#       - Read：帶 `limit` 且為 ≤40 的正整數 → 放行；否則（`limit` 缺席／非法／>40）→ 擋。
#       - Bash：讀取動詞（`cat`／`less`／`head`／`tail`／`more`／`bat`／`nl`／`sed`／`awk`／
#         `cut`／`grep`／`rg`／`jq`／`perl`／`open`／`wc`／`stat`／`ls`）出現在某個「chain」
#         （以頂層 `;`／`&&`／`\|\|`／單一 `&`／換行切分，`\|` 管線不切 chain）裡、且該
#         chain 的原始文字含 `tasks/*.output` 字面時，看該 chain 管線的**最後一段**
#         （以頂層 `\|` 切分）是否為「有界／摘要」形狀：`grep`／`rg`／`wc`／`stat`／`ls`
#         一律算有界；`head`／`tail` 帶 `-n`／`--lines`／`-c`／`--bytes`／裸 `-N`
#         旗標且數值 ≤ 上限（行 ≤40、位元組 ≤8192）算有界。最後一段是有界形狀 → 該
#         chain 放行；否則擋（`cat`／無旗標的 `head`／`tail`／`less`／`more`／`bat`／
#         整檔重導向皆落在「不是有界形狀」而擋）。頂層 `;`／`\|`／引號／`$(...)` 判定
#         重用 `pretool_engine` 的引號／命令替換掃描函式遮蔽後再切，不重寫一套跳脫規則
#         （`_mask_quoted`，同 `background_bash_guard.py` 的既有作法）。
#   H-LF(b)（Read only；不適用 `tasks/*.output`，那個路徑走 H-LF(a) 自己的門檻）：
#       `tool_input.file_path` 存在、不是圖片／PDF（見下）、且可 stat 到是一般檔案、大小
#       > 4096 bytes（約 4 KB，票文原話），且 `offset`／`limit` 兩者皆缺席（帶任一個視為
#       「已限縮讀取範圍」，放行——**只看有沒有帶，不看值**，`limit: 100000` 一樣放行，
#       見下方已知盲區）。R2（merge-review R1 M1 修正）：副檔名為
#       `.png/.jpg/.jpeg/.gif/.webp/.heic/.pdf`（大小寫不分）時整支跳過本規則——圖片
#       沒有等價的「限縮讀取範圍」語意，`limit` 對圖片是 no-op（仍回整張），擋了既不省
#       context 也擋住正常的視覺驗收流程。R2（i5 修正）：目標不是一般檔案（目錄／不存在／
#       特殊檔）不擋——交給 Read 工具自己報錯，不對「Read 工具本來就會拒的呼叫」印出
#       誤導的 deny 理由。
#
# 已知盲區（記入 docs/COLLABORATION.md §7）：
#   - 變數間接（`O=<path>/tasks/x.output; grep ... "$O" | tail -3`）：本規則只認字面路徑，
#     把路徑存進變數再引用會繞過（LS-239 R2，票文明示「誠實記錄、不追」，見 §7）。
#   - Bash 側不做「任意大檔（非 tasks/*.output）＋讀取動詞」的一般化偵測——判斷任意 Bash
#     命令會讀哪個檔案、那個檔案多大，需要完整命令位置解析＋逐一 stat 每個候選路徑，成本與
#     誤判面遠高於 Read 工具的結構化 `file_path` 欄位；`cat some/other/large-file.md` 這類
#     不會被這支 gate 攔到。
#   - H-LF(b) 只看 `offset`／`limit` 有沒有出現、不看值——`limit: 100000`／`offset: 1` 一個
#     參數就能整檔讀（LS-239 R2 i2，票文接受此取捨，只記錄不修）。
#   - 直譯器 `-c`／heredoc payload（`python3 -c "open('tasks/x.output').read()"`）不遞迴解析。
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pretool_engine as E  # noqa: E402 — 只借用 strip_heredocs／引號掃描函式

COLL_REF = "docs/COLLABORATION.md §7"
SIZE_LIMIT_BYTES = 4096  # 約 4 KB，票文原話
TASKS_OUTPUT_LIMIT_MAX = 40  # H-LF(a) Read 側：tasks/*.output 的 limit 上限
BOUNDED_MAX_LINES = 40  # H-LF(a) Bash 側：head/tail -n 上限
BOUNDED_MAX_BYTES = 8192  # H-LF(a) Bash 側：head/tail -c 上限
IMAGE_PDF_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".pdf"}

TASKS_OUTPUT_RE = re.compile(r"(?:^|/)tasks/[^/\s]*\.output$")
TASKS_OUTPUT_TOKEN_RE = re.compile(r"(?:^|[^A-Za-z0-9_])tasks/[^\s'\"]*\.output\b")

# R2（merge-review R1 B1）：讀取動詞清單擴充 wc／stat／ls（原本漏列，這三支本身輸出就是摘要，
# 一律算有界；同時也是「這個 chain 有在讀檔」的判準之一，見 _bash_denies_tasks_output）。
READ_VERBS_FOR_TASKS = {
    "cat", "less", "head", "tail", "more", "bat", "nl", "sed", "awk", "cut",
    "grep", "rg", "jq", "perl", "open", "wc", "stat", "ls",
}
ALWAYS_BOUNDED_LAST_STAGE = {"grep", "rg", "wc", "stat", "ls"}

CHAIN_SPLIT_RE = re.compile(r"&&|\|\||;|&(?!&)|\n")
PIPE_SPLIT_RE = re.compile(r"\|(?!\|)")

_LINES_FLAG_RE = re.compile(r"--lines=(\d+)|-n\s*(\d+)")
_BYTES_FLAG_RE = re.compile(r"--bytes=(\d+)|-c\s*(\d+)")
_BARE_N_RE = re.compile(r"(?:^|\s)-(\d+)(?:\s|$)")

_MISSING = object()


def _is_main_session(d):
    """回傳 (is_main_session, note)。判準是 `agent_id`（不是 `agent_type`，見檔頭 R2 說明）。
    `agent_id` 欄位整個缺席 → (True, None)（主 session，不論 `agent_type` 是否存在）；欄位
    存在且為非空字串 → (False, None)（subagent）；欄位存在但無法採信（型別不對／空字串）→
    (False, note)（身分不明，fail-open：寧可漏擋，也不要誤擋整批 agent 呼叫）。"""
    raw = d.get("agent_id", _MISSING)
    if raw is _MISSING:
        return True, None
    if isinstance(raw, str) and raw.strip():
        return False, None
    return (
        False,
        f"agent_id 欄位存在但無法採信（值={raw!r}），視為非主 session，fail-open（見 {COLL_REF}）",
    )


def _is_tasks_output(path):
    if not path:
        return False
    return bool(TASKS_OUTPUT_RE.search(str(path).replace(os.sep, "/")))


def _valid_bounded_limit(value, max_value):
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return 0 < value <= max_value
    return False


def _large_without_window(file_path, offset, limit):
    if not file_path:
        return False
    if offset is not None or limit is not None:
        return False
    ext = os.path.splitext(str(file_path))[1].lower()
    if ext in IMAGE_PDF_EXTS:
        return False  # R2 M1：圖片／PDF 沒有等價 window 語意，整支跳過
    try:
        if not os.path.isfile(file_path):
            return False  # R2 i5：目錄／不存在／特殊檔交給 Read 工具自己報錯
        size = os.path.getsize(file_path)
    except OSError:
        return False
    return size > SIZE_LIMIT_BYTES


def _mask_quoted(text):
    """把單／雙引號內文、`$'...'`、`$(...)`／反引號內文換成等長空白，只留下真正在 shell
    頂層、會被解讀成語法的字元——重用 pretool_engine 既有的引號／命令替換掃描函式，不重寫
    一套跳脫規則（同 background_bash_guard.py 的既有作法，這裡再複製一份避免跨檔案耦合
    private 函式的呼叫面）。引號／`$(...)` 不平衡（Ambiguous）時保守放棄遮蔽、回傳原始文字。
    """
    n = len(text)
    i = 0
    out = []
    try:
        while i < n:
            ch = text[i]
            if ch == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            if ch == "$" and i + 1 < n and text[i + 1] == "'":
                _content, j = E._scan_ansi_c_quote(text, i + 2, n)
                out.append(" " * (j - i))
                i = j
                continue
            if ch == "'":
                j = text.find("'", i + 1)
                if j == -1:
                    raise E.Ambiguous()
                out.append(" " * (j + 1 - i))
                i = j + 1
                continue
            if ch == "$" and i + 1 < n and text[i + 1] == "(":
                _inner, j = E._scan_cmdsub(text, i + 2, n)
                out.append(" " * (j - i))
                i = j
                continue
            if ch == "`":
                j = text.find("`", i + 1)
                if j == -1:
                    raise E.Ambiguous()
                out.append(" " * (j + 1 - i))
                i = j + 1
                continue
            if ch == '"':
                _buf, j = E._scan_dquote(text, i + 1, n, [])
                out.append(" " * (j - i))
                i = j
                continue
            out.append(ch)
            i += 1
    except E.Ambiguous:
        return text
    return "".join(out)


def _split_by_masked_pairs(text, masked, pattern):
    """依 `pattern` 在 `masked`（與 text 等長、引號內文已遮蔽）裡找到的切點，把 `text`
    切成保留原文（含引號）的子字串清單。"""
    parts = []
    last = 0
    for m in pattern.finditer(masked):
        parts.append(text[last:m.start()])
        last = m.end()
    parts.append(text[last:])
    return parts


def _stage_command_position(stage_text):
    tokens = stage_text.strip().split()
    if not tokens:
        return None
    return tokens[0].rsplit("/", 1)[-1]


def _stage_is_bounded(stage_text):
    cmd = _stage_command_position(stage_text)
    if cmd in ALWAYS_BOUNDED_LAST_STAGE:
        return True
    if cmd not in ("head", "tail"):
        return False
    m = _LINES_FLAG_RE.search(stage_text)
    if m:
        n = int(m.group(1) or m.group(2))
        if n <= BOUNDED_MAX_LINES:
            return True
    m = _BYTES_FLAG_RE.search(stage_text)
    if m:
        n = int(m.group(1) or m.group(2))
        if n <= BOUNDED_MAX_BYTES:
            return True
    m = _BARE_N_RE.search(stage_text)
    if m and int(m.group(1)) <= BOUNDED_MAX_LINES:
        return True
    return False


def _bash_denies_tasks_output(command):
    """R2（merge-review R1 B1）：有界讀取放行、無界讀取擋。回傳 True＝該擋。"""
    stripped, _bad = E.strip_heredocs(command)
    masked = _mask_quoted(stripped)
    for chain in _split_by_masked_pairs(stripped, masked, CHAIN_SPLIT_RE):
        if not TASKS_OUTPUT_TOKEN_RE.search(chain):
            continue
        chain_masked = _mask_quoted(chain)
        stages = _split_by_masked_pairs(chain, chain_masked, PIPE_SPLIT_RE)
        has_read_verb = any(
            _stage_command_position(stage) in READ_VERBS_FOR_TASKS for stage in stages
        )
        if not has_read_verb:
            continue  # 例如純變數賦值 O=<path>/tasks/x.output，沒有讀取動詞，非本規則對象
        if not _stage_is_bounded(stages[-1]):
            return True
    return False


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
            if _valid_bounded_limit(ti.get("limit"), TASKS_OUTPUT_LIMIT_MAX):
                sys.exit(0)
            sys.stdout.write(
                "H-LF(a)：orchestrator 不得直接 Read tasks/*.output 又不帶 limit（≤40）——"
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
    if _bash_denies_tasks_output(command):
        sys.stdout.write(
            "H-LF(a)：orchestrator 不得直接用 Bash 無界讀取 tasks/*.output（如裸 cat／less／"
            "整檔重導向）——改用 head/tail -n（≤40）／-c（≤8192）或 grep/wc/stat/ls 收尾，"
            f"見 {COLL_REF}"
        )
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
