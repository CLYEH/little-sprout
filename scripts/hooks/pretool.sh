#!/bin/bash
# PreToolUse fail-closed gate（LS-88 縮減版）：只做三條「漏做會出事、字面可辨、後果不可逆」的規則，
# 其餘（H4–H11）在 Harness 待辦池 LS-96，等事故再升。讀 stdin 的 hook JSON（`tool_name`／`tool_input`），
# 逐條比對規則表，任一命中即 deny；全部不命中才 allow。
#
# 規則表：
#   H1（Bash）：命令含 `--no-verify`；或 `git push` 帶 `--force`／`-f`／`+<ref>` 且命令字面提到
#               development／test／main（受保護分支禁止 force push；CLAUDE.md 純文字規約）。
#   H2（Bash／Read）：以 cat／less／head／tail／sed／awk／grep／cut 讀出 `.env`（含 `.env.*`）的內容；
#               或 Read 工具直接讀 `.env`。放行 key-only 形式：`grep -o... '…='`（擷取式樣以 `=` 結尾，
#               擷取不到值）、`cut -d= -f1`、`source .env`／`. .env`（注入不印出）。
#   H3（Bash）：`supabase db reset`／`run.sh` 未包在 `scripts/ops/supabase-lock.sh -- ` 之後、且非重入
#               （本程序自己的環境已有 `SUPABASE_LOCK_HELD`）（容器跨 worktree 共用，LS-70）。
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
#   python3；兩者都解不出（皆缺、或 JSON 本身壞掉）→ deny。三條規則比對只用 `grep -E`／bash 內建
#   （`case`、`[ ]`、參數展開），不倚賴陣列／`${var,,}`，bash 3.2（macOS 內建版本）可跑。
#
# 已知盲區（見 docs/COLLABORATION.md §7）：
#   - hook 未經 `/hooks` 重載或重啟不會生效（本檔案改完當次 session 仍照舊放行，PR body 需附 pipe-test
#     證據）；`--no-verify` 本身也能繞過我們自己的 commit/push gate（不能繞過這支 hook，因為 hook 攔的
#     是「執行 Bash 工具」這個動作本身，而不是 git 的機制）。
#   - 字面變體可繞：把命令寫進暫存腳本再 `bash tmp.sh` 執行、拆成多個工具呼叫、變數組字串再 eval，
#     這些都不在字面比對範圍內——H1–H3 抓的是「直接、字面可辨」的動作，不是完整 shell 語意解析。
#   - H2 的偵測是「整條命令字串」比對，不是逐一 argv／管線切開：`source .env; cat .env` 這種鏈式命令，
#     只要字串裡出現一段符合放行形式的子字串，目前會整條放行——不做假設之外的語意解析（簡單優先）。
#   - H1 的保護分支比對是整字字面命中（`development`／`test`／`main` 出現在命令字串任何位置即算），
#     不解析目前實際 checkout 的分支；`git push --force`（未寫明目標）不在字面比對範圍內。
#   - H3 的 `run.sh` 比對是任何路徑結尾為 `run.sh` 的字面命中，不限定是 supabase 底下那支——寧嚴勿鬆。
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

# ---- 讀 stdin：用內建 `read -d ''`，不倚賴外部 cat（PATH 淨空時仍要撐到這裡）----
input=
IFS= read -r -d '' input || true

# 空 stdin 直接 deny：jq 對空輸入串流不算錯誤（0 個 JSON 值、exit 0、印不出任何東西），
# 若放給下面的解析區塊，會被誤判成「解析成功、tool_name 是空字串」而 final_allow——
# 這裡先擋在解析之前，維持「解析不出東西就 deny」的 fail-closed 精神。
[ -n "$input" ] || final_deny "H0：stdin 是空的，無法判斷 tool_input（fail-closed），見 ${COLL_REF}"

# ---- 解析 JSON：jq 優先，缺才退 python3；兩者都解不出（缺工具或 JSON 壞）→ deny ----
tool_name=; command=; file_path=; parsed=0

# 欄位分隔字元用 \x1f（unit separator），不用 tab：bash `read` 對 IFS 內的空白類字元
# （space／tab／newline）一律視為可連續合併的分隔符，即使 IFS 只設成單一個 tab 也一樣會把
# 「Read<TAB><TAB>.env」的空欄位吃掉、後面的欄位往前擠一位——tool_input.command 為空字串的
# Read 呼叫會把 file_path 錯放進 command 變數。\x1f 不在空白類字元集合內，不會被合併。
SEP=$'\x1f'
if command -v jq >/dev/null 2>&1; then
  # \x1f 以 --arg 傳入（不寫死在 jq 程式原始碼裡，避免編輯器／git diff 把控制字元搞丟或看不見）
  if out=$(printf '%s' "$input" | jq -r --arg sep "$SEP" \
    '[(.tool_name // "" | tostring), (.tool_input.command // "" | tostring), (.tool_input.file_path // "" | tostring)] | map(gsub($sep; " ")) | join($sep)' 2>/dev/null); then
    IFS="$SEP" read -r tool_name command file_path <<<"$out"
    parsed=1
  fi
fi

if [ "$parsed" -ne 1 ] && command -v python3 >/dev/null 2>&1; then
  if out=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if not isinstance(d, dict):
        raise ValueError("top-level not object")
except Exception:
    sys.exit(1)
def esc(s):
    return str(s).replace("\\", "\\\\").replace("\x1f", " ").replace("\n", " ")
ti = d.get("tool_input")
if not isinstance(ti, dict):
    ti = {}
sys.stdout.write(esc(d.get("tool_name") or "") + "\x1f" + esc(ti.get("command") or "") + "\x1f" + esc(ti.get("file_path") or ""))
' 2>/dev/null); then
    IFS="$SEP" read -r tool_name command file_path <<<"$out"
    parsed=1
  fi
fi

[ "$parsed" -eq 1 ] || final_deny "H0：jq／python3 皆無法解析 tool_input（缺工具或 JSON 壞），見 ${COLL_REF}"

case "$tool_name" in
  Bash)
    # H1a：--no-verify（任何命令，作為獨立 token 出現）
    if printf '%s' "$command" | grep -Eq -- '(^|[^A-Za-z0-9_-])--no-verify([^A-Za-z0-9_-]|$)'; then
      final_deny "H1：命令含 --no-verify，繞過 commit/push gate，見 ${COLL_REF}"
    fi

    # H1b：git push --force／-f／+<ref> 且目標字面提到受保護分支
    if printf '%s' "$command" | grep -Eq 'git[[:space:]]+push'; then
      if printf '%s' "$command" | grep -Eq -- '(^|[[:space:]])(--force(-with-lease)?|-f)([[:space:]]|$)' \
        || printf '%s' "$command" | grep -Eq '(^|[[:space:]])\+[A-Za-z0-9._/-]+'; then
        if printf '%s' "$command" | grep -Ewq 'development|test|main'; then
          final_deny "H1：force push 目標為 development／test／main（受保護分支禁止 force push），見 ${COLL_REF}"
        fi
      fi
    fi

    # H3：supabase db reset／run.sh 未經 supabase-lock.sh -- 包裹，且非重入
    if printf '%s' "$command" | grep -Eq 'supabase[[:space:]]+db[[:space:]]+reset' \
      || printf '%s' "$command" | grep -Eq '(^|[/[:space:]])run\.sh([[:space:]]|$)'; then
      if ! printf '%s' "$command" | grep -Eq 'supabase-lock\.sh\b.*[[:space:]]--([[:space:]]|$)'; then
        if [ -z "${SUPABASE_LOCK_HELD:-}" ]; then
          final_deny "H3：supabase db reset／run.sh 未經 scripts/ops/supabase-lock.sh -- 包裹（本機容器跨 worktree 共用，LS-70），見 ${COLL_REF}"
        fi
      fi
    fi

    # H2：以 cat／less／head／tail／sed／awk／grep／cut 讀出 .env（含 .env.*）內容
    if printf '%s' "$command" | grep -Eq '(^|[[:space:]/])\.env(\.[A-Za-z0-9_.-]+)?([[:space:]]|$)'; then
      if printf '%s' "$command" | grep -Eq '\b(cat|less|head|tail|awk|cut|sed|grep)\b'; then
        allowed=0
        # 放行①：grep -o... '<pattern 以 = 結尾>'（擷取不到值，只到 key=）
        if printf '%s' "$command" | grep -Eq '\bgrep\b' \
          && printf '%s' "$command" | grep -Eq -- '-[A-Za-z]*o[A-Za-z]*\b' \
          && printf '%s' "$command" | grep -Eq "=['\"]"; then
          allowed=1
        fi
        # 放行②：cut -d= -f1（只取 key 欄）
        if [ "$allowed" -ne 1 ] \
          && printf '%s' "$command" | grep -Eq '\bcut\b' \
          && printf '%s' "$command" | grep -Eq -- '-d[[:space:]]*=' \
          && printf '%s' "$command" | grep -Eq -- '-f[[:space:]]*1\b'; then
          allowed=1
        fi
        if [ "$allowed" -ne 1 ]; then
          final_deny "H2：以 cat／less／head／tail／sed／awk／grep／cut 讀出 .env 內容（非 key-only 形式），見 ${COLL_REF}"
        fi
      fi
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
esac

final_allow
