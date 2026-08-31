#!/bin/bash
# PreToolUse fail-closed gate（LS-88 縮減版；LS-104 R1 精修「只在命令位置比對」；LS-104 R2
# 修 merge-reviewer R1 comment 的 2 blocker/3 major——Linear LS-104 comment
# 7a97f88a-d928-4e15-b656-a7d7be6eecb6）：只做三條「漏做會出事、字面可辨、後果不可逆」的
# 規則，其餘（H4–H11）在 Harness 待辦池 LS-96，等事故再升。讀 stdin 的 hook JSON
# （`tool_name`／`tool_input`），逐條比對規則表，任一命中即 deny；全部不命中才 allow。
#
# 規則表：
#   H1（Bash）：某一段命令的「命令位置」是 `git` 時，該段若含獨立 token `--no-verify`；或含
#               `commit` 與獨立 `-n`；或含 `push` 與 `--force`／`-f`／`+<ref>`（該段任一 token）
#               且該段任一 token 提到 development／test／main 整字，即 deny（受保護分支禁止
#               force push；CLAUDE.md 純文字規約）。
#   H2（Bash／Read／Grep）：某一段命令位置為讀取動詞（cat／less／head／tail／sed／awk／grep／
#               cut／bat／xxd／base64／strings／rg／wc／sort／paste／dd／od／nl／more／open／
#               perl／jq／`python3 -c`，R2 I2 擴充）且該段某個 token 是 `.env`（含路徑前綴／
#               `.env.<suffix>`／尾端 glob 萬用字元，R2 F5）、或該段含獨立 `<` 重導向且下一個
#               token 是 `.env`，即 deny；除非該段本身命中放行形式（`grep -o... `+以 `=` 結尾的
#               token、`cut -d= -f1`）。Read 工具直接讀 `.env`；Grep 工具的 `path`／`glob` 指向
#               `.env`。
#   H3（Bash）：某段命令位置為 `supabase` 且該段有相鄰 `db`、`reset` 兩個 token；或命令位置為
#               `bash`／`sh`／`./run.sh`（含任何路徑結尾為 `run.sh`）本身或其某 token 結尾為
#               `run.sh`，且整條命令（heredoc／comment 已剝除）沒有 `scripts/ops/supabase-lock.sh
#               -- ` 包裹形式、且非重入（讀 `supabase-lock.sh` 同一套 lock 目錄的 holder pid、走
#               本行程祖先鏈判定，不信環境變數；容器跨 worktree 共用，LS-70），即 deny。
#
# 前處理與命令位置判定（R2 全部移到 scripts/hooks/pretool_engine.py，本檔案只呼叫，見
# `run_bash_engine`；下面是設計摘要，完整細節與每一條的理由見該檔案檔頭大段註解）：
#   1. `strip_heredocs`：quote／comment-aware 單趟字元掃描，只有「不在引號內、不在 comment
#      內」的 `<<[-~]?TAG` 才算真正的 heredoc 起點——R2 F2（blocker）修：R1 版本純用行首正則
#      掃描，引號內／`#` comment 內字面出現的 `<<TAG` 會被誤當成真 heredoc 起點，把後面真正
#      會執行的命令整段吞掉當「資料」放行。comment 文字本身也整段剝除（不進 tokenize）。
#   2. `tokenize_segments`：引號感知斷詞＋切段，**正確處理反斜線**——unquoted `\X` 逐字還原成
#      `X`（`\` + 換行＝續行）；雙引號內只有 `\"`／`\\`／`` \` ``／`\$`／`\`+換行五種序列才有
#      跳脫意義。R2 F3（blocker）修：R1 版本完全不處理反斜線，導致巢狀跳脫引號（`bash -c
#      "bash -c \"…\""`）的引號狀態機提前關閉、token 被切碎而漏放，而非 §7 原本宣稱的
#      「更容易誤判 deny」方向（實測相反，是 fail-open）。
#   3. 命令位置正規化＋退回機制（R2 F1，blocker）：段落第一個非 `VAR=val` token，剝除黏連的
#      `(`／`{`／`!`／`)`／`}`／`;`／`&`（剝到空字串就換下一個 token）、取 basename（絕對／
#      相對路徑）；命中「透明前綴詞」（`command`／`builtin`／`exec`／`env`／`sudo`／`nohup`／
#      `time`／`timeout`／`stdbuf`／`caffeinate`／`script`）就再取下一個 token 重複正規化
#      （上限 16 層）。正規化後若不是「乾淨裸識別字且非 shell 保留字
#      （if/then/else/elif/fi/for/do/done/while/until/case/esac/in/select/function）」——
#      涵蓋 `${IFS}` 展開黏連、`xargs`／`eval`／`alias`／`find -exec`／函式定義 `name() {…}`
#      這些「間接執行」形狀——**視為命令位置認不得，整段退回舊版整段字面比對**（regex 直接
#      掃該段原始文字，等同 LS-88／R1 之前的字面比對邏輯）：前綴詞／關鍵字永遠列不完，
#      「命令位置認得才精確比對，認不得就退回寧嚴勿鬆」封掉大部分繞路面（括號黏連、絕對
#      路徑、shell 關鍵字開頭、間接執行）。命令位置認得的段落才用 R1 的 exact-token 精確比對
#      （誤擋面小）。
#   4. `$(...)`／反引號／`bash -c`／`sh -c`（含 `env FOO=bar bash -c "…"`）payload 遞迴丟回
#      整套規則重新評估，深度上限 8，同 R1。
#
# deny 輸出：`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#   "permissionDecisionReason":"H<n>：…見 docs/COLLABORATION.md §7"}}`，exit 2（Claude Code 的
#   PreToolUse hook 只認 exit 2 為 deny，其餘視為放行——這是本檔案「fail-closed」設計的前提）。
#   允許：exit 0、無輸出。
#
# fail-closed：`RESPONDED` 旗標＋`trap on_exit EXIT`——任何路徑（含未預期的中止：`set -u` 踩到未賦值
#   變數、stdin 讀取失敗、腳本本身語法以外的執行期錯誤）只要沒有先設 `RESPONDED=1` 就一定被 on_exit
#   攔下轉成 deny＋exit 2（`exit` 內建在 trap handler 裡可以覆寫最終 exit code）；正常的 final_allow／
#   final_deny 都先設旗標，on_exit 什麼都不做、維持原本的 exit code。JSON 解析：jq 優先，缺才退到
#   python3；兩者都解不出（皆缺、或 JSON 本身壞掉）→ deny。Bash 命令的 H1/H2/H3 評估（R2）改呼叫
#   `pretool_engine.py`：python3 不存在、或該腳本以非 0/2 的 rc 結束（腳本內部例外會被它自己的
#   try/except 轉成 rc=2＋理由文字），一律 fail-closed（R2 F4「效能改單趟 python3，失敗路徑必須
#   fail-closed」）——不再依賴外部 `grep`（R1 的 `m()`／grep 存在性檢查已隨 bash 版引擎移除，H1/H2/H3
#   比對邏輯全部在 pretool_engine.py 裡，Read／Grep 兩個工具分支仍是純 bash `case` 比對，未變動）。
#
# 已知盲區（見 docs/COLLABORATION.md §7，R2 已依實況更新）：
#   - hook 未經 `/hooks` 重載或重啟不會生效（本檔案改完當次 session 仍照舊放行，PR body 需附 pipe-test
#     證據）；`--no-verify` 本身也能繞過我們自己的 commit/push gate（不能繞過這支 hook，因為 hook 攔的
#     是「執行 Bash 工具」這個動作本身，而不是 git 的機制）。
#   - 字面變體仍可繞：把命令寫進暫存腳本再 `bash tmp.sh <file>` 執行（腳本內文我們讀不到，不會去讀
#     檔案系統上的腳本內容）；`alias name=cmd` 定義後、在**不同一段**（不同 `;`／換行）呼叫該別名
#     （同一段內的 `alias g=git; g commit --no-verify` 已被「命令位置認不得 alias→退回整段字面比對」
#     擋下，因為違規字面就在同一段原始文字裡；但 `alias g=git` 單獨一段之後、另一段才 `g commit
#     --no-verify` 呼叫時，我們不追蹤別名定義到後續呼叫的對應關係，`g` 本身是乾淨識別字、不觸發
#     退回機制）——H1–H3／`bash -c` 遞迴抓的是「直接、字面可辨」的動作，不是完整 shell 語意解析。
#   - H1 的保護分支比對是整字字面命中（`development`／`test`／`main` 出現在**同一段** git 命令
#     的任一 token 即算），不解析目前實際 checkout 的分支；`git push --force`（未寫明目標）不在
#     字面比對範圍內；`git commit`／`push`／旗標只要求同段出現，不看彼此的相對位置。
#   - H3 的 `run.sh` 比對是任何路徑結尾為 `run.sh` 的字面命中，不限定是 supabase 底下那支——寧嚴勿鬆；
#     包裹判定（`supabase-lock.sh ... --`）是整條命令字面比對、不看順序（`supabase-lock.sh --
#     true; supabase db reset` 仍會放行）——記入 LS-96。
#   - `bash -c`／`sh -c` 遞迴只認得 token 序列裡出現 `bash`／`sh` 緊接 `-c` 這個形狀；透過 `xargs
#     bash -c`、`find -exec bash -c ... \;` 這類再包一層的間接執行，退回機制會抓到（`xargs`／
#     `find -exec` 本身已觸發命令位置認不得），但抓到的是「整段字面比對」而非遞迴進 payload 精確
#     解析——足以擋下字面可辨的違規，但比對顆粒度較粗（fail-safe 方向，不是漏放）。
set -u

RESPONDED=
COLL_REF="docs/COLLABORATION.md §7"

# ---- 建 deny JSON（reason 只放本檔案自己寫的靜態文字，不帶使用者輸入，故不需跑時逸出）----
json_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
}

final_deny() {
  json_deny "$1"
  RESPONDED=1
  exit 2
}

final_allow() {
  RESPONDED=1
  exit 0
}

on_exit() {
  if [ -z "$RESPONDED" ]; then
    json_deny "H0：pretool.sh 未預期中止（fail-closed，見 ${COLL_REF}）"
    exit 2
  fi
}
trap on_exit EXIT

# ---- Bash 命令評估引擎所在目錄（R2：改叫 pretool_engine.py，見下方 run_bash_engine）----
# 純參數展開找目錄，不倚賴外部 dirname／cd／pwd（那三個先前只有 H3 重入判定才會用到、
# 命中率低；R2 把「找引擎腳本位置」搬到每次呼叫都會走的路徑上，PATH 被清空／裁剪過的
# 測試環境很容易漏掉 dirname，若倚賴外部指令、指令缺席時的容錯就得再繞一層——參數展開
# 是 bash 內建語法，沒有這個問題）。
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR="."
ENGINE_PY="${SCRIPT_DIR}/pretool_engine.py"

# ============================================================================
# R2：Bash 命令評估引擎（heredoc/comment 剝除 → 引號感知斷詞 → 命令位置正規化 →
# H1/H2/H3，命令位置認不得就退回整段字面比對）整個搬到 scripts/hooks/pretool_engine.py
# 用 Python 實作（R1 F4：純 bash 逐字迴圈是 O(n^2)，32KB 命令要 11 秒；改單趟 Python 掃描，
# 見該檔案檔頭大段註解說明完整設計）。這裡只負責呼叫＋fail-closed 轉譯。
#
# run_bash_engine <cmd>：把 $cmd 用 stdin 餵給 pretool_engine.py（避免 argv 跳脫問題），
# 設全域 DENY_MSG（非空＝deny 理由）。exit code 只認 0（allow）／2（deny，stdout 是理由
# 文字）；python3 不存在、或子行程以其他 rc 結束（腳本內部未預期例外理論上也會被它自己的
# try/except 轉成 2，這裡的「其他 rc」防的是行程本身被系統訊號殺掉、python3 損毀等更底層
# 的失敗）一律 fail-closed（R1 F4「失敗路徑必須 fail-closed」）。
run_bash_engine() {
  local cmd=$1
  DENY_MSG=""
  command -v python3 >/dev/null 2>&1 || {
    DENY_MSG="H0：python3 不存在，無法執行 LS-104 命令評估引擎（fail-closed），見 ${COLL_REF}"
    return
  }
  local out rc
  out=$(printf '%s' "$cmd" | python3 "$ENGINE_PY" 2>/dev/null)
  rc=$?
  case "$rc" in
    0) : ;;
    # out 理論上一定非空（pretool_engine.py 的 rc=2 路徑都會先印一行理由才 exit），但如果
    # 真的空了（例如檔案本身不存在、python3 印錯誤到 stderr 被丟掉、stdout 剛好沒東西）
    # 也不能讓下面的 `[ -n "$DENY_MSG" ]` 因為空字串而誤判成「沒有 deny」——一律給預設訊息。
    2) DENY_MSG=${out:-"H0：命令評估引擎回傳 deny 但無理由文字（fail-closed），見 ${COLL_REF}"} ;;
    *) DENY_MSG="H0：命令評估引擎執行異常（rc=${rc}），fail-closed，見 ${COLL_REF}" ;;
  esac
}

# ---- 讀 stdin：用內建 `read -d ''`，不倚賴外部 cat（PATH 淨空時仍要撐到這裡）----
input=
IFS= read -r -d '' input || true

# 空 stdin 直接 deny：jq 對空輸入串流不算錯誤（0 個 JSON 值、exit 0、印不出任何東西），
# 若放給下面的解析區塊，會被誤判成「解析成功、tool_name 是空字串」而 final_allow——
# 這裡先擋在解析之前，維持「解析不出東西就 deny」的 fail-closed 精神。
[ -n "$input" ] || final_deny "H0：stdin 是空的，無法判斷 tool_input（fail-closed），見 ${COLL_REF}"

# ---- 解析 JSON：jq 優先，缺才退 python3；兩者都解不出（缺工具或 JSON 壞）→ deny ----
# 五個欄位：tool_name／command／file_path（Bash／Read 用）／grep_path／grep_glob（Grep 工具用，
# R1 F7）。欄位分隔字元用 \x1f（unit separator），不用 tab：bash `read` 對 IFS 內的空白類字元
# （space／tab／newline）一律視為可連續合併的分隔符，即使 IFS 只設成單一個 tab 也一樣會把空欄位
# 吃掉、後面的欄位往前擠一位。`read -r -d ''`（delimiter 設成空字元＝NUL）取代預設的「遇換行就
# 停」，讓 command 裡的**換行也留在同一個欄位裡**（R1 F1 的根因：多行 command 原本在第一個 `\n`
# 就被截斷，H1/H2/H3 全部只看得到第一行）——herestring `<<<` 會在結尾多補一個換行，NUL 分隔不會
# 被那個換行擋下來，於是那個換行會跑進「最後一個變數」（本檔案設計成把 grep_glob 放在最後，讀完
# 用 `${grep_glob%$'\n'}` 去掉那一個尾端換行）。
SEP=$'\x1f'
if command -v jq >/dev/null 2>&1; then
  # \x1f 以 --arg 傳入（不寫死在 jq 程式原始碼裡，避免編輯器／git diff 把控制字元搞丟或看不見）；
  # gsub 只清掉欄位值裡「剛好也是」\x1f 的字元（避免污染切欄位），完全不動換行——換行是 R1 F1
  # 要保留的東西，不能像 python3 備援那樣整個換成空白。
  if out=$(printf '%s' "$input" | jq -r --arg sep "$SEP" \
    '[(.tool_name // "" | tostring), (.tool_input.command // "" | tostring), (.tool_input.file_path // "" | tostring), (.tool_input.path // "" | tostring), (.tool_input.glob // "" | tostring)]
     | map(gsub($sep; " ")) | join($sep)' 2>/dev/null); then
    IFS="$SEP" read -r -d '' tool_name command file_path grep_path grep_glob <<<"$out" || true
    grep_glob=${grep_glob%$'\n'}
    parsed=1
  fi
fi

if [ "${parsed:-0}" -ne 1 ] && command -v python3 >/dev/null 2>&1; then
  if out=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if not isinstance(d, dict):
        raise ValueError("top-level not object")
except Exception:
    sys.exit(1)
def esc(s):
    # 只清掉欄位分隔字元本身；換行留著（R1 F1——多行 command 不能被這裡拆掉）
    return str(s).replace("\x1f", " ")
ti = d.get("tool_input")
if not isinstance(ti, dict):
    ti = {}
fields = [d.get("tool_name") or "", ti.get("command") or "", ti.get("file_path") or "", ti.get("path") or "", ti.get("glob") or ""]
sys.stdout.write("\x1f".join(esc(f) for f in fields))
' 2>/dev/null); then
    IFS="$SEP" read -r -d '' tool_name command file_path grep_path grep_glob <<<"$out" || true
    grep_glob=${grep_glob%$'\n'}
    parsed=1
  fi
fi

[ "${parsed:-0}" -eq 1 ] || final_deny "H0：jq／python3 皆無法解析 tool_input（缺工具或 JSON 壞），見 ${COLL_REF}"

case "$tool_name" in
  Bash)
    # R2：全部 H1/H2/H3 判定收斂到 pretool_engine.py（見 run_bash_engine 與該檔案檔頭註解）。
    run_bash_engine "$command"
    if [ -n "${DENY_MSG:-}" ]; then
      final_deny "$DENY_MSG"
    fi
    ;;
  Read)
    base=${file_path##*/}
    case "$base" in
      .env|.env.*)
        final_deny "H2：Read 工具直接讀取 .env 檔內容，見 ${COLL_REF}"
        ;;
    esac
    ;;
  Grep)
    # R1 F7：內建 Grep 工具不經 Bash／Read，`tool_input.path`／`glob` 直接指向 .env 一樣能吐出
    # 內容，原本完全沒擋。只比對 basename（目錄型 path，如 "supabase/" 不受影響）。
    gp=${grep_path##*/}
    case "$gp" in
      .env|.env.*)
        final_deny "H2：Grep 工具的 path 指向 .env 檔案，見 ${COLL_REF}"
        ;;
    esac
    gg=${grep_glob##*/}
    # glob 本身就是萬用字元語法（`.env*` 這種字面星號很常見的寫法），用 `.env*` 一種形狀就夠
    # （case 的 `*` 本來就會吃掉任何延伸，`.env.production`／`.env-local`／單純 `.env` 都算）；
    # 跟 grep_path／file_path（字面檔名，非 glob）刻意不同，那兩處只認 `.env`／`.env.<suffix>`。
    case "$gg" in
      .env*)
        final_deny "H2：Grep 工具的 glob 鎖定 .env 檔案，見 ${COLL_REF}"
        ;;
    esac
    ;;
esac

final_allow
