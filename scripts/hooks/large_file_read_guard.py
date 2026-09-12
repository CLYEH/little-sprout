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
#         （`_mask_quoted`，同 `background_bash_guard.py` 的既有作法）。R3（merge-review
#         R2 major 修正）：`ls`／`stat` 只讀 metadata、輸出恆為一行，不論它出現在 chain
#         的哪一段（不限最後一段）都算該 chain 有界——即使後面接了 `awk`／`cut` 之類
#         非白名單動詞，處理的也只是那一行 metadata、不是檔案內容（`_chain_is_bounded`）。
#   R3（merge-review R2 major）：chain 切分曾有兩個洞讓「有界讀取」仍被誤擋——
#       (1) `2>&1`／`&>`／`>&` 這類 fd 複製／合併重導向的 `&` 被 `CHAIN_SPLIT_RE` 當成
#       chain 分隔符（`tail -c 200000 <out> 2>&1 | grep … | tail -n 6` 被切成
#       `tail -c 200000 <out> 2>` ＋ `1 | grep … | tail -n 6`，前段判為無界）——同一份
#       主 session 語料裡「讀取動詞 … `2>&1` `\|`」這個慣用占 842 條命令的 6.6%。修法：
#       比照 `background_bash_guard.py`（LS-215）排除 fd 複製的既有作法，把單一 `&` 判定
#       改成「前後都不是 `&`／`>` 才算」（`(?<![&>])&(?!&|>)`），`&&` 仍照舊整組匹配。
#       (2) 多行管線行尾 `\|` 換行也被 `\n` 分隔符切開，切出的第一個 chain 最後一段是
#       空字串、`_stage_command_position` 回 `None`、判非有界。修法：切 chain 前先用
#       `_collapse_pipe_continuations` 把頂層（遮蔽後找位置，不誤觸引號內文）`\|` 後緊接
#       換行的續行摺成 `\| `，讓多行管線在切 chain 前先變回單行；`_bash_denies_tasks_output`
#       另外對每個 chain 切出的 pipe stage 做「捨棄尾端空白段」的防禦性兜底。
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
# 已知盲區（under-block：擋不到該擋的，記入 docs/COLLABORATION.md §7）：
#   - 變數間接（`O=<path>/tasks/x.output; grep ... "$O" | tail -3`）：本規則只認字面路徑，
#     把路徑存進變數再引用會繞過（LS-239 R2，票文明示「誠實記錄、不追」，見 §7）。
#   - Bash 側不做「任意大檔（非 tasks/*.output）＋讀取動詞」的一般化偵測——判斷任意 Bash
#     命令會讀哪個檔案、那個檔案多大，需要完整命令位置解析＋逐一 stat 每個候選路徑，成本與
#     誤判面遠高於 Read 工具的結構化 `file_path` 欄位；`cat some/other/large-file.md` 這類
#     不會被這支 gate 攔到。
#   - H-LF(b) 只看 `offset`／`limit` 有沒有出現、不看值——`limit: 100000`／`offset: 1` 一個
#     參數就能整檔讀（LS-239 R2 i2，票文接受此取捨，只記錄不修）。
#   - 直譯器 `-c`／heredoc payload（`python3 -c "open('tasks/x.output').read()"`）不遞迴解析。
#   - R3（merge-review R2 m2）：「一律有界」動詞清單本身就是整檔傾印的繞過口——
#     `grep '' <out>`（空 pattern 等於全部匹配，等同 cat）、`grep -A 99999 x <out>`
#     （context 行數大到等於整檔）、`rg --passthru x <out>`（`rg` 的 passthru 模式印出
#     全部行）、`echo <out> | xargs cat`（`xargs` 不在讀取動詞清單，`cat` 的目標從管線
#     間接帶入）、`FOO=1 cat <out>`（`_stage_command_position` 只看 `tokens[0]`，開頭是
#     `VAR=val` 賦值形式時整段就不是「乾淨的 cat」，判非讀取動詞而放行）——皆屬「有界動詞
#     清單」被繞過的已知形狀，票文允許「擋不到就誠實記」，本輪不修。
#   - i-A：H-LF(a) Bash 側 `-c` 上限 8192、H-LF(b) 的檔案大小門檻是 4096——兩者管的是不同
#     情境（(a) 是「窗口一次能吐多少位元組」、(b) 是「檔案多大才需要窗口」），數值不同不是
#     矛盾，但容易讓人誤會是同一把尺，記錄供日後參考。
#   - i-B：`tasks/*.output` 的 `limit ≤40` 是**行**界，不是位元組界——agent transcript
#     單行常達數十 KB（`agent-liveness-signal.md` 正因此用 `tail -c 200000` 而非
#     `tail -n`），40 行不等於「context 量有真的封頂」。Read 工具本身沒有位元組窗口參數
#     （只有 `offset`／`limit` 行數），這是 Read 工具介面的既有限制，本 gate 修不了；
#     40 行是保守估計，記錄供日後若要更嚴格控管時參考。
#
# 已知誤擋（over-block：擋了不該擋的，記入 docs/COLLABORATION.md §7；R3 merge-review m3
# 從上面「已知盲區」欄搬過來——語意不同：盲區是「漏放」，這裡是「錯擋」，混在一起會讓下一個
# 維護者誤以為這些是「本來就擋不住」而不去修）：
#   - `sed -n 'N,Mp' <out> | cut -c1-200`：`sed` 帶窄地址範圍（如 `2,5p`，只印 5 行）其實
#     是有界讀取，但本規則的「有界動詞」清單不含 `sed`／`cut`，最後一段是 `cut` 判非有界而
#     擋（真實流量僅 1 例，票文「不追」精神下本輪不修，但這是誤擋、不是漏放）。
#   - `cat <out> > /tmp/f`（整檔重導向到另一個檔案）：輸出根本沒有印到 stdout、不會進
#     orchestrator context，但本規則只看命令位置是不是有界動詞，不看有沒有重導向，一律
#     判非有界而擋——這是保守但不必要的誤擋。
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
# R3（merge-review R2 m1）：ls／stat 只讀 metadata、輸出恆為一行，出現在 chain 的哪一段都算
# 有界（不限最後一段）——見 _chain_is_bounded。
METADATA_ONLY_VERBS = {"ls", "stat"}

# R3（merge-review R2 major (1)）：排除 fd 複製／合併重導向的 `&`（`2>&1`／`&>`／`>&`）——
# 同 background_bash_guard.py（LS-215）既有作法：前後都不是 `&`／`>` 才算真正的背景化 `&`。
CHAIN_SPLIT_RE = re.compile(r"&&|\|\||;|(?<![&>])&(?!&|>)|\n")
PIPE_SPLIT_RE = re.compile(r"\|(?!\|)")
# R3（merge-review R2 major (2)）：頂層 `|` 後緊接換行（含行首縮排）視為續行，切 chain 前
# 先摺成同一行，避免多行管線的行尾 `|` 被 CHAIN_SPLIT_RE 的 `\n` 切開、切出空 stage。
LINE_CONTINUATION_PIPE_RE = re.compile(r"\|[ \t]*\n[ \t]*")

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


def _collapse_pipe_continuations(text):
    """R3（merge-review R2 major (2)）：把頂層（遮蔽引號內文後找位置，不誤觸引號內的
    `|` 或換行）`|` 後緊接換行的續行摺成 `| `，讓多行管線在切 chain 前先變回單行——否則
    `CHAIN_SPLIT_RE` 的 `\\n` 會把 `cmd1 |\\n  cmd2` 切成兩個 chain，第一個 chain 最後一段
    是空字串、被誤判非有界。"""
    masked = _mask_quoted(text)
    out = []
    last = 0
    for m in LINE_CONTINUATION_PIPE_RE.finditer(masked):
        out.append(text[last:m.start()])
        out.append("| ")
        last = m.end()
    out.append(text[last:])
    return "".join(out)


# R3（真實流量重放發現：`for a in x y; do ls -la "$S/tasks/$a.output" | awk …; done` 這種
# for 迴圈，naive `;` 切段會把 `do ls -la …` 切成同一段，tokens[0] 是 `do` 不是 `ls`，讓
# has_read_verb／_chain_is_bounded 都認不出真正的命令）：跳過這幾個會出現在切段開頭、
# 本身不是命令的 shell 保留字，取後面第一個真正的 token。只列會在本規則的切段方式下卡在
# 開頭的形狀（for/while/until 的主體用 `do`；if/case 的替代分支用 `then`／`else`），不做
# 完整 shell 語法解析。
_LEADING_KEYWORDS_TO_SKIP = {"do", "then", "else"}


def _stage_command_position(stage_text):
    tokens = stage_text.strip().split()
    idx = 0
    while idx < len(tokens) and tokens[idx] in _LEADING_KEYWORDS_TO_SKIP:
        idx += 1
    if idx >= len(tokens):
        return None
    return tokens[idx].rsplit("/", 1)[-1]


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


def _chain_is_bounded(stages):
    """R3（merge-review R2 m1）：ls／stat 出現在管線任一段（不限最後一段）就算整個 chain
    有界——這兩支動詞的輸出恆為一行 metadata，後面接 awk／cut 之類非白名單動詞處理的也只是
    那一行，不是檔案內容本身，跟「最後一段是不是有界形狀」的判準無關。"""
    if any(_stage_command_position(s) in METADATA_ONLY_VERBS for s in stages):
        return True
    non_empty = [s for s in stages if s.strip()]
    last_stage = non_empty[-1] if non_empty else (stages[-1] if stages else "")
    return _stage_is_bounded(last_stage)


def _bash_denies_tasks_output(command):
    """R2（merge-review R1 B1）：有界讀取放行、無界讀取擋。回傳 True＝該擋。"""
    stripped, _bad = E.strip_heredocs(command)
    stripped = _collapse_pipe_continuations(stripped)  # R3：多行管線先摺成單行
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
        if not _chain_is_bounded(stages):
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
            limit_val = ti.get("limit")
            if _valid_bounded_limit(limit_val, TASKS_OUTPUT_LIMIT_MAX):
                sys.exit(0)
            # R3（merge-review R2 i-C）：區分「根本沒帶 limit」與「帶了但型別／數值不合法」，
            # 讓 deny 理由能一眼看出問題在哪，不用回頭翻程式碼。
            if limit_val is None:
                detail = "沒帶 limit"
            else:
                detail = f"limit 型別或數值不合法（收到 {limit_val!r}，需為 1–{TASKS_OUTPUT_LIMIT_MAX} 的整數）"
            sys.stdout.write(
                f"H-LF(a)：orchestrator 不得直接 Read tasks/*.output（{detail}）——"
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
