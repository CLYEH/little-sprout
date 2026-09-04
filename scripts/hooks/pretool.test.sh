#!/bin/bash
# pretool.sh 自測（LS-88；R2 補 merge-reviewer R1 blocker/major/informational——
# https://github.com/CLYEH/little-sprout/pull/157#issuecomment-5413222970；R3 補 LS-104
# merge-reviewer R2 blocker，comment 5a170052：bash/sh -c 偵測要求緊接在 bash/sh 後面，
# 併入短旗標團／前面插旗標都測不到，同時繞過 H1/H2/H3；R4 補 merge-reviewer R3 blocker，
# comment 59e21b88（F1-residual）：R3 的兩半兜底只套在 bash/sh，zsh/dash/ksh 這三支
# macOS 預裝的 sibling shell 仍 fail open，`zsh -c "supabase db reset"` 正是 LS-70
# 事故的路徑；R5 補 merge-reviewer R4 blocker，comment cd011475（F1-residual-2）：
# 同型的洞在 csh/tcsh 身上依然存在，補完後 macOS 預裝 -c shell 為封閉集合）。
# CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：H1–H3 若退化（字面比對變寬鬆、fail-closed
# 漏接）這裡會紅。R1 抓到的洞（多行 command 只看第一行、grep 異常當沒命中放行、.env／run.sh
# 邊界要求空白或行尾、放行形式整條字串比對）都各自補了對應的正負樣本，避免同一個洞回來。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pretool="${root}/scripts/hooks/pretool.sh"
fail=0

# ---- bash 3.2：不用陣列／${var,,}，${name} 展開＋case ----
bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
read_json() { printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1"; }

# expect <label> <want_exit> <payload> [env VAR=val ...]：allow（want=0）驗無輸出；
# deny（want!=0，本檔案只用 2）驗輸出含 deny JSON。額外參數交給 `env` 覆寫子行程環境
# （PATH／SUPABASE_LOCK_HELD 等），不影響本測試腳本自己的環境。
expect() {
  local label=$1 want=$2 payload=$3 out got
  shift 3
  out=$(printf '%s' "$payload" | env "$@" bash "$pretool" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ ${label}（期望 exit ${want}，實得 ${got}；輸出：${out}）" >&2
    fail=1
    return
  fi
  if [ "$want" -eq 0 ]; then
    if [ -n "$out" ]; then
      echo "✗ ${label}（allow 應無輸出，實得：${out}）" >&2
      fail=1
      return
    fi
  else
    case "$out" in
      *'"permissionDecision":"deny"'*) ;;
      *) echo "✗ ${label}（exit=${want} 但輸出缺 deny JSON：${out}）" >&2; fail=1; return ;;
    esac
  fi
  echo "✓ ${label}"
}

# ============================================================
# H1：--no-verify／force push 到 development／test／main
# ============================================================
expect 'H1① --no-verify（deny）' 2 "$(bash_json 'git push --no-verify')"
expect 'H1② force push 明寫 main（deny）' 2 "$(bash_json 'git push --force origin main')"
expect 'H1③ -f ＋ development refspec（deny）' 2 "$(bash_json 'git push -f origin development:development')"
expect 'H1④ 一般 push（allow）' 0 "$(bash_json 'git push origin feature/LS-88-pretool-hooks')"
expect 'H1⑤ force push 到非保護分支（allow，看目標而非只看旗標）' 0 "$(bash_json 'git push --force origin feature/LS-88-scratch')"
expect 'H1⑥ 無關命令（allow）' 0 "$(bash_json "git commit -m 'fix: something'")"

# ============================================================
# H2：讀 .env value（Bash 與 Read 兩種 matcher）
# ============================================================
expect 'H2① cat .env（deny）' 2 "$(bash_json 'cat .env')"
expect 'H2② grep 抓值 .env（deny）' 2 "$(bash_json 'grep SECRET_KEY .env')"
expect 'H2③ sed -n .env（deny）' 2 "$(bash_json "sed -n '1,5p' .env")"
expect 'H2④ 放行：grep -oE key-only（allow）' 0 "$(bash_json "grep -oE '^[A-Z_]+=' .env")"
expect 'H2⑤ 放行：source .env（allow，注入不印出）' 0 "$(bash_json 'source .env')"
expect 'H2⑥ 放行：set -a; . .env（allow）' 0 "$(bash_json 'set -a; . .env; set +a')"
expect 'H2⑦ 放行：cut -d= -f1（allow，只取 key 欄）' 0 "$(bash_json 'cut -d= -f1 .env')"
expect 'H2⑧ cut -d= -f2 抓值（deny，非 key-only）' 2 "$(bash_json 'cut -d= -f2 .env')"
expect 'H2⑨ Read 直讀 .env（deny）' 2 "$(read_json '.env')"
expect 'H2⑩ Read 直讀 .env.production（deny）' 2 "$(read_json '.env.production')"
expect 'H2⑪ Read 讀無關檔（allow）' 0 "$(read_json 'README.md')"
expect 'H2⑫ Bash 對無關檔操作（allow，不含 .env）' 0 "$(bash_json 'cat environment.json')"

# ============================================================
# H3：supabase db reset／run.sh 必經 supabase-lock.sh --
# ============================================================
expect 'H3① 裸跑 supabase db reset（deny）' 2 "$(bash_json 'supabase db reset')"
expect 'H3② 裸跑 run.sh（deny）' 2 "$(bash_json 'bash supabase/tests/run.sh')"
expect 'H3③ 包在 supabase-lock.sh --（allow）' 0 "$(bash_json 'bash scripts/ops/supabase-lock.sh -- supabase db reset')"
expect 'H3④ 帶 --timeout 仍算包裹（allow）' 0 "$(bash_json 'bash scripts/ops/supabase-lock.sh --timeout 30 -- supabase db reset')"
# R1 informational I2：重入判定原本讀 SUPABASE_LOCK_HELD（hook 是獨立行程、不繼承那個環境
# 變數，這條分支實務上永遠不會為真——見 pretool.sh h3_reentrant() 的檔頭說明），改用
# supabase-lock.sh 真正的祖先判定：讀 SUPABASE_LOCK_DIR/holder 的 `pid=` 行，往上走本行程
# 祖先鏈。用假的 lock 目錄測，不碰真正的 /tmp/supabase-lock-<project_id>。
i2_lockdir=$(mktemp -d)
printf 'pid=%s\n' "$$" > "$i2_lockdir/holder"
expect 'H3⑤a 重入：holder pid 是本程序的祖先（allow）' 0 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_DIR="$i2_lockdir"
printf 'pid=1\n' > "$i2_lockdir/holder"
expect 'H3⑤b 重入：holder pid 不是祖先（deny，同 supabase-lock.sh is_ancestor 對 pid 1／0 一律視為到頂放棄）' 2 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_DIR="$i2_lockdir"
rm -rf "$i2_lockdir"
expect 'H3⑤c 舊機制 SUPABASE_LOCK_HELD 不再有效（deny，證明真的換掉了、不是兩條路徑並存）' 2 "$(bash_json 'supabase db reset')" SUPABASE_LOCK_HELD=/tmp/fake-lock
expect 'H3⑥ 無關命令（allow）' 0 "$(bash_json 'ls supabase/migrations')"

# ============================================================
# 非 Bash／Read 工具：不受任何規則管
# ============================================================
expect '非 Bash／Read（Write，allow）' 0 '{"tool_name":"Write","tool_input":{"file_path":"foo.txt"}}'

# ============================================================
# R1 F1（blocker）：多行 command 只評估第一行——H1/H2/H3 各補一組「違規在第二行」
# ============================================================
# 注意：JSON 字串裡的換行必須是 `\n`（反斜線加 n 兩個字元，讓 jq／python3 解成真正的換行），
# 不能是原始換行位元組——原始換行在嚴格 JSON 裡是未跳脫的控制字元，jq／python3 兩邊都會直接
# parse error（試過：兩邊都拒絕），那樣測到的只是「JSON 壞掉」的 fail-closed 分支，不是 F1 真正
# 要驗的「多行 command 有沒有被完整讀進來」。
expect 'F1-H1 多行：違規在第二行（deny）' 2 "$(bash_json 'git add -A\ngit commit --no-verify -m x')"
expect 'F1-H1b 多行：force push 在第二行（deny）' 2 "$(bash_json 'echo prep\ngit push --force origin main')"
expect 'F1-H2 多行：cat .env 在第二行（deny，R1 實測案例）' 2 "$(bash_json 'cd /tmp\ncat .env')"
expect 'F1-H3 多行：db reset 在第二行（deny）' 2 "$(bash_json 'echo start\nsupabase db reset')"
expect 'F1 多行：違規在第一行、第二行無關（deny，回歸）' 2 "$(bash_json 'cat .env\necho done')"

# ============================================================
# R1 F2（blocker，原文測 grep 異常）／R2（H1/H2/H3 全改叫 pretool_engine.py，見 pretool.sh
# run_bash_engine）：pretool_engine.py 無法正常執行（python3 缺席／腳本以非 0/2 的 rc 結束）
# 須 fail-closed，不當「沒命中」放行——Rule 8：R1 這裡原本測的是「grep 異常」，R2 把 H1/H2/H3
# 的比對全部搬去 python3 之後 grep 已經不是任何 Bash 判定的依賴，原測資測不出邏輯改掉（假綠），
# 換成對等的 python3 情境（PATH 缺 python3／python3 是會以非預期 rc 結束的假腳本）。
# ============================================================
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bash_bin=$(bash -c 'type -P bash' 2>/dev/null || echo /bin/bash)
real_jq=$(bash -c 'type -P jq' 2>/dev/null || true)
real_python3=$(bash -c 'type -P python3' 2>/dev/null || true)

mkdir -p "$work/empty" "$work/nopy" "$work/badpy"
[ -n "$real_jq" ] && ln -sf "$real_jq" "$work/nopy/jq"
[ -n "$real_jq" ] && ln -sf "$real_jq" "$work/badpy/jq"
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/badpy/python3.real"
cat > "$work/badpy/python3" <<'STUB'
#!/bin/bash
exit 137
STUB
chmod +x "$work/badpy/python3"

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/nopy" "$bash_bin" "$pretool" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：PATH 缺 python3（deny，H1/H2/H3 評估引擎無法執行）'
else
  echo "✗ F2：PATH 缺 python3 應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/badpy" "$bash_bin" "$pretool" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：python3 以非預期 rc 結束（deny，rc 不是 0/2 一律 fail-closed）'
else
  echo "✗ F2：python3 異常應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

# pretool_engine.py 檔案本身不存在（例如佈署時漏拷貝）也要 fail-closed，不能因為 python3
# 找不到檔案印出的是 stderr（被 2>/dev/null 丟掉）、stdout 空字串，就被 run_bash_engine 的
# `DENY_MSG=$out` 用空字串蓋掉、`[ -n "$DENY_MSG" ]` 判斷成「沒有 deny」而誤放行。
missing_py_work=$(mktemp -d)
cp "$pretool" "$missing_py_work/pretool.sh"
# 故意不拷貝 pretool_engine.py，模擬部署時漏了這個檔案
out=$(printf '%s' "$(bash_json 'echo hi')" | "$bash_bin" "$missing_py_work/pretool.sh" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F2：pretool_engine.py 檔案不存在（deny，空 stdout 不會被誤判成沒有 deny）'
else
  echo "✗ F2：pretool_engine.py 缺席應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi
rm -rf "$missing_py_work"

# ============================================================
# R1 F3（blocker）：.env／run.sh 邊界要求後接空白或行尾，漏放引號／分號／重導向／命令替換
# ============================================================
expect 'F3① cat .env;（deny）' 2 "$(bash_json 'cat .env; echo hi')"
expect 'F3② cat .env;ls 無空白（deny）' 2 "$(bash_json 'cat .env;ls')"
expect 'F3③ 單引號包住 .env（deny）' 2 "$(bash_json "cat '.env'")"
expect 'F3④ 雙引號包住 .env（deny）' 2 "$(bash_json 'cat ".env"')"
expect 'F3⑤ 命令替換 $(cat .env)（deny）' 2 "$(bash_json 'echo $(cat .env)')"
expect 'F3⑥ < 重導向讀 .env（deny，無需具名動詞）' 2 "$(bash_json 'while read l; do echo $l; done < .env')"
expect 'F3⑦ H3：run.sh 帶結尾分號（deny）' 2 "$(bash_json 'bash supabase/tests/run.sh;')"
expect 'F3⑧ 回歸：路徑前綴 config/.env 仍判定（deny）' 2 "$(bash_json 'cat config/.env')"
expect 'F3⑨ 回歸：不相關檔名 myapp.environment 不誤判（allow）' 0 "$(bash_json 'cat myapp.environment')"

# ============================================================
# 空 stdin／JSON 壞掉／解析工具皆缺
# ============================================================
expect 'fail-closed：空 stdin（deny）' 2 ''
expect 'fail-closed：JSON 語法壞掉（deny）' 2 '{"tool_name":"Bash",'
expect 'fail-closed：JSON 頂層不是物件（deny）' 2 '[1,2,3]'

# py-only：jq 缺、只有 python3——R2 起 JSON 解析備援與 H1/H2/H3 評估都只需要 python3，
# 不再需要 grep（R1 的 py-only 目錄還會順便符連 grep，因為當時 H3 的 wrapper 字面比對走
# grep；R2 這條路徑已經沒有任何步驟呼叫外部 grep 了）。
mkdir -p "$work/py-only"
[ -n "$real_python3" ] && ln -sf "$real_python3" "$work/py-only/python3"

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/empty" "$bash_bin" "$pretool" 2>&1)
got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ fail-closed：jq／python3 皆缺（PATH 清空，deny）'
else
  echo "✗ fail-closed：jq／python3 皆缺（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
  fail=1
fi

if [ -n "$real_python3" ]; then
  out=$(printf '%s' "$(bash_json 'git push --no-verify')" | env PATH="$work/py-only" "$bash_bin" "$pretool" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（H1 判定仍正確，deny）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/py-only" "$bash_bin" "$pretool" 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（無關命令仍 allow）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（無關命令期望 exit 0 allow，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
  out=$(printf '%s' "$(bash_json 'cd /tmp\ncat .env')" | env PATH="$work/py-only" "$bash_bin" "$pretool" 2>&1)
  got=$?
  if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
    echo '✓ fail-closed：jq 缺、python3 備援成功（多行 command 仍能正確判定 H2，見 F1）'
  else
    echo "✗ fail-closed：jq 缺、python3 備援（多行 command 期望 exit 2 deny，實得 exit ${got}：${out}）" >&2
    fail=1
  fi
else
  echo '⚠ 略過 jq-缺-python3-備援 測試（本機找不到 python3）'
fi

# ============================================================
# R1 F4（major）：放行形式原本是整條字串比對，鏈式命令裡一段放行形式會讓另一段的真違規免疫
# ============================================================
expect 'F4① grep key-only 段 ; 真違規段（deny，原本被免疫）' 2 "$(bash_json "grep -oE '^[A-Z_]+=' .env; cat .env")"
expect 'F4② cut key-only 段 && 真違規段（deny）' 2 "$(bash_json 'cut -d= -f1 .env && cat .env')"
expect 'F4③ source .env; cat .env（deny——source 從不在放行判定裡，cat 才是觸發點；§7／PR body 曾記成「這是已知盲區」是文件記錯洞，已修正）' 2 "$(bash_json 'source .env; cat .env')"
expect 'F4④ 全段皆放行形式、無真違規（allow）' 0 "$(bash_json "grep -oE '^[A-Z_]+=' .env; echo done")"

# ============================================================
# R2 F1（merge-reviewer R2 blocker，F4 切段引入的回歸）：切段不看引號，分隔字元其實在引號內時
# 會把「動詞在這段、.env 在另一段」，兩段各自都不成立、整條被誤放行。修法：整條命令同時符合
# .env 引用與讀取動詞，但沒有任何一段同時符合兩者——歧義即 deny。
# ============================================================
expect 'R2F1① grep -E 雙引號內含 |（deny，回歸）' 2 "$(bash_json 'grep -E \"^(SUPABASE|ANON)=\" .env')"
expect 'R2F1② grep -E 單引號內含 |（deny，回歸）' 2 "$(bash_json "grep -E 'SECRET|TOKEN' .env")"
expect 'R2F1③ awk 欄位分隔字元在引號內（deny，回歸）' 2 "$(bash_json "awk -F'|' '{print \$2}' .env")"
expect 'R2F1④ sed -e 腳本內含 ;（deny，回歸）' 2 "$(bash_json "sed -e 's/a/b/;s/c/d/' .env")"
expect 'R2F1⑤ grep 樣式內含 ;（deny，回歸）' 2 "$(bash_json "grep 'a;b' .env")"
expect 'R2F1⑥ 放行形式＋真正的管線到 sort（allow，不受影響——放行段本身就同時命中兩者）' 0 "$(bash_json "grep -oE '^[A-Z_]+=' .env | sort")"
expect 'R2F1⑦ 無關命令不受影響（allow）' 0 "$(bash_json 'grep -E \"a|b\" notes.txt')"

# ============================================================
# R1 F6（major）：git commit -n（--no-verify 官方短旗標）；git push -n 是 --dry-run 不算
# ============================================================
expect 'F6① git commit -n（deny）' 2 "$(bash_json 'git commit -n -m x')"
expect 'F6② git commit --no-verify -n 同時出現（deny，H1a 先命中也行）' 2 "$(bash_json 'git commit --no-verify -n -m x')"
expect 'F6③ git push -n（allow，--dry-run 語意不同）' 0 "$(bash_json 'git push -n origin main')"
expect 'F6④ git commit 一般用法（allow）' 0 "$(bash_json "git commit -m 'x'")"

# ============================================================
# R1 F7（major）：內建 Grep 工具的 path／glob 指向 .env，原本 matcher 沒蓋到
# ============================================================
expect 'F7① Grep path=.env（deny）' 2 '{"tool_name":"Grep","tool_input":{"pattern":".","path":".env","output_mode":"content"}}'
expect 'F7② Grep glob=.env*（deny）' 2 '{"tool_name":"Grep","tool_input":{"pattern":"SECRET","glob":".env*"}}'
expect 'F7③ Grep path 為目錄（allow）' 0 '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"scripts"}}'
expect 'F7④ Grep 一般用法（allow）' 0 '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"scripts","glob":"*.sh"}}'

# ============================================================
# R1 I1（informational，便宜順修）：H2 讀取動詞白名單擴充 bat／xxd／base64／strings／rg／wc
# ============================================================
expect 'I1① bat .env（deny）' 2 "$(bash_json 'bat .env')"
expect 'I1② xxd .env（deny）' 2 "$(bash_json 'xxd .env')"
expect 'I1③ base64 .env（deny）' 2 "$(bash_json 'base64 .env')"
expect 'I1④ strings .env（deny）' 2 "$(bash_json 'strings .env')"
expect 'I1⑤ rg SECRET .env（deny）' 2 "$(bash_json 'rg SECRET .env')"
expect 'I1⑥ wc -l .env（deny）' 2 "$(bash_json 'wc -l .env')"

# ============================================================
# R1 I6（informational，便宜順修）：settings.json 的 PreToolUse 真的接著 pretool.sh、matcher
# 含 Grep、且用 `|| exit 2` 把 wiring 層的 fail-open 關起來（I4）——把 PreToolUse 區塊刪掉／
# matcher 漏列 Grep／忘了 `|| exit 2` 之前 CI 全綠，這裡補上直接讀 settings.json 斷言。
# ============================================================
settings_json="${root}/.claude/settings.json"
i6_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read|Grep") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null)
if [ -n "$i6_cmd" ]; then
  echo '✓ I6①：settings.json 的 PreToolUse matcher 含 Bash|Read|Grep 且接著 command'
else
  echo "✗ I6①：settings.json 找不到 matcher=Bash|Read|Grep 的 PreToolUse command" >&2
  fail=1
fi
case "$i6_cmd" in
  *pretool.sh*) echo '✓ I6②：command 確實呼叫 pretool.sh' ;;
  *) echo "✗ I6②：command 沒有呼叫 pretool.sh（實得：${i6_cmd}）" >&2; fail=1 ;;
esac
case "$i6_cmd" in
  *'|| exit 2'*) echo '✓ I6③：command 帶 || exit 2（I4，腳本缺席／執行失敗時 wiring 層仍 fail-closed）' ;;
  *) echo "✗ I6③：command 沒有 || exit 2（實得：${i6_cmd}）" >&2; fail=1 ;;
esac

# ============================================================
# R1 F5（major）：自測完全沒有覆蓋 trap——把 trap 那行拿掉重跑，31 組原本全綠（票文驗收「腳本
# 被弄壞時仍 deny」不成立）。做兩份暫存副本：都在 `input=` 之後插入 `exit 1`（模擬腳本中途一個
# 沒被任何 if／&&／|| 包住、未捕捉的失敗），一份保留 trap、一份把 trap 那行拿掉——若移除 trap
# 這件事不會改變行為，代表這組測試沒測到 trap 的作用（假綠）；本測試斷言兩者行為確實不同。
# ============================================================
mut_dir=$(mktemp -d)
build_mutant() {   # $1=輸出路徑 $2=yes/no（是否保留 trap）
  awk -v keep="$2" '
    $0 == "trap on_exit EXIT" && keep != "yes" { next }
    { print }
    $0 == "input=" { print "exit 1  # LS-88 R2 mutation-test：模擬腳本中途未捕捉錯誤" }
  ' "$pretool" > "$1"
}
build_mutant "$mut_dir/with_trap.sh" yes
build_mutant "$mut_dir/no_trap.sh" no

out=$(printf '%s' "$(bash_json 'echo hi')" | bash "$mut_dir/with_trap.sh" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F5：trap on_exit EXIT 在——腳本中途未捕捉錯誤（注入 exit 1）仍 deny（exit 2）'
else
  echo "✗ F5：trap 在時應 deny（實得 exit ${got}：${out}）" >&2
  fail=1
fi

out=$(printf '%s' "$(bash_json 'echo hi')" | bash "$mut_dir/no_trap.sh" 2>&1); got=$?
if [ "$got" -ne 2 ] || ! case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F5：拿掉 trap 後同樣的中途錯誤不再變成 deny（證明 trap 是關鍵、不是巧合過關）'
else
  echo "✗ F5：拿掉 trap 後行為竟然沒變——這組測試沒測到 trap 的效果（實得 exit ${got}：${out}）" >&2
  fail=1
fi
rm -rf "$mut_dir"

rm -rf "$work"
trap - EXIT

# ============================================================
# LS-104：只在「命令位置」比對，heredoc／引號字串／echo·printf 內容排除出比對範圍，$(...)／
# 反引號內容仍比對（那是真的執行）。三組事故原始重現（必須從誤擋改回 allow）＋三組對照
# （拿掉「文字內容」外殼、真的執行同一件事，必須仍然 deny——證明narrowing 沒有打開繞過路徑）。
# ============================================================
expect 'LS104-inc① heredoc 內文含 --no-verify 字面（allow，事故①原始重現：寫記憶檔提到旗標字面不是真的執行）' 0 \
  "$(bash_json "cat <<'EOF' > /tmp/mem.md\n這裡示範 --no-verify 的用法\nEOF\ngit add /tmp/mem.md")"
expect 'LS104-inc② heredoc 內文含 supabase db reset 字面（allow，事故②原始重現：寫文件說明規則不是真的執行）' 0 \
  "$(bash_json "cat <<'EOF' >> docs/NOTES.md\nH3 規則：supabase db reset 必須包 lock\nEOF")"
expect 'LS104-inc③ echo 提到 .env 檔名、另一段用 tail 讀無關檔（allow，事故③原始重現：echo 參數不是讀取動詞的引數）' 0 \
  "$(bash_json "echo '.env 是否存在的檢查'; tail -n 5 /var/log/app.log")"

expect 'LS104-ctl① 對照 inc①：真的 --no-verify（非 heredoc 內文，deny）' 2 "$(bash_json 'git push --no-verify')"
expect 'LS104-ctl② 對照 inc②：真的裸跑 supabase db reset（非 heredoc 內文，deny）' 2 "$(bash_json 'supabase db reset')"
expect 'LS104-ctl③ 對照 inc③：真的用 tail 讀 .env（非 echo 提及檔名，deny）' 2 "$(bash_json 'tail -n 5 .env')"

# 票文驗收另立一條：「引號不平衡 → deny」（切段失敗即歧義，見 evaluate() 的 AMBIGUOUS 分支）。
expect 'LS104-amb① 單引號未閉合（deny，切段失敗即歧義）' 2 "$(bash_json "cat .env'")"
expect 'LS104-amb② 命令替換 \$(...) 未閉合（deny，同一歧義規則）' 2 "$(bash_json 'echo $(cat .env')"

# 本票的自指性：ios-dev／orchestrator 自己的 commit message、PR body、handoff 常常需要描述這三條
# 規則本身（例如這個 commit message 就在講 --no-verify）——引號內的文字內容不該被當成旗標本身。
expect 'LS104-msg① commit message 提到 --no-verify（allow，訊息內文不是旗標）' 0 \
  "$(bash_json "git commit -m 'docs: 說明 --no-verify 規則'")"
expect 'LS104-msg② 對照 msg①：旗標本身在引號外（deny）' 2 "$(bash_json "git commit --no-verify -m 'docs update'")"

# 位置比對收窄到「命令位置」後，若不處理 bash -c／sh -c，會把違規包一層變成新的繞過路徑
# （cmd 變成 bash／sh，真正的動詞被吞進一個引號內的 token）——必須遞迴評估 payload，見
# pretool_engine.py 的 check_precise()「RECURSE」分支。
expect 'LS104-shc① bash -c 包住真違規（deny，證明位置比對收窄沒開新繞路）' 2 "$(bash_json "bash -c 'cat .env'")"
expect 'LS104-shc② sh -c 包住 --no-verify（deny）' 2 "$(bash_json "sh -c 'git push --no-verify'")"
expect 'LS104-shc③ env 包一層再 bash -c（deny，env FOO=bar bash -c 的形狀）' 2 \
  "$(bash_json "env FOO=bar bash -c 'supabase db reset'")"

# ============================================================
# LS-104 R2：merge-reviewer R1 comment 7a97f88a（2 blocker／3 major）——每個攻擊類別至少收
# 一組進永久回歸（reviewer 的 probe.py／probe2.py 130 組留在 /tmp 當開發期回歸套件，不進 repo；
# 這裡是「代表性案例」，每類至少一組，見票文驗收段）。
# ============================================================

# ---- F1（blocker）：命令位置認不得就退回整段字面比對，封住括號黏連／絕對路徑／shell 關鍵字
#      開頭／xargs／find -exec／eval／alias／函式定義這些「命令位置認得才精確比對」繞過的路徑 ----
expect 'R2F1-a 透明前綴詞 command（deny，command git commit --no-verify）' 2 "$(bash_json 'command git commit --no-verify')"
expect 'R2F1-b 絕對路徑（deny，/usr/bin/git commit --no-verify）' 2 "$(bash_json '/usr/bin/git commit --no-verify')"
expect 'R2F1-c 括號黏連 subshell（deny，(supabase db reset)）' 2 "$(bash_json '(supabase db reset)')"
expect 'R2F1-d brace group（deny，{ git commit --no-verify; }）' 2 "$(bash_json '{ git commit --no-verify; }')"
expect 'R2F1-e shell 關鍵字開頭 if/then（deny，agent 最自然會寫出的形狀）' 2 \
  "$(bash_json 'if true; then supabase db reset; fi')"
expect 'R2F1-f shell 關鍵字開頭 for/do（deny，for … do bash run.sh … done）' 2 \
  "$(bash_json 'for f in a b; do bash supabase/tests/run.sh; done')"
expect 'R2F1-g case/esac（deny）' 2 "$(bash_json 'case x in x) supabase db reset;; esac')"
expect 'R2F1-h xargs 間接執行（deny，echo x | xargs git commit --no-verify）' 2 \
  "$(bash_json 'echo x | xargs git commit --no-verify')"
expect 'R2F1-i find -exec 間接執行（deny）' 2 \
  "$(bash_json "find . -name f -exec git commit --no-verify {} \\;")"
expect 'R2F1-j 函式定義 name() { … } 同段呼叫真違規（deny）' 2 \
  "$(bash_json 'f() { git commit --no-verify; }')"
expect 'R2F1-k alias 定義後同段呼叫（deny，alias g=git; g commit --no-verify）' 2 \
  "$(bash_json 'alias g=git; g commit --no-verify')"
expect 'R2F1-l 引號旗標仍比對（deny，quoting 不影響傳給 git 的 argv，reviewer probe a06）' 2 \
  "$(bash_json 'git commit "--no-verify"')"
expect 'R2F1-m 正常前綴詞＋一般命令不誤擋（allow，sudo 只是很少見但不危險）' 0 "$(bash_json 'sudo ls -la')"
expect 'R2F1-n 正常 xargs 用法不誤擋（allow，找不到違規字面）' 0 "$(bash_json 'echo file.txt | xargs cat')"

# ---- F3（blocker）：反斜線跳脫先前完全不處理，導致引號提前關閉／token 被切碎＝漏放 ----
expect 'R2F3-a 反斜線接命令名（deny，\git commit --no-verify）' 2 "$(bash_json '\git commit --no-verify')"
expect 'R2F3-b 反斜線插在旗標中間（deny，git commit --no\-verify 真實 shell 還原成 --no-verify）' 2 \
  "$(bash_json 'git commit --no\-verify')"
expect 'R2F3-c 巢狀跳脫引號 bash -c 仍抓得到違規（deny）' 2 \
  "$(bash_json 'bash -c "bash -c \"cat .env\""')"
expect 'R2F3-d 續行反斜線不影響比對（deny，git commit \ 換行 --no-verify）' 2 \
  "$(bash_json 'git commit \\\n  --no-verify')"

# ---- F2（blocker）：假 heredoc（引號內／comment 內的 <<TAG 字面）不再吞掉後續真命令 ----
expect 'R2F2-a 引號內的 <<TAG 字面不觸發 heredoc（deny，後面真的 supabase db reset）' 2 \
  "$(bash_json 'echo "x <<T"\nsupabase db reset\nT')"
expect 'R2F2-b comment 內的 <<TAG 字面不觸發 heredoc（deny，後面真的 supabase db reset）' 2 \
  "$(bash_json 'true # <<T\nsupabase db reset\nT')"
expect 'R2F2-c 真正的 heredoc 仍正確剝除（allow，<<- 搭配 tab 縮排的合法用法）' 0 \
  "$(bash_json "cat <<-EOF\n\tsome text --no-verify\n\tEOF\n")"

# ---- F5（原 F1 acceptance 的延伸；informational 但列進 130 probe acceptance）：glob／${IFS} 繞路 ----
expect 'R2F5-a .env 加 glob 萬用字元（deny，cat .env*）' 2 "$(bash_json 'cat .env*')"
expect 'R2F5-b ${IFS} 取代空白（deny，cat${IFS}.env 展開後就是 cat .env）' 2 "$(bash_json 'cat${IFS}.env')"

# ---- ANSI-C quoting（reviewer probe2 x06）----
expect 'R2-ansic $便宜單引號（deny，cat \$'"'"'.env'"'"' 展開後就是 .env）' 2 "$(bash_json "cat \$'.env'")"

# ============================================================
# LS-104 R3（merge-reviewer R2 blocker，comment 5a170052）：命令位置認得 bash/sh 時，
# `-c` 偵測原本只認「`-c` 這個 token 緊接在 bash/sh 後面」——併入短旗標團（-lc/-cx）或
# 前面插其他旗標（-e -c/--norc -c）都測不到、也不遞迴，且 evaluate() 對 check_precise
# 回 OK 沒有 fallback 兜底，等於整條放行（同時繞過 H1/H2/H3，比 main 現行 hook 弱）。
# 廣義化 -c 偵測＋OK 結果補跑 check_fallback 兜底後，這些形狀都必須跟裸 `bash -c` 一樣
# 被遞迴抓到違規。
# ============================================================
expect 'R3F1-a -c 併入短旗標團 -lc（deny，bash -lc 讀 .env）' 2 "$(bash_json "bash -lc 'cat .env'")"
expect 'R3F1-b -c 併入短旗標團 -cx，c 在前（deny）' 2 "$(bash_json "bash -cx 'cat .env'")"
expect 'R3F1-c -c 前插旗標 -e -c（deny）' 2 "$(bash_json "bash -e -c 'cat .env'")"
expect 'R3F1-d -c 前插長旗標 --norc -c（deny，H3 supabase db reset）' 2 \
  "$(bash_json "bash --norc -c 'supabase db reset'")"
expect 'R3F1-e 對照：sh 併入短旗標團 -ec 同樣抓到（deny）' 2 "$(bash_json "sh -ec 'cat .env'")"
expect 'R3F1-f 對照：bash -c 包 benign payload 不誤擋（allow，廣義化沒有變成逢 -c 必擋）' 0 \
  "$(bash_json "bash -c 'echo hi'")"
expect 'R3F1-g 對照：純腳本呼叫無 -c 不受影響（allow，OK 兜底沒有變成逢 bash/sh 必擋）' 0 \
  "$(bash_json 'bash scripts/hooks/pretool.test.sh')"

# ============================================================
# LS-104 R4（merge-reviewer R3 blocker，comment 59e21b88，F1-residual）：R3 的
# `-c` 遞迴＋OK-fallback 只套在 cmd/pos_tok in ("bash", "sh")——macOS 預裝的 zsh／
# dash／ksh 是乾淨識別字，check_precise 對它們不做任何檢查而回 OK、OK-fallback 又
# 排除它們，於是三兄弟 shell 的 -c payload 裸放行（`zsh -c "supabase db reset"`
# 正是 LS-70 事故的原始路徑，main 擋、R3 版放行）。R4 把 zsh／dash／ksh 併入
# SHELLC_SHELLS，與 bash/sh 走同一套邏輯；payload 遞迴重評時新 shell 也在集合內，
# 巢狀（bash -c 包 zsh -c）自動被接住。
# ============================================================
expect 'R4F1-a zsh -c 裸跑 db reset（deny，H3，LS-70 事故原始路徑）' 2 \
  "$(bash_json "zsh -c 'supabase db reset'")"
expect 'R4F1-b dash -c 讀 .env（deny，H2）' 2 "$(bash_json "dash -c 'cat .env'")"
expect 'R4F1-c ksh -c --no-verify（deny，H1）' 2 \
  "$(bash_json "ksh -c 'git commit --no-verify'")"
expect 'R4F1-d 巢狀 bash -c 包 zsh -c 讀 .env（deny，遞迴接住兄弟 shell）' 2 \
  "$(bash_json 'bash -c '"'"'zsh -c "cat .env"'"'"'')"
expect 'R4F1-e zsh 併入短旗標團 -lc 同樣抓到（deny）' 2 "$(bash_json "zsh -lc 'cat .env'")"
expect 'R4F1-f 對照：zsh -c 包 benign payload 不誤擋（allow）' 0 \
  "$(bash_json "zsh -c 'echo hi'")"
expect 'R4F1-g 對照：zsh 呼叫純腳本不受影響（allow，OK 兜底沒有變成逢 zsh 必擋）' 0 \
  "$(bash_json 'zsh scripts/hooks/pretool.test.sh')"

# ============================================================
# LS-104 R5（merge-reviewer R4 blocker，comment cd011475，F1-residual-2）：R4 收了
# zsh／dash／ksh，但同型的洞在 csh／tcsh 身上依然存在（同樣預裝於 macOS，同樣的
# -c 語意）——`csh -c "supabase db reset"` 同樣是 LS-70 事故路徑。R5 把 csh／tcsh
# 併入 SHELLC_SHELLS，與其餘 shell 走同一套邏輯；至此 macOS 預裝、具 -c 語意的
# shell 為封閉集合 {bash,sh,zsh,dash,ksh,csh,tcsh}。
# ============================================================
expect 'R5F1-a csh -c 裸跑 db reset（deny，H3，LS-70 事故路徑）' 2 \
  "$(bash_json "csh -c 'supabase db reset'")"
expect 'R5F1-b tcsh -c 讀 .env（deny，H2）' 2 "$(bash_json "tcsh -c 'cat .env'")"
expect 'R5F1-c 巢狀 bash -c 包 csh -c 讀 .env（deny，遞迴接住 csh）' 2 \
  "$(bash_json 'bash -c '"'"'csh -c "cat .env"'"'"'')"
expect 'R5F1-d csh 併入短旗標團 -bc 同樣抓到（deny，H3）' 2 \
  "$(bash_json "csh -bc 'supabase db reset'")"
expect 'R5F1-e 對照：csh -c 包 benign payload 不誤擋（allow）' 0 \
  "$(bash_json "csh -c 'echo hi'")"
expect 'R5F1-f 對照：csh 呼叫純腳本不受影響（allow，OK 兜底沒有變成逢 csh 必擋）' 0 \
  "$(bash_json 'csh scripts/hooks/pretool.test.sh')"

# ============================================================
# LS-183 H3b：繞過 supabase-lock.sh 直接打本機容器的其他路徑（來源 LS-96 池項 e381f653 第 1 項＝
# LS-143 QA 直接 docker exec 撞上 LS-149 mid-reset）。四類正樣本各 ≥3（含命令位置認不得的退回、
# bash -c 遞迴、多行第二行）、負樣本：包裝過／持有者 worktree（沿 hold_owner_ok 的 worktree 腿：
# holder cmd=hold:*、pid 活著、worktree 與呼叫端目前目錄所在 worktree 頂層相同）／--linked／唯讀例外／
# heredoc 與 echo 內字面（LS-104 只在命令位置比對）。持有者判定用假 lock 目錄（SUPABASE_LOCK_DIR）＋假
# worktree（含 .git 檔）＋ hook JSON 的 cwd（bash_json_cwd），不碰真 lock；holder pid 用 1（活著、但
# 不是任何人的祖先——是 ancestor 就會走 H3 既有重入放行，測不到 worktree 腿）。
# ============================================================
bash_json_cwd() { printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2"; }
h3b_work=$(mktemp -d)
mkdir -p "$h3b_work/wt/sub" "$h3b_work/other"
: > "$h3b_work/wt/.git"
h3b_lock="$h3b_work/lock"; mkdir -p "$h3b_lock"
h3b_wt=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$h3b_work/wt")
printf 'pid=1\nworktree=%s\ncmd=hold:LS-183 test\n' "$h3b_wt" > "$h3b_lock/holder"

# ---- 正樣本 (a) docker exec 進 supabase_* 容器 ----
expect 'H3b-a① docker exec -it supabase_db_… psql（deny）' 2 \
  "$(bash_json 'docker exec -it supabase_db_little-sprout psql -U postgres -c \"select 1\"')"
expect 'H3b-a② docker compose exec supabase-db（deny，連字號前綴）' 2 \
  "$(bash_json 'docker compose exec supabase-db psql -U postgres')"
expect 'H3b-a③ pg_isready 藏在 bash -c 引號 payload 內（deny，唯讀例外只認 exact token）' 2 \
  "$(bash_json 'docker exec -i supabase_db_little-sprout bash -c \"pg_isready; psql -U postgres -c x\"')"
expect 'H3b-a④ 括號黏連 (docker exec …)（deny，命令位置認不得→退回整段字面比對）' 2 \
  "$(bash_json '(docker exec supabase_db_x psql -U postgres)')"
expect 'H3b-a⑤ bash -c 包住 docker exec（deny，遞迴）' 2 \
  "$(bash_json 'bash -c \"docker exec supabase_db_x psql -U postgres\"')"
expect 'H3b-a⑥ 多行：docker exec 在第二行（deny）' 2 \
  "$(bash_json 'echo prep\ndocker exec supabase_db_x psql -U postgres')"
# ---- 正樣本 (b) psql／連線字串打 54322 ----
expect 'H3b-b① psql -h 127.0.0.1 -p 54322（deny）' 2 "$(bash_json 'psql -h 127.0.0.1 -p 54322 -U postgres -c \"select 1\"')"
expect 'H3b-b② psql 連線字串 localhost:54322（deny；樣本不帶密碼——pre-commit secrets 掃描會擋 user:pass@host 形狀）' 2 \
  "$(bash_json 'psql postgresql://postgres@localhost:54322/postgres')"
expect 'H3b-b③ PGPASSWORD=… psql --port=54322（deny，賦值前綴不影響命令位置）' 2 \
  "$(bash_json 'PGPASSWORD=postgres psql -h localhost --port=54322 -U postgres')"
expect 'H3b-b④ pg_dump 連線字串 :54322（deny，連線字串不限 psql）' 2 \
  "$(bash_json 'pg_dump postgresql://postgres@127.0.0.1:54322/postgres -f x.sql')"
expect 'H3b-b⑤ DATABASE_URL=postgres://…:54322 node（deny，VAR= 前綴的連線字串）' 2 \
  "$(bash_json 'DATABASE_URL=postgres://postgres@127.0.0.1:54322/postgres node x.js')"
expect 'H3b-b⑥ for … do psql -p 54322（deny，shell 關鍵字開頭→退回整段字面比對）' 2 \
  "$(bash_json 'for i in 1; do psql -p 54322; done')"
# ---- 正樣本 (c) supabase 本機子命令無 --linked ----
expect 'H3b-c① supabase functions serve（deny）' 2 "$(bash_json 'supabase functions serve')"
expect 'H3b-c② supabase db query（deny）' 2 "$(bash_json 'supabase db query \"select 1\"')"
expect 'H3b-c③ supabase db dump（deny）' 2 "$(bash_json 'supabase db dump -f x.sql')"
expect 'H3b-c④ supabase migration up（deny）' 2 "$(bash_json 'supabase migration up')"
expect 'H3b-c⑤ supabase db query --db-url 打 54322（deny，--db-url 非 --linked、連線字串亦命中）' 2 \
  "$(bash_json 'supabase db query --db-url postgresql://postgres@127.0.0.1:54322/postgres \"select 1\"')"
# ---- 負樣本：包裝過 ----
expect 'H3b-n① supabase-lock.sh -- docker exec …（allow，包裝字面）' 0 \
  "$(bash_json 'bash scripts/ops/supabase-lock.sh -- docker exec -i supabase_db_little-sprout psql -U postgres -c \"select 1\"')"
expect 'H3b-n② supabase-lock.sh -- supabase functions serve（allow）' 0 \
  "$(bash_json 'bash scripts/ops/supabase-lock.sh -- supabase functions serve')"
expect 'H3b-n③ supabase-lock.sh --timeout 30 -- psql -p 54322（allow）' 0 \
  "$(bash_json 'bash scripts/ops/supabase-lock.sh --timeout 30 -- psql -h 127.0.0.1 -p 54322 -U postgres')"
# ---- 負樣本：持有者 worktree（hook JSON cwd 在 holder 的 worktree 內，或命令 cd 進去）----
expect 'H3b-h① cwd＝holder worktree 根（allow，worktree 腿）' 0 \
  "$(bash_json_cwd "$h3b_work/wt" 'docker exec -i supabase_db_little-sprout psql -U postgres -c \"select 1\"')" SUPABASE_LOCK_DIR="$h3b_lock"
expect 'H3b-h② cwd＝holder worktree 子目錄（allow，比對的是 worktree 頂層）' 0 \
  "$(bash_json_cwd "$h3b_work/wt/sub" 'psql -h 127.0.0.1 -p 54322 -U postgres')" SUPABASE_LOCK_DIR="$h3b_lock"
expect 'H3b-h③ cd <holder worktree> && docker exec（allow，沿命令追蹤 cd）' 0 \
  "$(bash_json_cwd "$h3b_work/other" "cd $h3b_work/wt && docker exec supabase_db_x psql -U postgres")" SUPABASE_LOCK_DIR="$h3b_lock"
expect 'H3b-h④ 對照：cwd 在別的目錄（deny，同一把 hold）' 2 \
  "$(bash_json_cwd "$h3b_work/other" 'docker exec -i supabase_db_little-sprout psql -U postgres')" SUPABASE_LOCK_DIR="$h3b_lock"
expect 'H3b-h⑤ 對照：cd 目的地含變數（deny，目的地判不出→不視為持有者 worktree）' 2 \
  "$(bash_json_cwd "$h3b_work/wt" 'cd \"\$WT\" && docker exec supabase_db_x psql -U postgres')" SUPABASE_LOCK_DIR="$h3b_lock"
expect 'H3b-h⑥ 對照：cd 離開 holder worktree 後再打（deny）' 2 \
  "$(bash_json_cwd "$h3b_work/wt" "cd $h3b_work/other && psql -p 54322")" SUPABASE_LOCK_DIR="$h3b_lock"
expect 'H3b-h⑦ 對照：持有者 worktree 不豁免 H3 的 supabase db reset 裸跑（deny，H3 只認包裝或 pid 祖先）' 2 \
  "$(bash_json_cwd "$h3b_work/wt" 'supabase db reset')" SUPABASE_LOCK_DIR="$h3b_lock"
printf 'pid=1\nworktree=%s\ncmd=bash\n' "$h3b_wt" > "$h3b_lock/holder"
expect 'H3b-h⑧ 對照：holder 是命令型（cmd 非 hold:*）→ worktree 腿不適用（deny，同 hold_owner_ok）' 2 \
  "$(bash_json_cwd "$h3b_work/wt" 'docker exec supabase_db_x psql -U postgres')" SUPABASE_LOCK_DIR="$h3b_lock"
sleep 300 & h3b_dead=$!; kill "$h3b_dead" 2>/dev/null; wait "$h3b_dead" 2>/dev/null
printf 'pid=%s\nworktree=%s\ncmd=hold:LS-183 test\n' "$h3b_dead" "$h3b_wt" > "$h3b_lock/holder"
expect 'H3b-h⑨ 對照：守門 pid 已死（deny，stale hold 不豁免）' 2 \
  "$(bash_json_cwd "$h3b_work/wt" 'docker exec supabase_db_x psql -U postgres')" SUPABASE_LOCK_DIR="$h3b_lock"
printf 'pid=%s\n' "$$" > "$h3b_lock/holder"
expect 'H3b-h⑩ H3 既有重入（holder pid 是祖先）對 H3b 同樣放行（allow，不另立一套）' 0 \
  "$(bash_json_cwd "$h3b_work/other" 'docker exec supabase_db_x psql -U postgres')" SUPABASE_LOCK_DIR="$h3b_lock"
rm -rf "$h3b_work"
# ---- 負樣本：--linked（正式站，不是本機容器）----
expect 'H3b-l① supabase db query --linked（allow）' 0 "$(bash_json 'supabase db query --linked \"select 1\"')"
expect 'H3b-l② supabase migration up --linked（allow）' 0 "$(bash_json 'supabase migration up --linked')"
expect 'H3b-l③ supabase db dump --linked（allow）' 0 "$(bash_json 'supabase db dump --linked -f x.sql')"
# ---- 負樣本：唯讀例外 ----
expect 'H3b-r① docker ps（allow）' 0 "$(bash_json 'docker ps')"
expect 'H3b-r② docker logs supabase_db_…（allow）' 0 "$(bash_json 'docker logs supabase_db_little-sprout')"
expect 'H3b-r③ docker inspect supabase_db_…（allow）' 0 "$(bash_json 'docker inspect supabase_db_little-sprout')"
expect 'H3b-r④ docker exec supabase_db_… pg_isready（allow，唯讀例外）' 0 \
  "$(bash_json 'docker exec supabase_db_little-sprout pg_isready -U postgres')"
expect 'H3b-r⑤ supabase status（allow）' 0 "$(bash_json 'supabase status')"
expect 'H3b-r⑥ supabase-lock.sh --status（allow）' 0 "$(bash_json 'bash scripts/ops/supabase-lock.sh --status')"
expect 'H3b-r⑦ (docker ps) 退回字面比對也不誤擋（allow）' 0 "$(bash_json '(docker ps)')"
# ---- 負樣本：字面在 heredoc／echo／grep 引數（LS-104 只在命令位置比對）----
expect 'H3b-t① heredoc 內文含 docker exec supabase_db_… psql -p 54322（allow）' 0 \
  "$(bash_json "cat <<'EOF' > docs/NOTES.md\nH3b：docker exec supabase_db_x psql -p 54322 要包 lock\nEOF")"
expect 'H3b-t② echo 引號內字面（allow）' 0 \
  "$(bash_json "echo 'H3b：docker exec supabase_db_x psql -p 54322 要包 lock'")"
expect 'H3b-t③ grep -rn 本機連線字串（allow，讀取動詞的引數不是打 DB）' 0 \
  "$(bash_json "grep -rn 'postgresql://127.0.0.1:54322' supabase/")"
expect 'H3b-t④ git commit -m 提到 psql 54322（allow）' 0 "$(bash_json "git commit -m 'docs: psql 54322 must be wrapped'")"
expect 'H3b-t⑤ psql 打別的 port（allow，只認 54322）' 0 "$(bash_json 'psql -h 127.0.0.1 -p 5432 -U postgres')"
expect 'H3b-t⑥ psql 連線字串打遠端（allow）' 0 "$(bash_json 'psql postgresql://u@db.example.supabase.co:5432/postgres')"

if [ "$fail" -eq 0 ]; then
  echo "✓ pretool.sh 自測通過"
fi
exit "$fail"
