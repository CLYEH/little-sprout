#!/usr/bin/env python3
# background_bash_guard.py — LS-215：擋 agent（ios-dev／qa／merge-reviewer／dead-code-sweeper／
# ui-designer／visual-reviewer）背景 Bash（`run_in_background:true`）與「背景化再等」命令文字慣用
# 形狀（PreToolUse hook 的判定引擎）。由 scripts/hooks/background-bash-guard.sh 呼叫（stdin 餵完整
# hook JSON），本檔案不直接註冊進 settings.json。
#
# 來源：LS-96 池項 c593b5cf（2026-09-06 09:33，來源 LS-209 收尾 lesson `c50054be`／LS-192 lesson
# `c70eb812`）：「不使用背景 Bash」規約（ios-dev.md／qa.md／merge-reviewer.md 正文）落地後，同日仍有
# 三起 agent 停在等背景通知（LS-210 push、LS-190 R2 tap-target 為規約落地前的舊定義、LS-193
# push-gate 為落地後的新定義）——規約只靠 agent 自律、沒有機械 gate，本票升 PreToolUse。
#
# 身分信號（LS-215 實測結果，見票 handoff「已驗證」段的完整佐證鏈；本檔案只信任下面這條路徑，
# 找不到就 fail-open、不擋）：
#   Claude Code 官方 hooks 文件（code.claude.com/docs/en/hooks、code.claude.com/docs/en/sub-agents.md，
#   經 claude-code-guide agent 以 WebFetch 查證）記載：PreToolUse hook 的 stdin JSON 對「由 Task/Agent
#   工具以某個 subagent_type 呼叫的 subagent」所發出的工具呼叫，會在頂層多帶 `agent_id`／`agent_type`
#   兩個欄位，`agent_type` 的值＝該 subagent 定義的名稱（對應 `.claude/agents/<name>.md` 的
#   frontmatter／`subagent_type` 參數，如 "ios-dev"／"qa"）；由主 session（orchestrator）直接發出的
#   工具呼叫則兩者皆缺席。文件亦記載 subagent 會繼承並套用父層 `.claude/settings.json` 的
#   PreToolUse hook（不是獨立、未受管控的執行環境）。交叉佐證：對本機安裝的 Claude Code CLI 執行檔
#   （`~/.local/share/claude/versions/<版本>`）跑 `strings` 反查，找到原始碼字面
#   `"agent_type"in n?n.agent_type:void 0` 這行，出現在明顯與 hook 執行相關（鄰近字面
#   `hook_cancelled`／`hookName`／`hookEvent`／`toolUseID`）的程式碼路徑上，作為呼叫 hook 執行函式的
#   最後一個參數——與文件描述的「一個條件式存在的 agent_type 訊號會被傳遞給 hook 執行路徑」一致。
#   **R2（merge-review R1 APPROVE，LS-215 comment d2f1ae1c）獨立核實**：reviewer 對更新一版的執行檔
#   （2.1.261，實作者原驗 2.1.260）反查出完整 hook 輸入 schema 與組裝函式原始碼字面，逐字確認
#   `agent_type` 確實在 PreToolUse stdin JSON 頂層、主 session（未帶 `--agent` 啟動時）確實缺席、
#   `BLOCKED_AGENTS` 六個字串與 `.claude/agents/*.md` frontmatter `name:` 逐字相符——規則 (a) 的信號
#   真實存在，不是猜測。**未做到的驗證仍是**：在本 session 內對「主 checkout 的 settings.json」新增
#   除錯 hook 做端到端 runtime capture（那會違反「只在票 worktree 作業」與 main-checkout-guard 本身的
#   W1／W2，且不在本票範圍；待 `/hooks` 重載後由 orchestrator 派 ios-dev 最小任務實測，見票文驗收）。
#   容錯方向（找不到欄位＝視同主 session、不擋）確保萬一版本間 schema 有差異，這個風險只會讓 gate
#   「整支失效」而不會「誤擋主 session」，符合票文「查不到身分不擋」的裁決。
#   R2（merge-review N4，informational，不修）：票文列舉的備援訊號（頂層 `agent_name` 欄位、環境變數
#   `CLAUDE_AGENT_TYPE`／`CLAUDE_AGENT_NAME`）經 reviewer 對 2.1.261 執行檔反查，三者出現次數皆為
#   0（對照 `CLAUDE_PROJECT_DIR` 46 次），hook schema 也沒有 `agent_name` 欄位——確認是死碼，且同時
#   構成一個（極小的）誤判面：外部行程若剛好 export 同名環境變數會讓主 session 被誤判成 subagent。
#   R2 已移除這三個備援分支，只信任 `agent_type`（見 `_resolve_identity`）。
#
# 規則（任一命中即 deny：印一行 reason、exit 2；否則 exit 0）：
#   (a) `tool_name=="Bash"` 且 `tool_input.run_in_background is True` 且身分（見上）
#       ∈ BLOCKED_AGENTS＝{ios-dev, qa, merge-reviewer, dead-code-sweeper, ui-designer,
#       visual-reviewer}——主 session（身分欄位整個缺席）、身分不明（欄位存在但非可用字串，
#       fail-open＋stderr 註記）、以及身分是已知但不在名單內的其他 subagent（如 Explore／
#       general-purpose）皆放行。
#   (b) 命令文字「背景化再等」慣用形狀（與身分無關，人人皆擋——這是命令文字本身的反模式，不是
#       「這個人可不可以背景」的問題）：`nohup … &`／`(…) &`（subshell 背景化）／背景化（單一 `&`，
#       非 `&&`、非 fd 複製 `>&`）後接 `wait`／`sleep`／`while`／`until`（輪詢等待），且命令文字含
#       `git push`／`xcodebuild`／`push-gate`／`.test.sh`／`run.sh`／`supabase` 任一字面（這些是
#       harness 已知會拖很久、且背景化後容易被放著不管的操作）。純短命令的 `&` 用法——
#       `xcrun simctl boot … &`／`tail -f … &`／`caffeinate &`——在放行清單（ALLOWLIST_BG_RE），先從
#       文字中遮蔽再比對，即使剛好與上述字面同一條命令共存也不誤擋。比對前用
#       `pretool_engine.strip_heredocs` 剝除 heredoc／comment（同 LS-104「只在命令位置比對」的精神：
#       heredoc 內文／comment 提到這些字面不算真的執行）。**R2（merge-review N1，minor，已修）**：
#       比對前另用 `_mask_quoted`（重用 `pretool_engine` 的 `_scan_dquote`／`_scan_cmdsub`／
#       `_scan_ansi_c_quote` 三個引號／命令替換掃描函式，不重寫一套跳脫規則）把單／雙引號內文、
#       `$'...'`、`$(...)`／反引號內文換成等長空白——引號內的 `&`（URL query string、
#       `sed 's/x/&y/'` 的取代字面）不再被誤判成背景化運算子（reviewer 實測：
#       `curl -s "https://…/f?a=1&b=2"` 這類命令原本會被誤 deny）。除此之外沒有進一步做
#       pretool_engine 的完整引號感知斷詞／命令位置正規化——這支是文字慣用形狀的粗粒度啟發式比對，
#       不是 H1-H3 那種要 fail-closed 到繞路都擋住的安全邊界，維持簡單（票文 size:S）。
#
# W0：stdin 空／JSON 壞／頂層非物件／python3 或本檔案本身發生未預期例外 → deny（fail-closed，同
#   pretool.sh／main_checkout_guard.py 的既有慣例）。
#
# 已知盲區（記入 docs/COLLABORATION.md §7；**R2（merge-review N5，informational）敘述已改為實測
# 結果，不是保守猜測**）：規則 (b) 是粗粒度文字比對，不像 H1-H3 那樣遞迴 `bash -c`／`$(...)` payload
# 或做命令位置正規化，但純文字比對本來就吃得到「包一層」的巢狀字面——reviewer 實測
# `bash -c "nohup bash supabase/tests/run.sh > /tmp/o.log 2>&1 & sleep 5"` 仍正確 deny。真正的盲區
# 只有「動態組出來／變數帶入／base64 之類編碼過」的命令（規則 (b) 只看得到字面本身，看不到執行期
# 才展開出來的內容）；N3（informational，票文範圍內、不修）：純 `&` 背景化且無 wait/sleep/while/until
# 輪詢跟進（例如 `bash scripts/gates/push-gate.sh &`）仍放行——這是票文明定 (b) 只擋「背景化再等」
# 四種形狀之一，純背景化本身不在票文範圍內，是否收緊記入待辦、留給 orchestrator 之後評估。身分信號
# 若因 Claude Code 版本差異而不存在，規則 (a) 整支 fail-open（不會誤擋主 session，但也不會擋到任何
# subagent）。
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pretool_engine as E  # noqa: E402 — 只借用 strip_heredocs（heredoc／comment 剝除）

COLL_REF = "docs/COLLABORATION.md §3"

BLOCKED_AGENTS = {
    "ios-dev", "qa", "merge-reviewer", "dead-code-sweeper", "ui-designer", "visual-reviewer",
}

KEYWORD_RE = re.compile(r"git\s+push|xcodebuild|push-gate|\.test\.sh|run\.sh|supabase")
NOHUP_BG_RE = re.compile(r"\bnohup\b[^\n;&|]*&(?!&)")
SUBSHELL_BG_RE = re.compile(r"\([^()\n]*\)\s*&(?!&)")
BARE_AMP_RE = re.compile(r"(?<![&>])&(?!&|>)")
WAIT_POLL_RE = re.compile(r"\b(?:wait|sleep|while|until)\b")
# 放行清單（票文明定的三種短命令背景化）：即使同一條命令裡剛好也出現 KEYWORD_RE 字面也不算——
# 先遮蔽這些片段（含它自己的那個 `&`）再做慣用形狀比對，見 _mask_allowlisted_bg()。
ALLOWLIST_BG_RE = re.compile(
    r"\b(?:xcrun\s+simctl\s+boot|simctl\s+boot|tail\s+-f|caffeinate)\b[^\n;&|]*&(?!&)"
)

_MISSING = object()


def _resolve_identity(d):
    """回傳 (identity_or_None, note_or_None)。identity 是 agent_type 字串（trim 後非空）；找不到
    這個欄位（主 session 的正常情況）回 (None, None)；欄位存在但無法採信（型別不對／空字串）回
    (None, 註記文字)——票文「查不到身分→不擋、stderr 註記」專指這個分支。R2（merge-review N4，
    informational，已修）：拿掉 `agent_name` 欄位與 `CLAUDE_AGENT_TYPE`／`CLAUDE_AGENT_NAME` 環境變數
    備援——reviewer 反查 CLI 執行檔證實三者皆是死碼（從未出現在 schema／執行檔字串裡），只信任
    `agent_type`。"""
    raw = d.get("agent_type", _MISSING)
    if raw is _MISSING:
        return None, None
    if isinstance(raw, str) and raw.strip():
        return raw.strip(), None
    return (
        None,
        f"agent 身分欄位存在但無法採信（值={raw!r}），視為查不到身分，fail-open（見 {COLL_REF}）",
    )


def _mask_allowlisted_bg(text):
    return ALLOWLIST_BG_RE.sub(lambda m: "\0" * len(m.group(0)), text)


def _mask_quoted(text):
    """R2（merge-review N1，minor，已修）：把單／雙引號內文、`$'...'`、`$(...)`／反引號內文換成
    等長空白，只留下真正在 shell 頂層、會被解讀成語法的字元——重用 pretool_engine 既有的引號／命令
    替換掃描函式（`_scan_dquote`／`_scan_cmdsub`／`_scan_ansi_c_quote`），不重寫一套跳脫規則。
    修前：`BARE_AMP_RE` 直接對整段字面做正規表達式比對，`curl -s "https://…?a=1&b=2"`
    這類命令裡 URL query string 的 `&`、`sed 's/x/&y/'` 取代字面的 `&`，都會被誤判成背景化運算子。
    引號／`$(...)` 不平衡（`Ambiguous`）時保守放棄遮蔽、回傳原始文字——這支是啟發式比對，不像
    H1-H3 那樣要 fail-closed 到歧義都擋，遮蔽失敗頂多退回 R1 的（較寬鬆）行為。"""
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


def _idiom_hit(text):
    if NOHUP_BG_RE.search(text):
        return True
    if SUBSHELL_BG_RE.search(text):
        return True
    for m in BARE_AMP_RE.finditer(text):
        if WAIT_POLL_RE.search(text, m.end()):
            return True
    return False


def check_command_idiom(cmd):
    stripped, _bad = E.strip_heredocs(cmd)
    unquoted = _mask_quoted(stripped)
    masked = _mask_allowlisted_bg(unquoted)
    if _idiom_hit(masked) and KEYWORD_RE.search(masked):
        return (
            "H-BG(b)：命令文字為「背景化再等」慣用形狀（nohup／subshell 背景化，或背景化後接 "
            "wait/sleep/while/until 輪詢）且含 git push／xcodebuild／push-gate／.test.sh／run.sh／"
            f"supabase——一律前景執行並帶 timeout，等待改用 for/sleep 輪詢，見 {COLL_REF}"
        )
    return None


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        sys.stdout.write(f"H-BG0：stdin 是空的，無法判斷 tool_input（fail-closed），見 {COLL_REF}")
        sys.exit(2)
    try:
        d = json.loads(raw)
        if not isinstance(d, dict):
            raise ValueError("top-level not object")
    except Exception:
        sys.stdout.write(f"H-BG0：hook JSON 無法解析（fail-closed），見 {COLL_REF}")
        sys.exit(2)

    tool_name = d.get("tool_name")
    if tool_name != "Bash":
        sys.exit(0)

    ti = d.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}

    identity, note = _resolve_identity(d)
    if note:
        sys.stderr.write(f"background-bash-guard：{note}\n")

    if ti.get("run_in_background") is True and identity in BLOCKED_AGENTS:
        sys.stdout.write(
            f"H-BG(a)：agent「{identity}」不得以 run_in_background:true 執行 Bash——前景執行並帶 "
            f"timeout，等待改用 for/sleep 輪詢，見 {COLL_REF}"
        )
        sys.exit(2)

    command = str(ti.get("command") or "")
    reason = check_command_idiom(command)
    if reason:
        sys.stdout.write(reason)
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 - fail-closed on ANY unexpected error
        sys.stdout.write(
            f"H-BG0：background_bash_guard.py 執行異常（{type(e).__name__}），fail-closed，見 {COLL_REF}"
        )
        sys.exit(2)
