#!/bin/bash
# PreToolUse fail-closed gate（LS-88 縮減版，R2 修 merge-reviewer R1 blocker/major：LS-88 review
# https://github.com/CLYEH/little-sprout/pull/157#issuecomment-5413222970）：只做三條「漏做會出事、
# 字面可辨、後果不可逆」的規則，其餘（H4–H11）在 Harness 待辦池 LS-96，等事故再升。讀 stdin 的 hook
# JSON（`tool_name`／`tool_input`），逐條比對規則表，任一命中即 deny；全部不命中才 allow。
#
# 規則表：
#   H1（Bash）：命令含 `--no-verify`／`git commit` 帶獨立 `-n`；或 `git push` 帶 `--force`／`-f`／
#               `+<ref>` 且命令字面提到 development／test／main（受保護分支禁止 force push；
#               CLAUDE.md 純文字規約）。
#   H2（Bash／Read／Grep）：以 cat／less／head／tail／sed／awk／grep／cut 或 `<` 重導向讀出 `.env`
#               （含 `.env.*`）的內容；Read 工具直接讀 `.env`；Grep 工具的 `path`／`glob` 指向 `.env`。
#               放行 key-only 形式：`grep -o... '…='`（擷取式樣以 `=` 結尾，擷取不到值）、`cut -d= -f1`、
#               `source .env`／`. .env`（注入不印出）。
#   H3（Bash）：`supabase db reset`／`run.sh` 未包在 `scripts/ops/supabase-lock.sh -- ` 之後、且非重入
#               （容器跨 worktree 共用，LS-70）。
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
#   python3；兩者都解不出（皆缺、或 JSON 本身壞掉）→ deny；`grep` 本身缺失／執行異常（rc 既非 0
#   也非 1，如語法錯 rc=2、找不到指令 rc=127）一律經 `m()` 轉 deny，不當作「沒命中」放行（R1 F2）。
#   三條規則比對只用 `grep -E`／bash 內建（`case`、`[ ]`、參數展開），不倚賴陣列／`${var,,}`，
#   bash 3.2（macOS 內建版本）可跑。
#
# 已知盲區（見 docs/COLLABORATION.md §7）：
#   - hook 未經 `/hooks` 重載或重啟不會生效（本檔案改完當次 session 仍照舊放行，PR body 需附 pipe-test
#     證據）；`--no-verify` 本身也能繞過我們自己的 commit/push gate（不能繞過這支 hook，因為 hook 攔的
#     是「執行 Bash 工具」這個動作本身，而不是 git 的機制）。
#   - 字面變體可繞：把命令寫進暫存腳本再 `bash tmp.sh` 執行、拆成多個工具呼叫、變數組字串再 eval，
#     這些都不在字面比對範圍內——H1–H3 抓的是「直接、字面可辨」的動作，不是完整 shell 語意解析。
#   - H2 的偵測是「整條命令字串先切段」比對，不是完整 shell parser：只用 `;`／`&&`／`||`／`|`／換行
#     切段（保守切法），不處理引號內含這些字元的情況（如 `echo ";" > .env` 會被誤切）——已知限制。
#   - H1 的保護分支比對是整字字面命中（`development`／`test`／`main` 出現在命令字串任何位置即算），
#     不解析目前實際 checkout 的分支；`git push --force`（未寫明目標）不在字面比對範圍內；`git commit`
#     與 `-n` 是否同屬一個子命令不看順序／位置，鏈式命令中兩者分屬不同子命令時可能誤擋（fail-safe
#     方向，非漏放）。
#   - H3 的 `run.sh` 比對是任何路徑結尾為 `run.sh` 的字面命中，不限定是 supabase 底下那支——寧嚴勿鬆；
#     包裹判定不看順序（`supabase-lock.sh -- true; supabase db reset` 仍會放行）——記入 LS-96。
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

# ---- grep 存在性先查一次（R1 F2）：規則比對整段都靠 grep，缺了就沒有任何規則測得出來 ----
command -v grep >/dev/null 2>&1 || final_deny "H0：grep 不存在，無法比對規則（fail-closed），見 ${COLL_REF}"

# m <字串> [grep 額外參數...] <pattern>：grep -Eq 包一層，把「grep 本身異常」（regex 語法錯
# rc=2、找不到 grep 這個特例已在上面擋過，但保留防禦）跟「沒命中」（rc=1）分開；異常一律
# fail-closed 直接 final_deny（不是回傳給呼叫端假裝沒命中——R1 F2 原本用 `if grep -Eq …; then`
# 把 rc=1／rc=2／rc=127 全部混在一起當「沒命中」處理，是這支 gate「票文明文要求 fail-closed」
# 卻沒做到的地方）。呼叫端用法同 grep -Eq：`m "$str" 'pattern'` 或 `m "$str" -w 'pattern'`。
m() {
  local str=$1
  shift
  printf '%s' "$str" | grep -Eq "$@"
  local rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) final_deny "H0：grep 執行異常（rc=${rc}），fail-closed，見 ${COLL_REF}" ;;
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
    # H1a：--no-verify（任何命令，作為獨立 token 出現）
    if m "$command" -- '(^|[^A-Za-z0-9_-])--no-verify([^A-Za-z0-9_-]|$)'; then
      final_deny "H1：命令含 --no-verify，繞過 commit/push gate，見 ${COLL_REF}"
    fi

    # R1 F6：git commit 帶獨立 -n（--no-verify 的官方短旗標，效果相同，跳過 pre-commit／
    # commit-msg）。限定只在 git commit 生效——git push -n 是 --dry-run，語意不同，擋了就是
    # 誤擋（review 原話）。
    if m "$command" -- 'git[[:space:]]+commit' && m "$command" -- '(^|[[:space:]])-n([[:space:]]|$)'; then
      final_deny "H1：git commit -n 等同 --no-verify，繞過 commit gate，見 ${COLL_REF}"
    fi

    # H1b：git push --force／-f／+<ref> 且目標字面提到受保護分支
    if m "$command" -- 'git[[:space:]]+push'; then
      if m "$command" -- '(^|[[:space:]])(--force(-with-lease)?|-f)([[:space:]]|$)' \
        || m "$command" -- '(^|[[:space:]])\+[A-Za-z0-9._/-]+'; then
        if m "$command" -w 'development|test|main'; then
          final_deny "H1：force push 目標為 development／test／main（受保護分支禁止 force push），見 ${COLL_REF}"
        fi
      fi
    fi

    # H3：supabase db reset／run.sh 未經 supabase-lock.sh -- 包裹，且非重入
    # 邊界（R1 F3）：前界＝字串開頭或前一字元非英數底線（含引號／`(`／`<`／`$`／`;`／`&`／`|` 等）；
    # 後界＝字串結尾或後一字元非英數底線點線（`;`、引號、`)`、換行都算，但 `.`／`-` 不算，避免把
    # `run.sh` 誤判成延伸到 `run.sh.bak`／`run.sh-old` 這類不同檔名的邊界）。
    if m "$command" -- 'supabase[[:space:]]+db[[:space:]]+reset' \
      || m "$command" -- '(^|[^A-Za-z0-9_])run\.sh($|[^A-Za-z0-9_.-])'; then
      if ! m "$command" -- 'supabase-lock\.sh\b.*[[:space:]]--([[:space:]]|$)'; then
        if [ -z "${SUPABASE_LOCK_HELD:-}" ]; then
          final_deny "H3：supabase db reset／run.sh 未經 scripts/ops/supabase-lock.sh -- 包裹（本機容器跨 worktree 共用，LS-70），見 ${COLL_REF}"
        fi
      fi
    fi

    # H2：以 cat／less／head／tail／sed／awk／grep／cut 或 `<` 重導向讀出 .env（含 .env.*）內容。
    # 邊界（R1 F3）：前界＝開頭或非英數底線（`'`、`"`、`(`、`<`、`$`、`;` 都算）；後界＝結尾或
    # 非英數底線點線（`;`、引號、`)` 都算），涵蓋 `cat .env;`、`cat '.env'`、`cat ".env"`、
    # `< .env`、`$(cat .env)` 這些原本漏放的形狀。
    # R1 F4：放行形式原本是整條命令字串比對，`grep -oE '^[A-Z_]+=' .env; cat .env` 這種鏈式
    # 命令會被第一段的放行形式免疫掉第二段真正讀值的 cat（實測：`source .env; cat .env`
    # 其實本來就會 deny——cat 才是觸發點，source 從來不在放行判定裡；真正的洞是「放行形式」
    # 出現在鏈的某一段，讓另一段的違規免疫）。先用 `;`／`&&`／`||`／`|`／換行保守切段（不追求
    # 完整 shell parser，引號內含這些字元會被誤切——已知限制見檔頭），逐段判定，任一段命中
    # 讀值且該段本身不是放行形式即 deny；放行只在該段本身命中放行形式時才成立。
    h2_env_ref() { m "$1" -- '(^|[^A-Za-z0-9_])\.env(\.[A-Za-z0-9_.-]+)?($|[^A-Za-z0-9_.-])'; }
    h2_trigger() {
      m "$1" -- '\b(cat|less|head|tail|awk|cut|sed|grep)\b' \
        || m "$1" -- "<[[:space:]]*['\"]?\\.env"
    }
    h2_allow() {
      # 放行①：grep -o... '<pattern 以 = 結尾>'（擷取不到值，只到 key=）
      if m "$1" -- '\bgrep\b' && m "$1" -- '-[A-Za-z]*o[A-Za-z]*\b' && m "$1" -- "=['\"]"; then
        return 0
      fi
      # 放行②：cut -d= -f1（只取 key 欄）
      if m "$1" -- '\bcut\b' && m "$1" -- '-d[[:space:]]*=' && m "$1" -- '-f[[:space:]]*1\b'; then
        return 0
      fi
      return 1
    }
    h2_sep=$'\x1e'
    # 純 bash 參數展開切段，不倚賴外部 tr（tr 若缺席會讓這裡切出 0 段、H2 整段靜默不擋——
    # 用 param expansion 避免再多一個「缺了就 fail-open」的外部指令依賴）。
    h2_segs=$command
    h2_segs=${h2_segs//;/$h2_sep}
    h2_segs=${h2_segs//&/$h2_sep}
    h2_segs=${h2_segs//|/$h2_sep}
    h2_segs=${h2_segs//$'\n'/$h2_sep}
    while IFS= read -r -d "$h2_sep" h2_seg || [ -n "$h2_seg" ]; do
      [ -n "$h2_seg" ] || continue
      if h2_env_ref "$h2_seg" && h2_trigger "$h2_seg" && ! h2_allow "$h2_seg"; then
        final_deny "H2：以 cat／less／head／tail／sed／awk／grep／cut 讀出 .env 內容（非 key-only 形式），見 ${COLL_REF}"
      fi
    done <<<"${h2_segs}${h2_sep}"
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
