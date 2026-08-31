#!/bin/bash
# PreToolUse fail-closed gate（LS-88 縮減版；LS-104 精修：只在「命令位置」比對，heredoc／引號
# 字串／echo·printf 內容排除出比對範圍，$(...)／反引號內容仍比對——那是真的會執行的——見
# https://github.com/CLYEH/little-sprout/pull/157 與 LS-104）：只做三條「漏做會出事、字面可辨、
# 後果不可逆」的規則，其餘（H4–H11）在 Harness 待辦池 LS-96，等事故再升。讀 stdin 的 hook
# JSON（`tool_name`／`tool_input`），逐條比對規則表，任一命中即 deny；全部不命中才 allow。
#
# 規則表：
#   H1（Bash）：某一段命令的「命令位置」是 `git` 時，該段若含獨立 token `--no-verify`；或含
#               `commit` 與獨立 `-n`；或含 `push` 與 `--force`／`-f`／`+<ref>`（該段任一 token）
#               且該段任一 token 提到 development／test／main 整字，即 deny（受保護分支禁止
#               force push；CLAUDE.md 純文字規約）。
#   H2（Bash／Read／Grep）：某一段命令位置為讀取動詞（cat／less／head／tail／sed／awk／grep／
#               cut／bat／xxd／base64／strings／rg／wc）且該段某個 token（去引號後整個 token）
#               是 `.env`（含路徑前綴／`.env.<suffix>`），或該段含獨立 `<` 重導向且下一個 token
#               是 `.env`，即 deny；除非該段本身命中放行形式（`grep -o... `+以 `=` 結尾的 token、
#               `cut -d= -f1`）。Read 工具直接讀 `.env`；Grep 工具的 `path`／`glob` 指向 `.env`。
#   H3（Bash）：某段命令位置為 `supabase` 且該段有相鄰 `db`、`reset` 兩個 token；或命令位置為
#               `bash`／`sh`／`./run.sh`（含任何路徑結尾為 `run.sh`）本身或其某 token 結尾為
#               `run.sh`，且整條命令（heredoc 已剝除）沒有 `scripts/ops/supabase-lock.sh -- `
#               包裹形式、且非重入（讀 `supabase-lock.sh` 同一套 lock 目錄的 holder pid、走本
#               行程祖先鏈判定，不信環境變數；容器跨 worktree 共用，LS-70），即 deny。
#
# 前處理（LS-104 核心）：
#   1. `strip_heredocs`：先把 `<<[-~]?TAG` 到終止行 `TAG` 之間的內文整段剝掉（不切段、不比對——
#      那只是資料，不是要執行的命令）；終止行找不到（heredoc 未閉合）視為切段失敗，歧義即 deny。
#   2. `tokenize`：對剝掉 heredoc 後的字串做「引號感知」的切段＋斷詞——`;`／`&&`／`||`／`|`／
#      `&`／換行只在**引號外**才切段（`grep -E "a|b" .env` 的 `|` 在雙引號內不切）；單／雙引號
#      整個去掉、內容併回原 token（`cat '.env'` 的 token 是 `.env`，`echo "含 --no-verify 文字"`
#      的 token 是整句「含 --no-verify 文字」——後者不會被誤判成獨立的 `--no-verify` token）；
#      單引號內完全逐字（不再遞迴），雙引號內仍會遞迴進 `$(...)`／反引號（跟真實 shell 一致：
#      雙引號不會抑制指令替換）；掃到字串結尾仍在引號內、或 `$(...)`／反引號未閉合 → 歧義即
#      deny。`$(...)`／反引號擷取出的內文（那是真的會被執行的）遞迴丟回整套規則重新評估。
#   3. 每段的「命令位置」＝該段第一個不是 `VAR=val` 賦值形狀的 token；H1/H2/H3 只在命令位置
#      命中對應動詞時才在該段內比對旗標／檔名，不再整條字串／跨段落找字面。echo／printf 的
#      參數天然被排除：它們的命令位置是 echo／printf，不在任何規則的動詞清單裡，該段永遠不會
#      被拿去跟 H1/H2/H3 的 pattern 比對（不需要另外特判）。
#   4. `bash -c "…"`／`sh -c "…"`（含 `env FOO=bar bash -c "…"` 這種前面還有其他 token 的形狀）
#      的 payload 是會被整個當 shell 命令執行的字串，遞迴丟回整套規則重新評估（深度上限 8，
#      超過視為歧義 deny）——否則位置比對收窄後，把違規包進 `bash -c "…"` 會變成新的繞過路徑。
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
#   規則比對只用 `grep -E`／bash 內建（`case`、`[ ]`、`[[ =~ ]]`＋`BASH_REMATCH`、參數展開），不
#   倚賴自訂陣列／`${var,,}`，bash 3.2（macOS 內建版本）可跑；segment／token 用 `\x02`–`\x05`
#   四個不可見分隔字元＋`read -d` 逐段讀出（同一套手法既有 JSON 欄位解析已在用）。
#
# 已知盲區（見 docs/COLLABORATION.md §7）：
#   - hook 未經 `/hooks` 重載或重啟不會生效（本檔案改完當次 session 仍照舊放行，PR body 需附 pipe-test
#     證據）；`--no-verify` 本身也能繞過我們自己的 commit/push gate（不能繞過這支 hook，因為 hook 攔的
#     是「執行 Bash 工具」這個動作本身，而不是 git 的機制）。
#   - 字面變體可繞：把命令寫進暫存腳本再 `bash tmp.sh <file>` 執行（腳本內文我們讀不到）、拆成多個
#     工具呼叫、變數組字串再 `eval` 都繞得過去——H1–H3／`bash -c` 遞迴抓的是「直接、字面可辨」的
#     動作，不是完整 shell 語意解析，也不會去讀取檔案系統上的腳本內容。
#   - 切段／斷詞是自製的字元掃描器，不是完整 shell parser：反斜線跳脫（如 `"a\"b"`）不認得；
#     `$(...)`／反引號的巢狀擷取只用括號配對與基本引號追蹤，同樣不處理反斜線跳脫。
#   - H1 的保護分支比對是整字字面命中（`development`／`test`／`main` 出現在**同一段** git 命令
#     的任一 token 即算），不解析目前實際 checkout 的分支；`git push --force`（未寫明目標）不在
#     字面比對範圍內；`git commit`／`push`／旗標只要求同段出現，不看彼此的相對位置。
#   - H3 的 `run.sh` 比對是任何路徑結尾為 `run.sh` 的字面命中，不限定是 supabase 底下那支——寧嚴勿鬆；
#     包裹判定（`supabase-lock.sh ... --`）仍是整條命令字面比對、不看順序（`supabase-lock.sh --
#     true; supabase db reset` 仍會放行）——記入 LS-96。
#   - `bash -c`／`sh -c` 遞迴只認得 token 序列裡出現 `bash`／`sh` 緊接 `-c` 這個形狀；透過其他
#     wrapper（`xargs bash -c`、`find -exec`、別名）間接執行不在遞迴範圍內。
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

# ============================================================================
# LS-104：命令位置比對引擎（heredoc 剝除 → 引號感知斷詞 → 逐段命令位置判定 → H1/H2/H3）
# ============================================================================
LSEP=$'\x04'   # strip_heredocs 內部：逐行切割用（不會出現在真實命令裡）
SSEP=$'\x03'   # tokenize 輸出：段落分隔（`;`／`&&`／`||`／`|`／`&`／換行，僅在引號外）
TSEP=$'\x02'   # tokenize 輸出：段落內的 token 分隔
CSUB_SEP=$'\x05'  # tokenize 輸出：$(...)／反引號擷取出的內文，供遞迴評估

READ_VERBS_RE='^(cat|less|head|tail|awk|cut|sed|grep|bat|xxd|base64|strings|rg|wc)$'
ENV_FILE_RE='(^|.*/)\.env(\.[A-Za-z0-9_.-]+)?$'
RUNSH_RE='(^|.*/)run\.sh$'
PROTECTED_BRANCH_RE='(^|[^A-Za-z0-9_])(development|test|main)([^A-Za-z0-9_]|$)'

# strip_heredocs <cmd>：把 `<<[-~]?TAG` 起到終止行 `TAG` 之間的內文整段剝掉（那是資料，不是要
# 執行的命令——LS-88 事故①②都是規則字面出現在 heredoc 內文裡被誤當命令比對）。設全域
# HD_OUT（剝除後字串）與 HD_BAD（1＝heredoc 未閉合，切段失敗）。直接呼叫、不可用 $(...) 包
# （子行程看不到呼叫端的全域變數）。
strip_heredocs() {
  local cmd=$1
  local lines=${cmd//$'\n'/$LSEP}
  local out="" line check tag="" in_hd=0 strip_tabs=0
  HD_BAD=0
  while IFS= read -r -d "$LSEP" line || [ -n "$line" ]; do
    if [ "$in_hd" -eq 1 ]; then
      check=$line
      if [ "$strip_tabs" -eq 1 ]; then
        while [ "${check#$'\t'}" != "$check" ]; do check=${check#$'\t'}; done
      fi
      [ "$check" = "$tag" ] && in_hd=0
      continue
    fi
    out="${out}${line}"$'\n'
    local checkline=${line//<<</XXX}   # <<< 是 herestring，不是 heredoc，先遮住避免誤判
    if [[ $checkline =~ \<\<(-|~)?[[:space:]]*(\"[^\"]*\"|\'[^\']*\'|[A-Za-z_][A-Za-z0-9_]*) ]]; then
      local mod=${BASH_REMATCH[1]}
      tag=${BASH_REMATCH[2]}
      case "$tag" in
        \"*\") tag=${tag#\"}; tag=${tag%\"} ;;
        \'*\') tag=${tag#\'}; tag=${tag%\'} ;;
      esac
      [ "$mod" = "-" ] && strip_tabs=1 || strip_tabs=0
      in_hd=1
    fi
  done <<<"${lines}${LSEP}"
  [ "$in_hd" -eq 1 ] && HD_BAD=1
  HD_OUT=$out
}

# tokenize <s>：引號感知的段落＋token 掃描。設全域 TOK_OUT（SSEP 分段、每段 TSEP 分 token）、
# AMBIGUOUS（1＝引號或 $(...)／反引號未平衡，切段失敗，歧義即 deny）、CMDSUBS（CSUB_SEP 串接
# 的 $(...)／反引號內文，供呼叫端遞迴評估——那是真的會執行的，不能因為在引號裡就跳過比對）。
# 單引號內完全逐字（不遞迴 $(...)／反引號，與真實 shell 一致）；雙引號內仍會遞迴（雙引號不
# 抑制指令替換）。直接呼叫、不可用 $(...) 包。
tokenize() {
  local s=$1
  local i=0 n=${#s}
  local ch next
  local cur_tok="" tok_has_content=0
  local cur_seg=""
  local out=""
  local q=""
  AMBIGUOUS=0
  CMDSUBS=""

  flush_tok() {
    if [ -n "$cur_tok" ] || [ "$tok_has_content" -eq 1 ]; then
      cur_seg="${cur_seg}${cur_tok}${TSEP}"
    fi
    cur_tok=""
    tok_has_content=0
  }
  flush_seg() {
    flush_tok
    out="${out}${cur_seg}${SSEP}"
    cur_seg=""
  }

  while [ "$i" -lt "$n" ]; do
    ch=${s:$i:1}

    if [ "$q" = "'" ]; then
      if [ "$ch" = "'" ]; then q=""; else cur_tok="${cur_tok}${ch}"; tok_has_content=1; fi
      i=$((i+1)); continue
    fi

    if [ "$ch" = '$' ] && [ "${s:$((i+1)):1}" = '(' ]; then
      local depth=1 j=$((i+2)) inner="" cch cq=""
      while [ "$j" -lt "$n" ] && [ "$depth" -gt 0 ]; do
        cch=${s:$j:1}
        if [ -n "$cq" ]; then
          [ "$cch" = "$cq" ] && cq=""
          inner="${inner}${cch}"
        else
          case "$cch" in
            "'"|'"') cq=$cch; inner="${inner}${cch}" ;;
            '(') depth=$((depth+1)); inner="${inner}${cch}" ;;
            ')') depth=$((depth-1)); [ "$depth" -gt 0 ] && inner="${inner}${cch}" ;;
            *) inner="${inner}${cch}" ;;
          esac
        fi
        j=$((j+1))
      done
      if [ "$depth" -ne 0 ]; then
        AMBIGUOUS=1
        i=$n
        continue
      fi
      CMDSUBS="${CMDSUBS}${inner}${CSUB_SEP}"
      tok_has_content=1
      i=$j
      continue
    fi

    if [ "$ch" = '`' ]; then
      local j=$((i+1)) inner="" cch
      while [ "$j" -lt "$n" ]; do
        cch=${s:$j:1}
        [ "$cch" = '`' ] && break
        inner="${inner}${cch}"
        j=$((j+1))
      done
      if [ "$j" -ge "$n" ]; then
        AMBIGUOUS=1
        i=$n
        continue
      fi
      CMDSUBS="${CMDSUBS}${inner}${CSUB_SEP}"
      tok_has_content=1
      i=$((j+1))
      continue
    fi

    if [ "$q" = '"' ]; then
      if [ "$ch" = '"' ]; then q=""; else cur_tok="${cur_tok}${ch}"; tok_has_content=1; fi
      i=$((i+1)); continue
    fi

    case "$ch" in
      "'"|'"') q=$ch; tok_has_content=1 ;;
      ' '|$'\t') flush_tok ;;
      $'\n'|';') flush_seg ;;
      '&')
        next=${s:$((i+1)):1}
        if [ "$next" = "&" ]; then flush_seg; i=$((i+1)); else flush_seg; fi
        ;;
      '|')
        next=${s:$((i+1)):1}
        if [ "$next" = "|" ]; then flush_seg; i=$((i+1)); else flush_seg; fi
        ;;
      '<')
        flush_tok
        next=${s:$((i+1)):1}
        if [ "$next" = "<" ]; then
          i=$((i+1))
          next=${s:$((i+1)):1}
          if [ "$next" = "<" ]; then i=$((i+1)); cur_seg="${cur_seg}<<<${TSEP}"; else cur_seg="${cur_seg}<<${TSEP}"; fi
        else
          cur_seg="${cur_seg}<${TSEP}"
        fi
        ;;
      *) cur_tok="${cur_tok}${ch}"; tok_has_content=1 ;;
    esac
    i=$((i+1))
  done
  [ -n "$q" ] && AMBIGUOUS=1
  flush_seg
  TOK_OUT=$out
}

# h3_reentrant：同 LS-88，讀同一把 lock 目錄（預設 /tmp/supabase-lock-<project_id>；
# SUPABASE_LOCK_DIR 可覆寫供自測用）的 holder pid，走本行程 ppid 鏈（≤64 層）判定是否已在
# lock 內——不信環境變數（hook 是獨立行程，不繼承呼叫端 shell 的 export）。
h3_reentrant() {
  local lock_dir proj root holder_pid p n
  if [ -n "${SUPABASE_LOCK_DIR:-}" ]; then
    lock_dir=$SUPABASE_LOCK_DIR
  else
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || return 1
    proj=$(sed -nE 's/^project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$root/supabase/config.toml" 2>/dev/null | head -1)
    [ -n "$proj" ] || return 1
    lock_dir="/tmp/supabase-lock-${proj}"
  fi
  [ -f "$lock_dir/holder" ] || return 1
  holder_pid=$(sed -nE 's/^pid=([0-9]+)$/\1/p' "$lock_dir/holder" 2>/dev/null | head -1)
  [ -n "$holder_pid" ] || return 1
  p=$$
  n=0
  while [ "$n" -lt 64 ]; do
    [ "$p" = "$holder_pid" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    case "$p" in ''|*[!0-9]*|0|1) return 1 ;; esac
    n=$((n + 1))
  done
  return 1
}

# analyze_segment <seg> <depth>：對一個已斷詞的段落做 H1/H2/H3 判定（命令位置＝第一個非
# `VAR=val` 賦值形狀的 token）。命中即設全域 DENY_MSG 並 return；沒命中維持 DENY_MSG 空。
# 段內任一位置出現 `bash`／`sh` 緊接 `-c` 時，把下一個 token 當巢狀命令遞迴丟回 evaluate()
# （見檔頭「前處理 4」）——WRAPPER_HAYSTACK 是 evaluate() 設的全域，遞迴呼叫會覆寫它，用完
# 要還原，否則本段後面的 H3 包裹檢查會拿到巢狀那層的 haystack。
analyze_segment() {
  local seg=$1 depth=$2
  local t prevtok="" idx=0
  local cmd="" cmd_set=0
  local has_no_verify=0 has_dash_n=0 has_commit=0 has_push=0 has_force=0 has_protected=0
  local h2_hit=0 grep_o=0 grep_eq=0 cut_d=0 cut_f=0 h2_redir=0 expect_redir=0
  local h3_run_sh=0 h3_supabase_reset=0
  local shellc_prev=""

  while IFS= read -r -d "$TSEP" t || [ -n "$t" ]; do
    [ "$t" = $'\n' ] && continue

    if [ "$cmd_set" -eq 0 ]; then
      if ! [[ $t =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
        cmd=$t
        cmd_set=1
      fi
    fi

    if [ "$cmd" = "git" ]; then
      case "$t" in
        --no-verify) has_no_verify=1 ;;
        -n) has_dash_n=1 ;;
        commit) has_commit=1 ;;
        push) has_push=1 ;;
        --force|-f) has_force=1 ;;
      esac
      [[ $t == --force-with-lease* ]] && has_force=1
      [[ $t == +* ]] && has_force=1
      [[ $t =~ $PROTECTED_BRANCH_RE ]] && has_protected=1
    fi

    if [[ $cmd =~ $READ_VERBS_RE ]]; then
      [[ $t =~ $ENV_FILE_RE ]] && h2_hit=1
      if [ "$cmd" = "grep" ]; then
        [[ $t =~ ^-[A-Za-z]*o[A-Za-z]*$ ]] && grep_o=1
        [[ $t == *= ]] && grep_eq=1
      fi
      if [ "$cmd" = "cut" ]; then
        [ "$t" = "-d=" ] && cut_d=1
        [ "$prevtok" = "-d" ] && [ "$t" = "=" ] && cut_d=1
        [ "$t" = "-f1" ] && cut_f=1
        [ "$prevtok" = "-f" ] && [ "$t" = "1" ] && cut_f=1
      fi
    fi

    if [ "$t" = "<" ]; then
      expect_redir=1
    else
      if [ "$expect_redir" -eq 1 ]; then
        [[ $t =~ $ENV_FILE_RE ]] && h2_redir=1
        expect_redir=0
      fi
    fi

    if [ "$cmd" = "supabase" ] && [ "$prevtok" = "db" ] && [ "$t" = "reset" ]; then
      h3_supabase_reset=1
    fi
    if [ "$cmd" = "bash" ] || [ "$cmd" = "sh" ]; then
      [[ $t =~ $RUNSH_RE ]] && [ "$t" != "$cmd" ] && h3_run_sh=1
    fi

    # bash/sh -c "<nested>" 遞迴（掃全段任一位置，不限命令位置——`env FOO=bar bash -c "…"`
    # 這種命令位置其實是 env 的情況也要接住，否則位置比對收窄後變成新的繞過路徑）。
    if [ "$prevtok" = "-c" ] && { [ "$shellc_prev" = "bash" ] || [ "$shellc_prev" = "sh" ]; }; then
      if [ "$depth" -lt 8 ]; then
        local saved_wrapper=$WRAPPER_HAYSTACK
        evaluate "$t" "$((depth+1))"
        WRAPPER_HAYSTACK=$saved_wrapper
        [ -n "${DENY_MSG:-}" ] && return
      else
        DENY_MSG="H0：巢狀 bash/sh -c 超過安全深度上限，fail-closed，見 ${COLL_REF}"
        return
      fi
    fi
    [ "$t" = "-c" ] && shellc_prev=$prevtok

    prevtok=$t
    idx=$((idx+1))
  done <<<"${seg}${TSEP}"

  if [[ $cmd =~ $RUNSH_RE ]]; then h3_run_sh=1; fi

  if [ "$has_no_verify" -eq 1 ]; then
    DENY_MSG="H1：命令含 --no-verify，繞過 commit/push gate，見 ${COLL_REF}"; return
  fi
  if [ "$has_commit" -eq 1 ] && [ "$has_dash_n" -eq 1 ]; then
    DENY_MSG="H1：git commit -n 等同 --no-verify，繞過 commit gate，見 ${COLL_REF}"; return
  fi
  if [ "$has_push" -eq 1 ] && [ "$has_force" -eq 1 ] && [ "$has_protected" -eq 1 ]; then
    DENY_MSG="H1：force push 目標為 development／test／main（受保護分支禁止 force push），見 ${COLL_REF}"; return
  fi

  if [ "$h2_redir" -eq 1 ]; then
    DENY_MSG="H2：以 < 重導向讀出 .env 內容，見 ${COLL_REF}"; return
  fi
  if [ "$h2_hit" -eq 1 ]; then
    if { [ "$grep_o" -eq 1 ] && [ "$grep_eq" -eq 1 ]; } || { [ "$cut_d" -eq 1 ] && [ "$cut_f" -eq 1 ]; }; then
      : # key-only 放行形式
    else
      DENY_MSG="H2：以 cat／less／head／tail／sed／awk／grep／cut／bat／xxd／base64／strings／rg／wc 讀出 .env 內容（非 key-only 形式），見 ${COLL_REF}"
      return
    fi
  fi

  if [ "$h3_supabase_reset" -eq 1 ] || [ "$h3_run_sh" -eq 1 ]; then
    if ! m "$WRAPPER_HAYSTACK" 'supabase-lock\.sh\b.*[[:space:]]--([[:space:]]|$)'; then
      if ! h3_reentrant; then
        DENY_MSG="H3：supabase db reset／run.sh 未經 scripts/ops/supabase-lock.sh -- 包裹（本機容器跨 worktree 共用，LS-70），見 ${COLL_REF}"
        return
      fi
    fi
  fi
}

# evaluate <cmd> <depth>：整套規則的入口——heredoc 剝除 → 引號感知斷詞 → 逐段 analyze_segment
# → $(...)／反引號內文遞迴評估。設全域 DENY_MSG（非空＝deny 理由）。深度上限 8（`bash -c`
# 巢狀與 `$(...)` 巢狀共用同一個上限）。直接呼叫、不可用 $(...) 包。
evaluate() {
  local cmd=$1 depth=$2
  DENY_MSG=""
  if [ "$depth" -gt 8 ]; then
    DENY_MSG="H0：巢狀深度超過安全上限，fail-closed，見 ${COLL_REF}"; return
  fi
  strip_heredocs "$cmd"
  if [ "$HD_BAD" -eq 1 ]; then
    DENY_MSG="H0：heredoc 未正確終止，切段失敗（歧義即 deny），見 ${COLL_REF}"; return
  fi
  tokenize "$HD_OUT"
  if [ "$AMBIGUOUS" -eq 1 ]; then
    DENY_MSG="H0：命令引號／\$(...)／反引號不平衡，切段失敗（歧義即 deny），見 ${COLL_REF}"; return
  fi
  WRAPPER_HAYSTACK=$HD_OUT
  local segs=$TOK_OUT
  local subs=$CMDSUBS
  local seg
  while IFS= read -r -d "$SSEP" seg || [ -n "$seg" ]; do
    [ -n "$seg" ] || continue
    [ "$seg" = $'\n' ] && continue
    analyze_segment "$seg" "$depth"
    [ -n "${DENY_MSG:-}" ] && return
  done <<<"${segs}"
  local sub
  while IFS= read -r -d "$CSUB_SEP" sub || [ -n "$sub" ]; do
    [ -n "$sub" ] || continue
    [ "$sub" = $'\n' ] && continue
    if [ "$depth" -ge 8 ]; then
      DENY_MSG="H0：巢狀 \$(...)／反引號超過安全深度上限，fail-closed，見 ${COLL_REF}"; return
    fi
    evaluate "$sub" "$((depth+1))"
    [ -n "${DENY_MSG:-}" ] && return
  done <<<"${subs}"
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
    # LS-104：全部 H1/H2/H3 判定收斂到 evaluate()（heredoc 剝除 → 引號感知斷詞 → 逐段命令位置
    # 判定 → $(...)／反引號／bash -c 遞迴），見檔頭「前處理」與函式註解。
    evaluate "$command" 0
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
